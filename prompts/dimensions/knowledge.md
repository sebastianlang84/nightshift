## Lens: KNOWLEDGE

Aim this scan at a maintained Markdown knowledge base: one canonical home per claim, strong links,
traceable sources, explicit freshness, and short prose that earns retrieval cost. This is not the
`docs` lens. `docs` compares documentation with code; `knowledge` checks whether the corpus itself
is coherent, navigable, grounded, and current.

Hunt for:
- redundant concepts or repeated evidence/history that should collapse into one canonical page;
- direct or implied contradictions, especially newer claims that fail to supersede older ones;
- filler, generic throat-clearing, repeated conclusions, fake precision, and other AI-shaped prose
  that carries no decision, evidence, constraint, or retrieval value;
- missing relations: orphan concepts, absent index entries, weak neighboring links, and important
  ideas mentioned repeatedly without their own canonical page;
- metadata drift: wrong/missing title, description, type, status, provenance, generated timestamp,
  verification, freshness, or attestation fields;
- broken maintenance loops: sources not integrated into existing concepts, queries whose durable
  answers never return to the corpus, and lint that checks syntax but not contradictions/staleness.

Use the injected `knowledge_probe` as deterministic evidence, not as the whole review. It checks the
portable structural subset and never executes target-repo code. A clean report does not prove that
claims agree; a warning is not automatically valuable enough for a finding. Read any repo-local
schema, README, agent instructions, type vocabulary, and linter source before applying house rules.
OKF v0.2 deliberately permits missing optional metadata and broken links, so distinguish baseline
conformance from a stricter local policy. Never invent an OKF requirement.

For this lens, REPLACE the generic code invariant matrix with exactly these keys in
`coverage.invariants`:
- `canonicality`: trace at least one repeated topic across every candidate page and identify the
  canonical home, or show that the pages carry distinct claims;
- `consistency`: compare claims that share a noun, rule, status, or lifecycle and settle whether
  they agree, supersede one another, or genuinely conflict;
- `routing`: follow index and neighboring links into at least one concept and back out; check
  orphans, missing index entries, and whether progressive disclosure reaches the important pages;
- `provenance_trust`: trace at least one consequential claim to its source and verification state;
  distinguish source identity, human review, deterministic attestation, and unsupported assertion;
- `lifecycle_freshness`: inspect generated/modified/stale/deprecated signals and the ingest/query/lint
  loop; show how a newer source or correction would replace, retire, or re-verify existing knowledge.

Proof standard:
- A redundancy finding names every overlapping page, quotes only the minimum claim boundaries, and
  states what remains canonical versus deleted/moved. Similar wording alone is not duplicated meaning.
- A contradiction finding cites both propositions and the authority/freshness evidence. If the corpus
  does not identify which side wins, use `disposition:surface`.
- An AI-slop finding must remove enough text to materially improve retrieval or prevent a false claim;
  cosmetic tightening is below the value bar.
- A missing-link or metadata finding must show a real routing, trust, or maintenance failure. One
  optional OKF field being absent is not a defect by itself.
- Prefer one coherent consolidation over file-by-file cleanup. Never rewrite a human-verified claim
  merely to make nearby machine-generated prose consistent with it.

This lens is normally configured `findings-only` first. Semantic consolidation is easy to perform in
the wrong direction; surface ambiguity until the corpus names an authority.
