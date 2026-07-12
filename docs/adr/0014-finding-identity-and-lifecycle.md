# ADR 0014 — finding identity and lifecycle

- Status: accepted
- Date: 2026-07-12
- Resolves: [OPEN-QUESTIONS.md §1 "Finding identity and lifecycle"](../../OPEN-QUESTIONS.md)

## Context

Nightshift must recognize the *same* defect across runs so it neither re-reports handled work nor
re-fixes it, and so a repeatedly-selected known item cannot crowd out new work. The v1 identity was
the model's free-form `fingerprint`, else `file:type:line_window` — both unstable: rewording changed
the string, line numbers drift, and multi-file descriptions ordered files arbitrarily. The
append-only ledger also lacked a defined carry / clear / invalidate lifecycle.

Constraints (decided): the v1 ledger is central and append-only; human verdicts outrank reconcile
([ADR 0007](0007-human-verdicts-outrank-machine-reconcile.md)); surfaced ambiguity stays human-owned
until cleared ([ADR 0006](0006-surface-intent-ambiguous-divergences.md)); wording and drifting line
numbers alone are insufficient identity.

## Decision

**1. Identity is Runner-canonical and layered.** The Runner (`finding_fingerprint`), not the model,
computes identity from normalized structured fields:

```
sorted(files) : normalized(type) : anchor
```

where `anchor` is the finding's `symbol` (the named code entity) when present, else a normalized
`snippet` (`:#…`), else omitted. Prose summary and line numbers are excluded by construction, so
identity survives rewording and line movement. Files are sorted, so multi-file order is irrelevant.
The model is asked to emit `symbol`/`files` (`prompts/explore.md`); its own `fingerprint` is used only
as a last-resort fallback when no structured anchor exists.

**2. Multi-file canonicalization.** `files` (or the single `file`) are de-duplicated and sorted before
joining, so the same finding described in any file order yields one identity.

**3. Lifecycle.** A fingerprint is *unresolved* while it has a `finding`/`shipped`/`abandoned` row and
no terminal verdict. Terminal verdicts (`harvest.sh verdict`): `merged`/`resolved` **clear** it;
`wontfix` **permanently ignores** it; `dropped` (branch deleted unmerged) is a human rejection. A
single suppression predicate (`_fp_suppressed`) drives all dedup: an identity is suppressed if it is
permanently ignored *or* has a prior row (in the relevant outcome set) whose content signature still
matches (see 5). Merged and dropped branches both release open-branch backpressure automatically,
since the cap counts git reality (unmerged branches), not ledger rows.

**4. Exploration receives known work.** Before Explore, the Runner injects the repo's still-open
findings/branches (`known_work`) into the prompt with an instruction to not re-report them and keep
searching, so the model does not spend its findings budget on items the Runner would only suppress.
Unresolved findings also persist in every later digest under **"Open findings (all nights)"** until a
human clears them.

**5. Invalidation via content signature.** Each finding/shipped/abandoned row stores `code_sig` — a
hash of its target files' blob shas at HEAD. When the underlying code changes, the signature changes
and the identity becomes eligible again (suppression requires a matching or absent signature). A
`wontfix` is the sole exception: it suppresses permanently, regardless of later code change.

## Consequences

- Rewording, line drift, and file-order changes no longer create duplicates; distinct symbols stay
  distinct. Same-file/same-type findings still collide unless the model supplies a `symbol`/`snippet`
  — the layered anchor is the mitigation, and a false merge is safer than a false split (it suppresses
  rather than duplicates).
- The ledger gains additive, nullable fields (`type`, `code_sig`); old rows with them absent are
  treated as signature-less (always match), i.e. suppressed as before — backward compatible.
- Invalidation is coarse (any change to a target file re-opens the identity); acceptable for v1.
- Covered by `tests/test-finding-identity.sh` across identity stability, starvation (known-work),
  carry-forward, and clearing (+ invalidation and wontfix permanence).
