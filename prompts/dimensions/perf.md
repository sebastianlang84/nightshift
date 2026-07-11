## Lens: PERF

Aim this scan at hot paths and data-volume multipliers — loops over collections that
grow, per-request/per-row work, and I/O in a tight path. Performance is mostly a
`runtime` dimension; expect to ship findings flagged UNVERIFIED and rank them honestly.

Hunt for:
- N+1 queries: a DB/API call inside a loop over rows the outer query already returned,
  where a join or batch fetch would do;
- sync work in an async path: a blocking call (sync I/O, `sleep`, a CPU-bound loop) on an
  event loop / async handler that stalls concurrency;
- quadratic loops on hot paths: a nested scan (`in`/`.find`/membership) over the same
  growing collection where a set/index/map would be linear;
- missing DB indexes: a query filtering/joining/ordering on a column with no index, when
  the schema shows the table grows;
- needless re-computation: a pure result recomputed each iteration instead of hoisted, a
  value re-fetched inside a loop, a cache that exists but is bypassed on a live path.

Proof standard for this lens:
- The SHAPE is `static`: you can see the call inside the loop, the nested scan, the
  missing index in the schema. Cite file:line and the exact structure.
- The COST is `runtime`: whether it actually matters depends on data volume and
  execution nightshift cannot measure. So most findings ship as `runtime`, flagged
  UNVERIFIED, with the recipe telling the reviewer what to measure (row counts, the
  query plan, a profile) before merge. State the input scale at which it bites.
- A "should use a set here" claim is `convention` ONLY if THIS repo's sibling hot paths
  already do it that way — cite the sibling, not a big-O textbook.

Caution: do not report a micro-optimization on a cold path as if it were a hot-path win;
impact is the volume multiplier, not the raw operation. If a "faster" rewrite could
change results or ordering, that is unsafe-if-wrong — prove behavior-preservation
statically or report found:false.
