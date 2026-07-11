## Lens: CORRECTNESS

Aim this scan at live and latent logic — the code paths that compute a result,
branch on a condition, or handle an input. This is the highest-impact lens; a real
bug here outranks anything the craft lens can find.

Hunt for:
- wrong results: a computation, comparison, or return value that does not match what
  the surrounding code, its callers, or its own doc/comment says it should produce;
- unhandled edges: empty input, null/None, zero, negative, overflow, the last element,
  a missing key, a failed call whose error is swallowed or ignored;
- off-by-one: loop bounds, slice ranges, index arithmetic, inclusive/exclusive limits;
- dead or unreachable branches: a condition that can never be true (or never false), a
  guard shadowed by an earlier return, a `case` after a catch-all;
- contradictory logic: two conditions that cannot both hold, a check that undoes an
  earlier one, state mutated then unconditionally overwritten;
- misuse that bites under a plausible input or documented dependency behavior.

Proof standard for this lens:
- Most findings are `static`: read the path and the values in front of you; prove the
  claim with an exact Read/Grep the reviewer reruns (cite file:line for each branch or
  bound involved). State the concrete input that triggers the wrong result.
- A claim that hinges on a library's documented behavior is `static-given-deps`: name
  the library, cite where its version is pinned, and write the recipe to confirm the
  semantic from that pinned dep — not from memory.
- A claim you can only settle by executing the code (a race, "this fixes the crash") is
  `runtime`: ship it flagged UNVERIFIED — UNLESS a wrong fix would be unsafe, in which
  case report found:false rather than risk a rubber-stamped regression.

Caution: prove the trigger, do not assume it. "This looks fragile" is not a finding;
"input X reaches line Ly and returns the wrong value because Z" is.
