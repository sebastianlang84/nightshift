# Deep-review replay

This opt-in eval measures whether Explore rediscovers four known, non-local defects on historical
pre-fix Nightshift snapshots. It runs the current Recon and Explore implementation with the real
Claude adapter, a three-finding budget, and the frozen lens and semantic anchors in `cases.json`.

```bash
evals/deep-review/run.sh
```

Requirements: authenticated `claude`, `jq`, Git, and optionally CodeMap. Results go to `/tmp` unless
an output directory is passed. The gate passes at three of four `hit@3`; `score.json` also records
`hit@1` and model cost. This is an explicit quality eval, not part of credential-free CI. Never
weaken cases or match anchors in the same change that tunes Explore.

`baseline.json` records the original 2026-08-19 result and the excluded, unreviewable ground truth.
`experiments/2026-08-19.json` records the controlled changes: breadth evidence alone stayed at 1/4;
the kept invariant matrix reached 3/4 `hit@3` at $17.60, with the suite-mutation case still missed.
