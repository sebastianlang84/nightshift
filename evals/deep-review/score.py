#!/usr/bin/env python3
"""Score historical deep-review replays with frozen, explicit semantic anchors."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def finding_text(finding: dict[str, object]) -> str:
    fields = ("summary", "claim", "verify", "file", "symbol")
    return " ".join(str(finding.get(field, "")) for field in fields).lower()


def matches(finding: dict[str, object], groups: list[list[str]]) -> bool:
    text = finding_text(finding)
    return all(any(re.search(pattern, text, re.I) for pattern in group) for group in groups)


def main(results_arg: str) -> None:
    root = Path(__file__).resolve().parent
    cases = json.loads((root / "cases.json").read_text(encoding="utf-8"))
    results = Path(results_arg)
    rows = []
    total_cost = 0.0
    for case in cases:
        path = results / case["name"] / "result.json"
        result = json.loads(path.read_text(encoding="utf-8"))
        findings = result["finding"].get("findings", [])
        ranks = [i + 1 for i, finding in enumerate(findings) if matches(finding, case["match_groups"])]
        cost = float(result.get("recon_usage", {}).get("cost_usd") or 0) + float(
            result.get("explore_usage", {}).get("cost_usd") or 0
        )
        total_cost += cost
        rows.append(
            {
                "name": case["name"],
                "hit_at_1": bool(ranks and ranks[0] <= 1),
                "hit_at_3": bool(ranks and ranks[0] <= 3),
                "rank": ranks[0] if ranks else None,
                "findings": len(findings),
                "cost_usd": cost,
            }
        )
    summary = {
        "hit_at_1": sum(row["hit_at_1"] for row in rows),
        "hit_at_3": sum(row["hit_at_3"] for row in rows),
        "total": len(rows),
        "cost_usd": total_cost,
        "pass": sum(row["hit_at_3"] for row in rows) >= 3,
        "cases": rows,
    }
    (results / "score.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    raise SystemExit(0 if summary["pass"] else 1)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: score.py RESULTS_DIR")
    main(sys.argv[1])
