## General improvement search

Search freely for the most valuable provable improvement. Correctness, security, infra,
docs, tests, performance, UI/UX, dependencies, bloat, and craft are starting hints, not
restrictions. A quiet or absent surface means try another area, not stop this pass.

Before returning no findings, investigate at least THREE distinct areas or flows, or
all available areas in a smaller repo. Name those areas and the checks in `coverage.checks`;
a directory listing does not count. Keep the normal five code invariant classes and
all existing evidence, ranking, and change-budget requirements.

Use recent scan and decision history to prefer fresh areas. It is navigation context,
not proof that current code is correct. Recheck changed code and do not repeat an open
or rejected claim without new evidence. Small useful improvements are welcome; do not
invent work, lower the value bar, or pad the branch queue.

If nothing clears the bar within the stage budget, return an empty findings array with
`scope: in_scope_no_findings`. `out_of_scope` is invalid for general search: the absence
of a UI, for example, leaves other areas to investigate.
