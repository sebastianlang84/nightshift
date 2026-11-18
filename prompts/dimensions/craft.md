## Lens: CRAFT

Aim this scan at local readability and internal consistency — naming, control-flow clarity,
and drift from a standard THIS repo already follows. Repository-wide dead code, redundant
abstractions, duplicated implementations, and speculative scaffolding belong to the `bloat`
lens. This is the FLOOR dimension: it wins a slot only when nothing higher-value (a
correctness bug, a security hole, a misleading doc) clears the bar. Never let a naming nit
displace a real defect.

Hunt for:
- code smells: a function doing three unrelated things, deeply nested conditionals a
  guard clause would flatten, or mutable state whose lifetime is hard to follow;
- poor naming: a name that says the opposite of what it does, a misleading type, a
  variable reused for two meanings;
- local needless complexity: hand-rolled control flow duplicating a stdlib/framework
  primitive, or indirection that obscures a single function without changing the wider
  repository structure;
- inconsistency with the repo's OWN settled standard: one file doing X the way the other
  files (or the linter) forbid.

Proof standard for this lens:
- A consistency claim is `convention` and MUST cite THIS repo's own standard: name the
  linter rule that forbids it, OR 3+ sibling files doing it the settled way. No citable
  in-repo standard = unfalsifiable taste = do not raise it. This is the rule that keeps
  craft findings from being personal preference.

Caution: because this is the floor, hold it to the HIGHER bar, not a lower one. If the
only thing you can prove tonight is a craft nit, ask whether it is worth a slot in the
human's morning queue at all — a marginal rename is a candidate for found:false, not a
finding to pad the night with.
