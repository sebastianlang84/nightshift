## Lens: DOCS

Aim this scan at the gap between what the docs SAY and what the code DOES — READMEs,
inline comments, ADRs, design notes, usage examples, help text. The impact that earns a
slot is a doc whose error would MISLEAD someone changing the code, not cosmetic prose.

Hunt for:
- docs-vs-code contradictions: a README/comment stating a default, path, flag, port, or
  behavior that the code contradicts;
- stale comments: a comment describing logic that has since changed, a `# returns X`
  above code that returns Y, a rationale for a branch that no longer exists;
- wrong commands/ports/URLs: a documented command that fails, a port/host/endpoint that
  no config sets, an install/run step that references a removed file or script;
- out-of-date examples: a code sample using a renamed function, a removed flag, or an old
  signature; a config example with a key the loader no longer reads.

Proof standard for this lens:
- Almost all findings are `static`: the contradiction is settled by reading both sides
  in THIS repo. Cite BOTH file:line locations — the doc claim AND the code that refutes
  it — and give the exact search the reviewer reruns to see the mismatch.
- A claim that a documented command fails only when run is `runtime`: flag UNVERIFIED
  unless the failure is visible statically (the referenced file/script does not exist —
  then it is `static`).

Caution: a doc and the code disagreeing does NOT tell you which is right. If fixing the
doc means siding with a value labelled temporary/WIP/placeholder/example, or the code
side contradicts a stated design rationale or the component's own documented purpose,
set disposition:surface — do not silently rewrite the doc to match possibly-wrong code,
or the code's intent out of a comment. Fix only when the repo names the authority.
