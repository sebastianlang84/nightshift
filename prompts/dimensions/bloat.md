## Lens: BLOAT

Aim this scan at code that makes the repository larger or harder to navigate without
carrying distinct behavior. This is the dead-code and structural-slop lens: judge the
observable code shape, never whether a human or a model authored it. Prefer deletion or
consolidation over another abstraction.

Hunt for:
- dead surfaces: unreachable branches, unused symbols/files/parameters, stale feature
  flags, abandoned compatibility paths, commented-out implementations, and exports with
  no live consumer;
- redundant implementations: near-identical helpers, validators, adapters, DTOs, or
  configuration layers that encode the same policy and can already drift independently;
- speculative scaffolding: interfaces with one implementation and no testing seam,
  wrappers that only rename a call, generic factories used once, and extension points with
  no declared consumer;
- defensive clutter: fallback chains for impossible states, broad exception handling that
  only returns the existing default, repeated validation after the invariant is established,
  and compatibility code without a supported old input or version;
- narration and indirection that hide the path: comments/docstrings that merely restate the
  next line, pass-through modules, re-export mazes, and helper fragmentation that turns one
  operation into a search across files.

Proof standard for this lens:
- A dead-code claim is `static`, but a literal reference search alone is insufficient. Trace
  every entry point and caller across code, config, templates, tests, CI, docs, registries,
  dependency injection, reflection/dynamic import, serialization names, and external/public
  API boundaries. Use the language's compiler/linter or a structural/code graph when one is
  available. If a dynamic or external consumer cannot be ruled out, do not claim deletion is
  safe.
- A redundancy claim must name the parallel paths, trace their callers, and show that they
  implement the same policy rather than superficially similar behavior. State the concrete
  simplification: which path becomes canonical and which files/lines/indirections disappear.
- A speculative-abstraction claim must prove the extension point has one real implementation
  and no repo-stated requirement for substitution, portability, compatibility, or public API
  stability. "Only one implementation today" is not enough when the seam is intentional.
- Never target generated/vendor code, migrations, protocol schemas, or compatibility layers
  merely because they are repetitive. Their duplication may be the contract.

Value bar: raise one coherent simplification that removes a meaningful maintenance surface or
collapses a misleading parallel path. A handful of verbose comments, a tiny wrapper, or a style
preference is not worth a review slot. Do not replace proven bloat with a new framework, utility
layer, or broad rewrite.
