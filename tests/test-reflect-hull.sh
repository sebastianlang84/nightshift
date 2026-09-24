#!/usr/bin/env bash
set -euo pipefail
unset GIT_CONFIG_COUNT  # a Fix stage exports the pre-push confinement hook this way; fixtures push main

# The reflection's two model calls run inside the bwrap hull (docs/design/reflection-confinement.md),
# and the design makes that fail CLOSED. What is asserted, with `pi` stubbed so no model is reached:
#
#   1. inside the hull the model call can read its payload and nothing of the account: not the
#      transcript trees the day was read from, not a file beside them;
#   2. the probe that shows (1) is not blind — with NIGHTSHIFT_REFLECT_SANDBOX=none the same stub
#      does see the transcripts;
#   3. without bwrap no model call is made at all, and the run says why;
#   4. the credential the call gets is narrowed to the reflection's provider — another provider's
#      token in the operator's auth.json is not in it, and the operator's file itself is not bound;
#   5. the host knobs that widen the gate's bind set do not reach this hull, and a bind that would
#      expose a protected path (here: an extension whose package root is the pi directory) refuses
#      the run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFLECT="$ROOT/bin/reflect.sh"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "test-reflect-hull: $*" >&2; exit 1; }
skip() { echo "test-reflect-hull: SKIP — $*"; exit 0; }

# An ambient opt-out would turn every case into a test of the unconfined path passing itself.
unset NIGHTSHIFT_REFLECT_SANDBOX NIGHTSHIFT_PI_SANDBOX NIGHTSHIFT_PI_EXTENSIONS NIGHTSHIFT_TEST_PATH \
      NIGHTSHIFT_TEST_SANDBOX_ROBIND

command -v bwrap >/dev/null 2>&1 || skip "bwrap is not installed"
bwrap --unshare-all --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
      --symlink usr/lib64 /lib64 --proc /proc --dev /dev \
      /bin/true >/dev/null 2>&1 || skip "unprivileged user namespaces are unavailable on this host"

DAY="2026-09-20"
C="$TMP/claude/projects/-home-x-proj"
mkdir -p "$TMP/bin" "$C" "$TMP/codex/sessions" "$TMP/out" "$TMP/pi-agent"
echo '{"pidso-proxy":{"type":"api_key","key":"KEEP_ME"},"anthropic":{"type":"api_key","key":"OTHER_PROVIDER_TOKEN"}}' \
  > "$TMP/pi-agent/auth.json"
T="$C/aaaaaaaa-1111-4111-8111-111111111111.jsonl"
cat > "$T" <<EOF
{"type":"user","uuid":"aaaaaaaa-1111-2222-3333-444444444444","timestamp":"${DAY}T10:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"SENTINEL_HUMAN_LINE"}}
{"type":"assistant","uuid":"aaaaaaaa-5555-2222-3333-444444444444","timestamp":"${DAY}T10:00:09.000Z","message":{"role":"assistant","content":[{"type":"text","text":"answered"}]}}
EOF
touch -d "$DAY 11:00:00" "$T"
echo "not for the model" > "$C/secret.txt"

# The stub answers both stages. Generate gets one finding whose quote resolves, so the run reaches the
# judge; the judge's answer is a probe of what the call could reach, and it lands in the report.
cat > "$TMP/bin/pi" <<EOF
#!/bin/sh
payload=""
for a in "\$@"; do case "\$a" in @*) payload="\${a#@}" ;; esac; done
case "\$payload" in
  *generate-payload.md)
    printf '%s\n' '{"findings":[{"id":"f1","title":"t","observation":"o","diagnosis":"d",
      "recommendation":"r","cost":"c","quotes":[{"turn":"s:aaaaaaaa","text":"SENTINEL_HUMAN_LINE"}]}]}' ;;
  *)
    v() { if [ -r "\$1" ]; then echo visible; else echo hidden; fi; }
    other=absent; grep -q OTHER_PROVIDER_TOKEN "\$PI_CODING_AGENT_DIR/auth.json" 2>/dev/null && other=present
    keep=absent;  grep -q KEEP_ME "\$PI_CODING_AGENT_DIR/auth.json" 2>/dev/null && keep=present
    echo "PROBE payload=\$(v "\$payload") transcript=\$(v "$T") secret=\$(v "$C/secret.txt") home=\$(v "$HOME/.ssh") opauth=\$(v "$TMP/pi-agent/auth.json") other=\$other keep=\$keep envsecret=\${REFLECT_TEST_SECRET:-unset}" ;;
esac
EOF
chmod +x "$TMP/bin/pi"

run() {
  PATH="$TMP/bin:$PATH" NIGHTSHIFT_PI_PATH="$TMP/bin" PI_CODING_AGENT_DIR="$TMP/pi-agent" \
  NIGHTSHIFT_REFLECT_CLAUDE_DIR="$TMP/claude/projects" \
  NIGHTSHIFT_REFLECT_CODEX_DIR="$TMP/codex/sessions" \
  NIGHTSHIFT_REFLECT_DIR="$TMP/out" \
    bash "$REFLECT" --day "$DAY" "$@" 2>&1
}

# The extractor names the session after the transcript, and the stub's quote must cite that id.
SID="$(python3 "$ROOT/lib/extract_session.py" --print-session-id "$T")"
sed -i "s/s:aaaaaaaa/$SID:aaaaaaaa/" "$TMP/bin/pi"

# --- 1. confined --------------------------------------------------------------
out="$(run --out "$TMP/out/hull.md")" || fail "the hulled run failed: $out"
grep -q 'hull: model calls confined' <<<"$out" || fail "the run did not report the hull: $out"
probe="$(grep -h 'PROBE' "$TMP/out/hull.md" || true)"
[ -n "$probe" ] || fail "the judge's probe never reached the report — did the judge run? $out"
grep -q 'payload=visible' <<<"$probe"   || fail "the hull hid the payload itself: $probe"
grep -q 'transcript=hidden' <<<"$probe" || fail "the model call could read the transcript tree: $probe"
grep -q 'secret=hidden' <<<"$probe"     || fail "the model call could read a file beside it: $probe"
grep -q 'home=hidden' <<<"$probe"       || fail "the model call could read ~/.ssh: $probe"
grep -q 'opauth=hidden' <<<"$probe"     || fail "the operator's own auth.json is bound into the hull: $probe"
grep -q 'other=absent' <<<"$probe"      || fail "another provider's token reached the call: $probe"
grep -q 'keep=present' <<<"$probe"      || fail "the reflection's own credential was filtered away: $probe"

# --- 5. widening knobs stay out, and a protected bind refuses the run ---------
out="$(NIGHTSHIFT_TEST_SANDBOX_ROBIND="$TMP/claude" REFLECT_TEST_SECRET=leaked \
       NIGHTSHIFT_TEST_ENV_PASS=REFLECT_TEST_SECRET run --out "$TMP/out/knob.md")" \
  || fail "the run with widening knobs in the environment failed: $out"
grep -q 'transcript=hidden' "$TMP/out/knob.md" \
  || fail "NIGHTSHIFT_TEST_SANDBOX_ROBIND widened the hull: $(grep PROBE "$TMP/out/knob.md")"
grep -q 'envsecret=unset' "$TMP/out/knob.md" \
  || fail "NIGHTSHIFT_TEST_ENV_PASS carried a variable into the hull: $(grep PROBE "$TMP/out/knob.md")"
# A bind INSIDE a sealed tree refuses the run too, not only one that contains it.
if out="$(NIGHTSHIFT_TEST_PATH="$C" NIGHTSHIFT_PI_EXTENSIONS="$C/secret.txt" run --out "$TMP/out/inside.md")"; then
  fail "an extension inside a transcript tree was bound and the run went on: $out"
fi
grep -q 'refusing the model calls' <<<"$out" || fail "the sealed-bind refusal does not say why: $out"
mkdir -p "$TMP/pi-agent/extensions"
echo '{}' > "$TMP/pi-agent/package.json"
echo 'export default {}' > "$TMP/pi-agent/extensions/auth.ts"
if out="$(NIGHTSHIFT_PI_EXTENSIONS="$TMP/pi-agent/extensions/auth.ts" run --out "$TMP/out/ext.md")"; then
  fail "an extension rooted at the pi directory was bound and the run went on: $out"
fi
grep -q 'refusing the model calls' <<<"$out" || fail "the protected-bind refusal does not say why: $out"
[ ! -e "$TMP/out/ext.md" ] || fail "a report was written although the hull was refused"
rm -rf "$TMP/pi-agent/extensions" "$TMP/pi-agent/package.json"

# --- 2. the probe is not blind ------------------------------------------------
out="$(NIGHTSHIFT_REFLECT_SANDBOX=none run --out "$TMP/out/open.md")" || fail "the unhulled run failed: $out"
grep -q 'hull DISABLED' <<<"$out" || fail "the opt-out ran without saying so: $out"
grep -q 'transcript=visible' "$TMP/out/open.md" \
  || fail "unconfined, the probe still saw nothing — case 1 proves nothing: $(grep PROBE "$TMP/out/open.md")"

# --- 3. no bwrap, no model call -------------------------------------------------
# A PATH with every tool this host has except bwrap, so `command -v bwrap` misses for real.
mkdir -p "$TMP/nobw"
for d in /usr/local/bin /usr/bin /bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = bwrap ] || [ -e "$TMP/nobw/$b" ] || ln -s "$f" "$TMP/nobw/$b"
  done
done
printf '#!/bin/sh\necho CALLED > "%s/pi-called"\n' "$TMP" > "$TMP/bin/pi"
if out="$(PATH="$TMP/bin:$TMP/nobw" NIGHTSHIFT_PI_PATH="$TMP/bin" PI_CODING_AGENT_DIR="$TMP/pi-agent" \
          NIGHTSHIFT_REFLECT_CLAUDE_DIR="$TMP/claude/projects" NIGHTSHIFT_REFLECT_CODEX_DIR="$TMP/codex/sessions" \
          NIGHTSHIFT_REFLECT_DIR="$TMP/out" /bin/bash "$REFLECT" --day "$DAY" --out "$TMP/out/nobw.md" 2>&1)"; then
  fail "the run succeeded without bwrap: $out"
fi
grep -q 'no hull for the model calls' <<<"$out" || fail "the refusal does not say why: $out"
[ ! -e "$TMP/pi-called" ] || fail "a model call was made without the hull"
[ ! -e "$TMP/out/nobw.md" ] || fail "a report was written without the hull"

echo "test-reflect-hull: ok"
