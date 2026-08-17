# ADR 0028 — gate egress goes through a vetting proxy, never the host's network

- Status: accepted
- Date: 2026-08-17
- Amends: [ADR 0026](0026-the-ship-gate-runs-in-a-sandbox.md) §2, which introduced `test_net: true`
  and described it as granting "egress"

## Context

ADR 0026 denied the gate sandbox a network by default and let a repo opt in with `test_net: true`,
implemented as bubblewrap's `--share-net`. Its residual list called that "an egress channel for
worktree content", judged narrow because the sandbox holds no credentials.

A cross-vendor review corrected the description, and the correction matters: `--share-net` does not
grant *the internet*, it declines to create a network namespace at all. The suite therefore sits in
**the host's** namespace, with the host's loopback and the host's LAN. On this machine that is
partflow, llmstack, open-webui and the dashboard — services that are unauthenticated precisely
because they are only reachable from localhost.

So the reasoning in ADR 0026 was sound and its conclusion was wrong. "No credentials on disk" is not
"no credentials reachable": a suite that cannot read `~/.ssh` can still ask a trusted local service
for whatever that service will hand out. And `npm ci` needs a registry — it has never needed
`127.0.0.1`.

## Decision

**The sandbox always gets its own network namespace. `test_net` no longer changes that.**

`--unshare-net` is unconditional. A `test_net: true` repo instead gets a path out through a vetting
proxy, and that path is the only one there is.

- **`lib/egress_proxy.py`** runs on the host for the duration of one gate, listening on a unix
  socket in a Runner-owned directory. A unix socket crosses the namespace boundary because it is a
  filesystem object, not a route — which is what makes this work without `slirp4netns`, `pasta`,
  `nftables` or any privilege the operator's account does not have. None of those are installed
  here, and requiring them would have made the sandbox a host-provisioning project.
- **`lib/gate_forwarder.py`** runs inside the sandbox, listening on *its* private loopback and
  forwarding to that socket, because npm, uv and pip speak to a proxy over TCP and none of them will
  connect to a unix socket. The Runner points `HTTPS_PROXY` and friends at it. A tool that ignores
  those variables simply has no network, which is the safe direction.
- **The policy is applied to the resolved address, not to the name.** Every address a name resolves
  to must be global unicast; if *any* is not, the request is refused, because partial rejection
  leaves DNS rebinding open. The connection is then made to an address that was actually checked,
  never by re-resolving. `ipaddress.is_global` supplies the definition rather than a hand-written
  CIDR list that would go stale one block at a time.
- **Ports are limited to 80 and 443**, and only `CONNECT` is proxied. Plain HTTP would mean becoming
  a real forwarding proxy; refusing it keeps this small enough to reason about, and registries are
  HTTPS.
- **The sandbox resolves nothing.** No `/etc/resolv.conf`: it hands the proxy a name and the proxy
  resolves it on the host, which is the only place the answer can be checked. A resolver inside
  would be a second, unchecked opinion.
- **A minimal synthetic `/etc/hosts` is bound in**, for every gate, network or not. Not for the
  network — it is how `localhost` resolves to the sandbox's *own* loopback. Without it vitest dies
  at startup with `EAI_AGAIN` before running a test. Synthesised rather than bound from the host,
  whose `/etc/hosts` names this machine's LAN.
- The proxy is started per gate and torn down on every exit from it, so nothing outlives the run it
  served. If it fails to come up, the gate takes the could-not-run path and the item is refused.

## Consequences

**A `test_net` suite can reach a package registry and nothing on this machine.** Verified end to
end: a real service on the host's loopback is unreachable from the gate with and without
`test_net`, while the sandbox's own loopback still works, so a suite that starts its own test server
is unaffected.

**All three network-dependent fleet gates still pass** — macrolens (`npm ci && npm test`),
market-digest and valuelens (`uv run`), measured after the change, not assumed. npm and uv both
honour the proxy variables.

**Egress is now logged, per destination, per gate.** `<item>/egress.log` records every allow and
refuse. That did not exist before: `--share-net` was unobservable by construction.

**`python3` becomes load-bearing for `test_net` repos**, on both sides of the boundary. It is
already a hard dependency of every entry point, and both scripts are stdlib-only like the rest of
`lib/`.

## Residual risk

- **A registry is still a supply chain.** The proxy governs *where* a suite may connect, not what it
  downloads. `npm ci` runs lifecycle scripts from whatever the registry serves — that is the whole
  reason for ADR 0026's sandbox, and this narrows the exposure rather than removing it.
- **Traffic is not inspected**, only routed. CONNECT is opaque by design; the proxy cannot tell a
  package download from an exfiltration to the same host. Worktree content can still leave through
  an allowed destination.
- **The port allowlist is coarse.** Anything a public host serves on 443 is reachable, including a
  paste site. A per-repo destination allowlist would be the next tightening, and is only worth it
  once there is evidence of what the fleet actually needs.
- **The host resolver is trusted.** A poisoned DNS answer that returns a public address routes the
  suite somewhere unintended; the policy only guarantees the destination is not *internal*.

## Alternatives considered

**`slirp4netns` or `pasta`.** The standard rootless-networking answer, and neither is installed —
apt offers no candidate here. They would also not solve the problem on their own:
`--disable-host-loopback` blocks the host's loopback, but the LAN stays reachable through the NAT,
which is half the exposure. A proxy is the layer where "which destination" can actually be decided.

**Firewall rules inside the sandbox.** `--unshare-user` maps the invoking uid, not root, so there is
no `CAP_NET_ADMIN`; and `nftables`/`iptables` are not installed either. Mapping uid 0 into the
namespace to gain the capability would grant it in a namespace whose network is already empty.

**Keep `--share-net` and document the exposure.** What ADR 0026 effectively did. The exposure was
mis-stated there, and a documented hole in the one control standing between candidate test code and
this host's services is not a control.

**Drop `test_net` entirely and pre-populate dependency caches.** Genuinely stronger — no egress at
all — and still a separate project per ecosystem, as ADR 0026 already argued. It composes with this:
a repo whose cache is warm simply stops setting `test_net`.
