#!/usr/bin/env python3
"""Vetting HTTP CONNECT proxy for the ship gate's network (ADR 0028).

Runs on the HOST, listens on a unix socket, and is the only way out of a gate sandbox that has
`test_net: true`. The sandbox itself always gets `--unshare-net`, so there is no route it can take
that does not pass through here.

Why a proxy and not a shared network namespace: `--share-net` gave the suite the host's own
namespace, which means loopback and the LAN — every other service on this machine — not just "the
internet". `npm ci` needs a registry; it does not need `127.0.0.1:11434`.

Policy, enforced on the RESOLVED ADDRESS rather than on the name, because a name is attacker-chosen
and `evil.example` can resolve to `127.0.0.1`:

  * every address a name resolves to must be a global unicast address; if ANY of them is not, the
    request is refused. Partial rejection would leave DNS rebinding open.
  * the connection is then made to an address that was actually checked, never by re-resolving the
    name — otherwise the check and the connect can disagree.
  * ports are limited to 80 and 443. A package registry needs nothing else.

Stdlib only, like every other lib/ script here (see the deployment notes: `python3` is a hard
dependency and nothing in this repo may add a pip install).
"""
import ipaddress
import os
import socket
import sys
import threading

ALLOWED_PORTS = (80, 443)
BUFSIZE = 65536
# A refused CONNECT gets a real HTTP status so the tool reports something an operator can read,
# rather than a bare socket close that surfaces as "network unreachable" three layers up.
REFUSED = (
    b"HTTP/1.1 403 Forbidden\r\n"
    b"Content-Type: text/plain\r\n"
    b"Connection: close\r\n\r\n"
    b"nightshift egress proxy: destination refused (ADR 0028).\r\n"
)
BAD_REQUEST = (
    b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
    b"nightshift egress proxy: only HTTPS CONNECT is proxied.\r\n"
)


def log(msg: str) -> None:
    # stderr, because the Runner captures it next to the gate's own output.
    print(f"[egress] {msg}", file=sys.stderr, flush=True)


def is_public(ip: str) -> bool:
    """True only for a globally routable unicast address.

    `is_global` already excludes loopback, RFC1918, link-local (169.254/16, and with it the cloud
    metadata address), unique-local IPv6, multicast and the reserved blocks. Spelling those out
    by hand is how such a list goes stale one CIDR at a time.
    """
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return addr.is_global and not addr.is_multicast


def vet(host: str, port: int):
    """Resolve and approve a destination -> (family, sockaddr) to connect to, or None."""
    if port not in ALLOWED_PORTS:
        log(f"refuse {host}:{port} — port not in {ALLOWED_PORTS}")
        return None
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        log(f"refuse {host}:{port} — cannot resolve ({exc})")
        return None
    if not infos:
        log(f"refuse {host}:{port} — resolved to nothing")
        return None
    # ALL of them, not the first: a name that resolves to one public and one private address is a
    # rebinding attempt, and picking the public one would let it through.
    for family, _type, _proto, _canon, sockaddr in infos:
        if not is_public(sockaddr[0]):
            log(f"refuse {host}:{port} — resolves to non-public {sockaddr[0]}")
            return None
    family, _type, _proto, _canon, sockaddr = infos[0]
    return family, sockaddr


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


def read_request_line(conn: socket.socket) -> bytes:
    """Read up to the end of the CONNECT request head, bounded so a peer cannot exhaust us."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(BUFSIZE)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 32768:
            break
    return buf


def handle(conn: socket.socket) -> None:
    upstream = None
    try:
        head = read_request_line(conn)
        first = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = first.split()
        if len(parts) < 2 or parts[0].upper() != "CONNECT":
            # Plain HTTP would mean proxying request bodies and following redirects, i.e. becoming a
            # real HTTP proxy. Registries are HTTPS; refusing keeps this small enough to reason about.
            log(f"refuse — not a CONNECT request: {first[:80]!r}")
            conn.sendall(BAD_REQUEST)
            return
        target = parts[1]
        host, _, port_s = target.rpartition(":")
        if not host:
            host, port_s = target, "443"
        host = host.strip("[]")
        try:
            port = int(port_s)
        except ValueError:
            conn.sendall(BAD_REQUEST)
            return

        vetted = vet(host, port)
        if vetted is None:
            conn.sendall(REFUSED)
            return
        family, sockaddr = vetted
        upstream = socket.socket(family, socket.SOCK_STREAM)
        upstream.settimeout(30)
        upstream.connect(sockaddr)
        upstream.settimeout(None)
        log(f"allow {host}:{port} -> {sockaddr[0]}")
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")

        t = threading.Thread(target=splice, args=(conn, upstream), daemon=True)
        t.start()
        splice(upstream, conn)
        t.join(timeout=5)
    except OSError as exc:
        log(f"connection error: {exc}")
    finally:
        for s in (conn, upstream):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass


def main(sock_path: str) -> None:
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    # The sandbox connects as the same uid; nothing else on this host should be able to.
    os.chmod(sock_path, 0o600)
    srv.listen(64)
    log(f"listening on {sock_path} (CONNECT to public {ALLOWED_PORTS} only)")
    # Announce readiness on stdout so the Runner can wait for it instead of sleeping and hoping.
    print("ready", flush=True)
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            break
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: egress_proxy.py <unix-socket-path>")
    try:
        main(sys.argv[1])
    except KeyboardInterrupt:
        pass
