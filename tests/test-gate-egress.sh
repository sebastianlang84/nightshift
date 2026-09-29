#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# ADR 0028 — `test_net: true` used to mean `--share-net`, which hands the suite the HOST's network
# namespace. That is not "the internet": it is loopback and the LAN, so a suite in a test_net repo
# could reach every other service on this machine. `npm ci` needs a registry; it does not need
# 127.0.0.1.
#
# Now the sandbox ALWAYS has its own empty network namespace, and a test_net repo reaches the
# outside only through a vetting proxy on a unix socket — which crosses the namespace because it is
# a filesystem object rather than a route.
#
# The policy is checked here at two levels, because they fail independently:
#   * lib/egress_proxy.py's own decision function, directly — cheap and needs no network;
#   * end to end through a real sandbox, which is what proves the sandbox cannot go around it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-gate-egress: $*" >&2; exit 1; }
skip() { echo "test-gate-egress: SKIP — $*"; exit 0; }

unset NIGHTSHIFT_TEST_SANDBOX NIGHTSHIFT_TEST_SANDBOX_ROBIND NIGHTSHIFT_TEST_SANDBOX_HOME \
      NIGHTSHIFT_TEST_ENV_PASS NIGHTSHIFT_TEST_PATH

# --- 1. the address policy itself --------------------------------------------
# No sandbox and no network needed, so this half runs on every host including a CI runner with no
# user namespaces. It is also the part that decides whether a destination is internal, which is the
# whole security property.
python3 - "$ROOT" <<'PY' || fail "the egress address policy is wrong"
import importlib.util, pathlib, socket, sys, threading, time
spec = importlib.util.spec_from_file_location("ep", pathlib.Path(sys.argv[1], "lib", "egress_proxy.py"))
ep = importlib.util.module_from_spec(spec); spec.loader.exec_module(ep)

must_refuse = [
    "127.0.0.1", "127.1.2.3",        # the host's own services
    "::1",                            # …over IPv6
    "10.0.0.1", "172.16.0.1", "192.168.1.1",   # RFC1918 — the LAN
    "169.254.169.254",                # link-local, and with it cloud metadata
    "fd00::1", "fe80::1",             # IPv6 unique-local / link-local
    "0.0.0.0", "224.0.0.1",           # unspecified, multicast
]
must_allow = ["1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"]
bad = [ip for ip in must_refuse if ep.is_public(ip)] + \
      [ip for ip in must_allow if not ep.is_public(ip)]
if bad:
    print("misclassified:", bad, file=sys.stderr); sys.exit(1)

# A port allowlist, so the proxy is not a general-purpose tunnel to arbitrary services.
if ep.vet("example.com", 22) is not None:
    print("port 22 was allowed", file=sys.stderr); sys.exit(1)
# And the name is never trusted over the address it resolves to: `localhost` is a public-looking
# name for a private address, which is the shape a DNS-rebinding attempt takes.
if ep.vet("localhost", 443) is not None:
    print("localhost:443 was allowed", file=sys.stderr); sys.exit(1)

# A client that opens a partial CONNECT may not hold a host thread indefinitely.
reader, writer = socket.socketpair()
started = time.monotonic()
try:
    try:
        ep.read_request_head(reader, timeout=0.05)
        print("partial request did not time out", file=sys.stderr); sys.exit(1)
    except socket.timeout:
        pass
finally:
    reader.close(); writer.close()
if time.monotonic() - started > 1:
    print("request timeout was not bounded", file=sys.stderr); sys.exit(1)

# The host process has its own cap; sandbox RLIMITs do not cover its threads or memory.
slots = threading.BoundedSemaphore(1)
slots.acquire()
server, client = socket.socketpair()
try:
    if ep.dispatch(server, slots):
        print("connection was dispatched past the active-handler cap", file=sys.stderr); sys.exit(1)
    client.settimeout(1)
    if b"503" not in client.recv(1024):
        print("overloaded proxy did not return a readable refusal", file=sys.stderr); sys.exit(1)
finally:
    server.close(); client.close(); slots.release()
print("policy ok")
PY

command -v bwrap >/dev/null 2>&1 || skip "bwrap is not installed"
bwrap --unshare-all --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --symlink usr/lib64 /lib64 --proc /proc --dev /dev /bin/true >/dev/null 2>&1 \
  || skip "unprivileged user namespaces are unavailable on this host"

# --- the harness --------------------------------------------------------------
mkdir -p "$TMP/item" "$TMP/worktrees"
REPO="$TMP/repo"
git init -q -b main "$REPO"
echo seed > "$REPO/f"
git -C "$REPO" -c user.name=t -c user.email=t@localhost add -A
git -C "$REPO" -c user.name=t -c user.email=t@localhost commit -q -m init
git -C "$REPO" worktree add -q --detach "$TMP/wt"

cat > "$TMP/probe.sh" <<'PROBE'
set +u
NIGHTSHIFT_SOURCED=1 . "$ROOT/bin/nightshift.sh" >/dev/null 2>&1
set +e
TEST_TIMEOUT="${GATE_TIMEOUT:-60}"; TEST_MEMORY_MB=4096; TEST_MAX_PROCS=2048; TEST_FSIZE_MB=2048
REPO_PATHS=("$REPO"); REPO_MODES=(branch-fix)
REPO_TEST_NETS=("${GATE_NET:-false}"); REPO_TEST_CMDS=("$GATE_CMD; exit 1")
run_test_gate "$REPO" "$WT" "$ID"; echo "GATE_RC=$?"
cat "$ID/tests.log" 2>/dev/null
echo "--- egress ---"; cat "$ID/egress.log" 2>/dev/null
# The probe's LAST command decides its exit status, and the caller assigns that under `set -e`.
# Without this, a gate that simply had no egress log takes the whole suite down.
:
PROBE

gate() { local cmd="$1"; shift
  rm -f "$TMP/item/tests.log" "$TMP/item/egress.log"
  env WT="$TMP/wt" REPO="$REPO" "$@" ROOT="$ROOT" ID="$TMP/item" GATE_CMD="$cmd" \
      NIGHTSHIFT_WORKTREES="$TMP/worktrees" bash "$TMP/probe.sh" 2>&1
}

# --- 2. a service on the HOST's loopback is unreachable, with and without net --
# This is the concrete thing --share-net exposed: partflow, llmstack, open-webui and the dashboard
# all listen on this machine. A stand-in for them runs here for the duration of the test.
# The kernel picks the port: a fixed one collides with a sibling copy of this suite, and then the
# stand-in that answers is the sibling's, gone the moment that copy exits. The listener is bound
# before its port is published, so a port read from the file is already this test's own.
python3 - "$TMP/httpd.port" >/dev/null 2>&1 <<'HTTPD' &
import http.server, os, sys
s = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
s.serve_forever()
HTTPD
HTTPD=$!
# `|| true`: under `set -e` a failing command inside the EXIT trap ends the trap there, so a
# stand-in that already died would turn a passing run into rc=1 and leak $TMP.
trap 'kill $HTTPD 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 300); do [ -s "$TMP/httpd.port" ] && break; sleep 0.1; done  # 30s: a loaded host is slow
PORT="$(cat "$TMP/httpd.port" 2>/dev/null)" || fail "the stand-in host service did not start"
curl -s -m 3 -o /dev/null "http://127.0.0.1:$PORT/" || fail "the stand-in host service is not up; the test would prove nothing"

probe_cmd='curl -s -m 6 -o /dev/null -w "%{http_code}" http://127.0.0.1:'"$PORT"'/ 2>/dev/null; echo " <- host loopback"'
out="$(gate "$probe_cmd")"
grep -q '200 <- host loopback' <<<"$out" && { echo "$out" >&2; fail "a gate WITHOUT test_net reached a service on the host's loopback"; }
out="$(gate "$probe_cmd" GATE_NET=true)"
grep -q '200 <- host loopback' <<<"$out" && { echo "$out" >&2; fail "a gate WITH test_net reached a service on the host's loopback — --share-net is back"; }

# The sandbox's own loopback still works, or a suite that starts a test server cannot run at all.
out="$(gate 'python3 -c "
import http.server,threading,urllib.request
s=http.server.HTTPServer((\"127.0.0.1\",'"$PORT"'),http.server.SimpleHTTPRequestHandler)
threading.Thread(target=s.serve_forever,daemon=True).start()
print(\"own-loopback=\", urllib.request.urlopen(\"http://127.0.0.1:'"$PORT"'/\").status)
"')"
grep -q 'own-loopback= 200' <<<"$out" \
  || { echo "$out" >&2; fail "the sandbox cannot reach its OWN loopback — a suite with a test server breaks"; }
# …and that listener must be the sandbox's, not the host's: same port, different namespace.
curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" | grep -q 200 \
  || fail "the host's own service on that port disappeared — the namespaces are not separate"

# The same, WITH test_net — which is where it used to break. The proxy variables are exported to the
# whole suite, so a client that honours them sends its localhost request to the forwarder and the
# proxy refuses it as an external destination. market-digest showed this live: twelve refused POSTs
# to its own 127.0.0.1:9002, and a preflight test exercising an error path instead of its subject.
# no_proxy must exempt loopback — the sandbox's own, which grants nothing that --unshare-net took.
out="$(gate 'python3 -c "
import http.server,threading,urllib.request
s=http.server.HTTPServer((\"127.0.0.1\",'"$PORT"'),http.server.SimpleHTTPRequestHandler)
threading.Thread(target=s.serve_forever,daemon=True).start()
print(\"own-loopback=\", urllib.request.urlopen(\"http://127.0.0.1:'"$PORT"'/\").status)
print(\"by-name=\", urllib.request.urlopen(\"http://localhost:'"$PORT"'/\").status)
"' GATE_NET=true)"
grep -q 'own-loopback= 200' <<<"$out" \
  || { echo "$out" >&2; fail "with test_net the suite cannot reach its OWN server — the proxy hijacked loopback"; }
grep -q 'by-name= 200' <<<"$out" \
  || { echo "$out" >&2; fail "with test_net 'localhost' does not reach the suite's own server"; }

# --- 3. the proxy is refused for internal destinations, allowed for public ----
# Needs real DNS on the host, so it is skipped rather than failed on an offline machine.
if getent ahosts example.com >/dev/null 2>&1; then
  out="$(gate 'for u in https://127.0.0.1 https://localhost https://192.168.1.1 https://169.254.169.254; do
      curl -s -m 8 -o /dev/null "$u" 2>/dev/null && echo "REACHED $u"; done; echo probed' GATE_NET=true)"
  grep -q 'REACHED' <<<"$out" && { echo "$out" >&2; fail "an internal destination was reachable through the proxy"; }
  grep -q 'resolves to non-public' <<<"$out" \
    || { echo "$out" >&2; fail "the proxy did not log an address-policy refusal — was it consulted at all?"; }

  out="$(gate 'curl -s -m 25 -o /dev/null -w "public=%{http_code}\n" https://example.com' GATE_NET=true)"
  grep -q 'public=200' <<<"$out" \
    || { echo "$out" >&2; fail "a public HTTPS destination did not work — test_net repos cannot install anything"; }
  grep -q 'allow example.com:443' <<<"$out" \
    || { echo "$out" >&2; fail "the fetch did not go through the proxy"; }
else
  echo "test-gate-egress: note — live-network cases skipped (no DNS on this host)"
fi

# --- 4. without test_net there is no egress path at all -----------------------
out="$(gate 'curl -s -m 6 -o /dev/null -w "%{http_code}" https://example.com 2>/dev/null; echo " <- public"')"
grep -q '200 <- public' <<<"$out" && { echo "$out" >&2; fail "a gate without test_net reached the internet"; }
grep -q 'nightshift-egress' <<<"$(gate 'ls / 2>&1')" \
  && fail "the egress socket is mounted into a sandbox that was not granted test_net"

# --- 5. the proxy does not outlive the gate -----------------------------------
# It is started per gate; one left running is a socket on the host that nothing owns.
# `pgrep -c` prints 0 AND exits non-zero when nothing matches, so a `|| echo 0` fallback appends a
# SECOND zero and the comparison below gets "0\n0". Count lines instead.
# `|| true` INSIDE the substitution: pgrep exits 1 when nothing matches, and `pipefail` would hand
# that to the assignment, which `set -e` turns into an exit right here.
# Only this test's proxies: their socket sits under its own $TMP/worktrees. A host-wide count moves
# with every sibling suite that opens or closes a gate meanwhile, in either direction. `pgrep -f`
# takes a regex, so the path is escaped: an unescaped `[` in TMPDIR would match nothing and make
# both counts a vacuous zero.
mine="egress_proxy\\.py $(printf '%s' "$TMP/worktrees/" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
# Polled, not slept: under load a proxy may take longer than a fixed second to exit after SIGINT.
# Prints how many of this test's proxies are still running after up to 10s.
settled_mine() { local n; for _ in $(seq 100); do
    n="$( { pgrep -f "$mine" 2>/dev/null || true; } | wc -l)"; [ "$n" -eq 0 ] && break; sleep 0.1
  done; echo "$n"; }
# Scoped to this test, every earlier gate's proxy must be gone too: a count that only has to stay
# level would let a survivor from sections 2-4 through.
before="$(settled_mine)"
[ "$before" -eq 0 ] || fail "an egress proxy from an earlier gate in this test is still running ($before)"
# With `before` at 0, "no proxy afterwards" only means something if one ran at all.
out="$(gate 'true' GATE_NET=true)"
grep -q '\[egress\] listening on' <<<"$out" \
  || { echo "$out" >&2; fail "the test_net gate started no egress proxy — its teardown cannot be checked"; }
after="$(settled_mine)"
[ "$after" -eq 0 ] || fail "an egress proxy survived the gate ($after still running after 10s)"
find "$TMP/worktrees" -maxdepth 1 -name 'gate-egress.*' | grep -q . \
  && fail "the egress socket directory was left behind"

# --- 6. tearing the proxy down is silent --------------------------------------
# bash announces a process-substitution job killed by SIGTERM as a bare `Terminated` on stderr, and
# it does so at the NEXT command — so it surfaces in the night log between "test gate passed" and
# the push, reading like a crash inside a run that succeeded. Every test_net gate did this. SIGINT
# is silent and egress_proxy.py already exits cleanly on KeyboardInterrupt.
out="$(gate 'true' GATE_NET=true)"
grep -q 'Terminated' <<<"$out" \
  && { echo "$out" >&2; fail "the egress teardown printed a bare 'Terminated' into the run output"; }

echo "test-gate-egress: ok"
