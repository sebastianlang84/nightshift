#!/usr/bin/env bash
set -euo pipefail

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
import importlib.util, pathlib, sys
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
python3 -m http.server 18231 --bind 127.0.0.1 >/dev/null 2>&1 &
HTTPD=$!
trap 'kill $HTTPD 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1
curl -s -m 3 -o /dev/null "http://127.0.0.1:18231/" || fail "the stand-in host service is not up; the test would prove nothing"

probe_cmd='curl -s -m 6 -o /dev/null -w "%{http_code}" http://127.0.0.1:18231/ 2>/dev/null; echo " <- host loopback"'
out="$(gate "$probe_cmd")"
grep -q '200 <- host loopback' <<<"$out" && { echo "$out" >&2; fail "a gate WITHOUT test_net reached a service on the host's loopback"; }
out="$(gate "$probe_cmd" GATE_NET=true)"
grep -q '200 <- host loopback' <<<"$out" && { echo "$out" >&2; fail "a gate WITH test_net reached a service on the host's loopback — --share-net is back"; }

# The sandbox's own loopback still works, or a suite that starts a test server cannot run at all.
out="$(gate 'python3 -c "
import http.server,threading,urllib.request
s=http.server.HTTPServer((\"127.0.0.1\",18231),http.server.SimpleHTTPRequestHandler)
threading.Thread(target=s.serve_forever,daemon=True).start()
print(\"own-loopback=\", urllib.request.urlopen(\"http://127.0.0.1:18231/\").status)
"')"
grep -q 'own-loopback= 200' <<<"$out" \
  || { echo "$out" >&2; fail "the sandbox cannot reach its OWN loopback — a suite with a test server breaks"; }
# …and that listener must be the sandbox's, not the host's: same port, different namespace.
curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:18231/" | grep -q 200 \
  || fail "the host's own service on that port disappeared — the namespaces are not separate"

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
before="$( { pgrep -f 'egress_proxy.py' 2>/dev/null || true; } | wc -l)"
gate 'true' GATE_NET=true >/dev/null
sleep 1
after="$( { pgrep -f 'egress_proxy.py' 2>/dev/null || true; } | wc -l)"
[ "$after" -le "$before" ] || fail "an egress proxy survived the gate ($before -> $after)"
find "$TMP/worktrees" -maxdepth 1 -name 'gate-egress.*' | grep -q . \
  && fail "the egress socket directory was left behind"

echo "test-gate-egress: ok"
