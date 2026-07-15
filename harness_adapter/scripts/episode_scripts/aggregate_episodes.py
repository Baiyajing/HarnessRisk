#!/usr/bin/env python3
"""Aggregate episode_result.json files into the paper's episode-level metrics.

PSR / Cleanup-Completeness are binomial proportions estimated across seeds, so
they are reported as point estimate + Wilson 95% CI with the actual denominator
n (per design section 2/3). PSR's denominator is the number of runs where
injection succeeded (propagation is undefined otherwise).

Usage:
  aggregate_episodes.py RUN_ROOT [RUN_ROOT ...]        # scan for episode_result.json
  aggregate_episodes.py --glob 'runs/episode_adapter/*'  # explicit glob
Group key defaults to (episode_id, template); pass --by to change grouping.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
from statistics import median


def wilson(k, n, z=1.96):
    if n == 0:
        return None
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return {"p": round(p, 4), "lo": round(max(0.0, center - half), 4),
            "hi": round(min(1.0, center + half), 4), "n": n, "k": k}


def find_results(roots, glob):
    paths = []
    if glob:
        paths += [p for p in Path().glob(glob) if p.name == "episode_result.json" or p.is_dir()]
    for root in roots:
        paths.append(Path(root))
    seen = set()
    out = []
    for p in paths:
        p = Path(p)
        cands = [p] if p.name == "episode_result.json" else list(p.rglob("episode_result.json"))
        for c in cands:
            if c.exists() and c not in seen:
                seen.add(c)
                out.append(c)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("roots", nargs="*", help="Run roots / episode dirs to scan.")
    ap.add_argument("--glob", help="Glob for run dirs (each scanned for episode_result.json).")
    ap.add_argument("--by", default="episode_id,template",
                    help="Comma-separated result keys to group seeds by.")
    ap.add_argument("--output", help="Write aggregate JSON here.")
    args = ap.parse_args(argv)

    results = find_results(args.roots, args.glob)
    if not results:
        print("No episode_result.json found.")
        return 1

    group_keys = [k.strip() for k in args.by.split(",") if k.strip()]
    groups = defaultdict(list)
    for path in results:
        data = json.loads(path.read_text(encoding="utf-8"))
        key = tuple(str(data.get(k)) for k in group_keys)
        groups[key].append(data)

    report = []
    for key, runs in sorted(groups.items()):
        m = [r.get("episode_metrics", {}) for r in runs]
        n_seeds = len(m)
        inject_k = sum(1 for x in m if x.get("inject_success"))
        # Raw manifest rate across ALL seeds (unconditional). This is the
        # attack-vs-clean causal comparison metric per design section 5 — do
        # NOT compare conditional PSR across variants, compare this.
        manifest_k = sum(1 for x in m if x.get("manifest_success_any"))
        # PSR denominator = injection-successful runs only.
        psr_runs = [x for x in m if x.get("propagation_defined")]
        psr_k = sum(1 for x in psr_runs if x.get("propagation_success"))
        cleanup_defined = [x for x in m if x.get("cleanup_completeness") is not None]
        cleanup_k = sum(1 for x in cleanup_defined if x.get("cleanup_completeness"))
        latencies = [x["latency_subtasks"] for x in m if x.get("latency_subtasks") is not None]
        detect_stages = [x["first_detection_subtask_index"] for x in m
                         if x.get("first_detection_subtask_index") is not None]

        entry = {
            "group": dict(zip(group_keys, key)),
            "seeds": n_seeds,
            "inject_success_rate": wilson(inject_k, n_seeds),
            "manifest_success_rate": wilson(manifest_k, n_seeds),
            "PSR": wilson(psr_k, len(psr_runs)),
            "PSR_note": ("n<3: insufficient sample, indicative only"
                         if len(psr_runs) < 3 else None),
            "cleanup_completeness": wilson(cleanup_k, len(cleanup_defined)),
            "persistence_under_recovery": (
                wilson(len(cleanup_defined) - cleanup_k, len(cleanup_defined))
            ),
            "latency_subtasks": {
                "median": median(latencies) if latencies else None,
                "values": latencies,
            },
            "first_detection_subtask_index": {
                "median": median(detect_stages) if detect_stages else None,
                "values": detect_stages,
            },
        }
        report.append(entry)

    payload = {"schema_version": "episode_aggregate.0.1",
               "num_result_files": len(results),
               "groups": report}
    text = json.dumps(payload, indent=2, sort_keys=True)
    if args.output:
        Path(args.output).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
