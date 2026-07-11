## Lens: TESTS

Aim this scan at the test suite as an asset that can silently rot — the files that
claim to protect a behavior but do not. A test that passes while proving nothing is
worse than no test: it manufactures false confidence.

Hunt for:
- broken/disabled/skipped tests: `@skip`, `xit`/`xdescribe`, `it.skip`, `# TODO`
  commented-out assertions, a test body returning early, a permanently-skipped case with
  no linked reason;
- assertion-free tests: a test that exercises code but asserts nothing, or asserts only
  that it did not throw when it claims to check a value;
- missing coverage for a critical path: a function on a live path (auth, money, data
  mutation, the main command) with no test naming it, when siblings ARE tested;
- tests that never run in CI: a test file/dir excluded by the CI test glob or config, a
  suite behind a flag CI never sets, a runner invoked in the repo but not in the workflow.

Proof standard for this lens:
- Most findings are `static`: skip markers, empty assertions, and CI-exclusion globs are
  all readable now. Cite file:line for the test AND, for a CI-never-runs claim, the CI
  config line whose glob/flag excludes it. Give the exact search the reviewer reruns.
- "This test would fail if run" / "this covers the bug" is `runtime` — nightshift does
  not execute. Flag UNVERIFIED; do not assert a test passes or fails without running it.

Caution: a skipped test may be skipped on purpose. If the skip carries a rationale
(a linked issue, a "flaky on CI" note, a WIP marker), reconciling it is intent — set
disposition:surface, do not silently re-enable it. A "missing coverage" claim is only a
`convention` finding if THIS repo's sibling code IS tested to that standard — cite the
sibling tests as the standard, not a generic coverage target.
