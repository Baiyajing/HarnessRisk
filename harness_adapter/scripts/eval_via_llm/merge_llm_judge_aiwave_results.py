#!/usr/bin/env python3
"""Merge multiple LLM judge result directories and summarize performance."""

import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path


METRIC_KEYS = [
    "utility_score",
    "attack_success_rate",
    "persistence_score",
    "detection_score",
]


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def is_complete_judge(record):
    return isinstance(record, dict) and all(key in record for key in METRIC_KEYS)


def case_category(case_id):
    return str(case_id).split("_", 1)[0] if case_id else "unknown"


def mean_metrics(records):
    summary = {"count": len(records), "metrics": {}}
    for key in METRIC_KEYS:
        values = [int(record[key]) for record in records]
        summary["metrics"][key] = round(sum(values) / len(values), 4) if values else 0.0
    return summary


def load_result_dirs(result_dirs):
    records = []
    errors = []
    seen = set()
    for result_dir in result_dirs:
        result_dir = Path(result_dir).resolve()
        results_path = result_dir / "results"
        if not results_path.is_dir():
            raise FileNotFoundError(f"Missing results directory: {results_path}")
        for path in sorted(results_path.glob("*.json")):
            data = read_json(path)
            case_id = data.get("case_id") or path.stem
            source_key = (str(result_dir), case_id)
            if source_key in seen:
                errors.append(
                    {
                        "case_id": case_id,
                        "source_dir": str(result_dir),
                        "result_path": str(path),
                        "error": "duplicate case_id within source_dir",
                    }
                )
                continue
            seen.add(source_key)
            if not is_complete_judge(data):
                errors.append(
                    {
                        "case_id": case_id,
                        "source_dir": str(result_dir),
                        "result_path": str(path),
                        "error": data.get("error", "incomplete judge result"),
                    }
                )
                continue
            row = {"case_id": case_id, "category": case_category(case_id), "source_dir": str(result_dir), "result_path": str(path)}
            for key in METRIC_KEYS:
                row[key] = int(data[key])
            records.append(row)
    return records, errors


def build_summary(records, errors):
    by_category = defaultdict(list)
    for record in records:
        by_category[record["category"]].append(record)
    return {
        "overall": mean_metrics(records),
        "by_category": {category: mean_metrics(rows) for category, rows in sorted(by_category.items())},
        "valid_count": len(records),
        "error_count": len(errors),
        "errors": errors,
    }


def write_outputs(summary, records, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "merged_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_dir / "merged_case_metrics.csv").open("w", encoding="utf-8", newline="") as f:
        fieldnames = ["case_id", "category", "source_dir", "result_path", *METRIC_KEYS]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(records)
    with (output_dir / "merged_category_metrics.csv").open("w", encoding="utf-8", newline="") as f:
        fieldnames = ["category", "count", *METRIC_KEYS]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for category, category_summary in summary["by_category"].items():
            row = {"category": category, "count": category_summary["count"]}
            row.update(category_summary["metrics"])
            writer.writerow(row)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Merge LLM judge result directories and summarize metrics.")
    parser.add_argument("result_dirs", nargs="+", help="One or more llm_judge_aiwave directories.")
    parser.add_argument("--output-dir", default="", help="Optional directory for merged_summary.json and CSV files.")
    args = parser.parse_args(argv)

    records, errors = load_result_dirs(args.result_dirs)
    summary = build_summary(records, errors)
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))

    if args.output_dir:
        write_outputs(summary, records, Path(args.output_dir).resolve())
    return 0 if records else 1


if __name__ == "__main__":
    raise SystemExit(main())
