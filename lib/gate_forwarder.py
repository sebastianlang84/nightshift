#!/usr/bin/env python3
"""Inside-the-sandbox half of the gate's egress path (ADR 0028).

The gate sandbox always has its own network namespace, so it has no route to anything — including
to the vetting proxy on the host. A unix socket crosses that boundary anyway, because it is a
filesystem object and the sandbox has it bound in.

npm, uv, pip and curl all speak to a proxy over TCP and none of them will connect to a unix socket,
so this listens on the sandbox's own private loopback and forwards each connection to that socket.
The sandbox's loopback is not the host's: nothing outside this namespace can reach this listener.

Runs as a background process inside the sandbox and dies with it (the PID namespace sees to that).
"""
import os
import socket
import sys
import threading

BUFSIZE = 65536


def splice(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            chunk = a.recv(BUFSIZE)
            if not chunk:
                break
            b.sendall(chunk)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(conn: socket.socket, sock_path: str) -> None:
    up = None
    try:
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        up.connect(sock_path)
        t = threading.Thread(target=splice, args=(conn, up), daemon=True)
        t.start()
        splice(up, conn)
        t.join(timeout=5)
    except OSError:
        pass
    finally:
        for s in (conn, up):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass


def main(port: int, sock_path: str) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(64)
    # The suite is only started once this line lands, so nothing races the listener.
    print("ready", flush=True)
    os.close(1)
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            break
        threading.Thread(target=handle, args=(conn, sock_path), daemon=True).start()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: gate_forwarder.py <port> <unix-socket-path>")
    try:
        main(int(sys.argv[1]), sys.argv[2])
    except KeyboardInterrupt:
        pass
