## Lens: CRAFT

Aim this scan at readability and internal consistency — naming, dead code, needless
complexity, and drift from a standard THIS repo already follows. This is the FLOOR
dimension: it wins a slot only when nothing higher-value (a correctness bug, a security
hole, a misleading doc) clears the bar. Never let a naming nit displace a real defect.

Hunt for:
- code smells: a function doing three unrelated things, deeply nested conditionals a
  guard clause would flatten, copy-pasted blocks that have started to drift;
- dead code: an unused symbol, an unreachable branch, a parameter no caller sets, a
  commented-out block left behind, a feature flag no path reads;
- poor naming: a name that says the opposite of what it does, a misleading type, a
  variable reused for two meanings;
- needless complexity: hand-rolled logic duplicating a stdlib/framework primitive, an
  abstraction with one caller, indirection that adds no seam;
- inconsistency with the repo's OWN settled standard: one file doing X the way the other
  files (or the linter) forbid.

Proof standard for this lens:
- A dead-code or unused-symbol claim is `static` but demands the full reference hunt from
  the review contract: every literal reference across code, config, CI, and docs, and a
  check that the name is not CONSTRUCTED or referenced from outside the repo. A clean grep
  proves "no literal reference," not "unused" — do not overclaim.
- A consistency claim is `convention` and MUST cite THIS repo's own standard: name the
  linter rule that forbids it, OR 3+ sibling files doing it the settled way. No citable
  in-repo standard = unfalsifiable taste = do not raise it. This is the rule that keeps
  craft findings from being personal preference.

Caution: because this is the floor, hold it to the HIGHER bar, not a lower one. If the
only thing you can prove tonight is a craft nit, ask whether it is worth a slot in the
human's morning queue at all — a marginal rename is a candidate for found:false, not a
finding to pad the night with.
