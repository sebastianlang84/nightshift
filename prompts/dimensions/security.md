## Lens: SECURITY

Aim this scan at the trust boundaries — where the code takes external input, spawns a
process, builds a query or path, reads a credential, or exposes a port. A provable
security hole outranks craft and most correctness nits.

Hunt for:
- secrets committed to the repo: keys, tokens, passwords, connection strings in source,
  config, fixtures, `.env` files, or CI definitions;
- injection: user/argument data concatenated into a SQL query, a shell command, a file
  path, or an eval — SQL/shell/path/template injection;
- authz gaps: an endpoint, command, or handler that skips an ownership or role check a
  sibling path performs;
- unsafe defaults: debug mode on, auth disabled, TLS verification off, wildcard trust;
- over-broad CORS, exposed ports, or bound-to-0.0.0.0 services that need not be;
- missing input validation on data that crosses a boundary before it is trusted.

CRITICAL — never leak the secret you report. Do NOT quote, paste, echo, or reproduce a
secret VALUE in ANY output field — not the claim, not the summary, not the verify
recipe. Report only its LOCATION (file:line) and its CLASS (e.g. "AWS access key",
"Postgres password", "generic API token"). Write the verify recipe as a search the
reviewer runs to see the value themselves (grep the key name / the assignment), never
as the value itself. A finding that reprints the secret is worse than no finding — it
copies the leak into the branch, the ledger, and the review queue.

Proof standard for this lens:
- Most findings are `static`: the vulnerable construction is visible in the source —
  cite file:line and the exact grep. For a committed secret, prove presence by pattern/
  location, not by disclosure.
- If the risk depends on a library's documented behavior (an ORM that does/doesn't
  escape, a framework default), it is `static-given-deps`: name and cite the pinned dep.
- "Exploitable at runtime" beyond what the source shows is `runtime`: flag UNVERIFIED,
  and if a wrong fix would itself weaken security, report found:false instead of guessing.

Caution: an unsafe-default finding is a `convention` claim only if THIS repo's own
sibling config sets the safe value — cite that sibling, never generic hardening dogma.
