#!/usr/bin/env python3
import argparse
import json
import re
import shutil
import sys
from pathlib import Path


CASE_ID_RE = re.compile(r"^(setup|skill|daily|memory|action|recovery)_\d{3}$")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def case_id_from_run_dir(run_dir, batch_id):
    name = run_dir.name
    prefix = f"{batch_id}-"
    if name.startswith(prefix):
        candidate = name[len(prefix) :]
        if CASE_ID_RE.match(candidate):
            return candidate
    match = re.search(r"(setup|skill|daily|memory|action|recovery)_\d{3}$", name)
    if match:
        return match.group(0)
    return name


def case_ids_from_data_dir(data_dir):
    case_ids = []
    for path in sorted(data_dir.glob("*.json")):
        try:
            payload = read_json(path)
        except Exception as exc:
            print(f"WARNING: skip unreadable case json {path}: {exc}", file=sys.stderr)
            continue
        case_id = payload.get("case_id") if isinstance(payload, dict) else None
        if isinstance(case_id, str) and CASE_ID_RE.match(case_id):
            case_ids.append(case_id)
    return case_ids


def inspect_run_dir(run_dir, batch_id):
    case_id = case_id_from_run_dir(run_dir, batch_id)
    trajectory_path = run_dir / "trajectory" / "trajectory.json"
    if not trajectory_path.exists():
        return {
            "case_id": case_id,
            "path": run_dir,
            "completed": False,
            "reason": "missing trajectory/trajectory.json",
        }
    try:
        status = read_json(trajectory_path).get("status")
    except Exception as exc:
        return {
            "case_id": case_id,
            "path": run_dir,
            "completed": False,
            "reason": f"unreadable trajectory/trajectory.json: {exc}",
        }
    if status == "completed":
        return {"case_id": case_id, "path": run_dir, "completed": True, "reason": "completed"}
    return {
        "case_id": case_id,
        "path": run_dir,
        "completed": False,
        "reason": f"status={status!r}",
    }


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Inspect a batch run directory, optionally delete incomplete run "
            "subdirectories, and print HERMES_ADAPTER_CASES for reruns."
        )
    )
    parser.add_argument("run_dir", type=Path, help="Batch run directory to inspect.")
    parser.add_argument(
        "--data-dir",
        type=Path,
        help=(
            "Optional case data directory. When provided, case ids that never "
            "created a run subdirectory are also included in HERMES_ADAPTER_CASES."
        ),
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        help="Delete incomplete direct child run directories. Without this, only report.",
    )
    args = parser.parse_args()

    root = args.run_dir.expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"Run directory does not exist: {root}")

    batch_id = root.name
    child_dirs = sorted(path for path in root.iterdir() if path.is_dir())
    rows = [inspect_run_dir(path, batch_id) for path in child_dirs]

    completed = [row for row in rows if row["completed"]]
    incomplete = [row for row in rows if not row["completed"]]

    completed_ids = {row["case_id"] for row in completed}
    incomplete_ids = [row["case_id"] for row in incomplete]
    missing_ids = []

    if args.data_dir:
        data_dir = args.data_dir.expanduser().resolve()
        if not data_dir.is_dir():
            raise SystemExit(f"Data directory does not exist: {data_dir}")
        for case_id in case_ids_from_data_dir(data_dir):
            if case_id not in completed_ids and case_id not in incomplete_ids:
                missing_ids.append(case_id)

    rerun_ids = incomplete_ids + missing_ids

    print(f"Run dir: {root}")
    print(f"Subdirectories: {len(child_dirs)}")
    print(f"Completed: {len(completed)}")
    print(f"Incomplete subdirectories: {len(incomplete)}")
    if args.data_dir:
        print(f"Not started from data dir: {len(missing_ids)}")
    print(f"Rerun case count: {len(rerun_ids)}")

    if incomplete:
        print("")
        print("Incomplete subdirectories:")
        for row in incomplete:
            print(f"  {row['case_id']}: {row['reason']} :: {row['path']}")

    if missing_ids:
        print("")
        print("Not started case ids:")
        for case_id in missing_ids:
            print(f"  {case_id}")

    print("")
    print('HERMES_ADAPTER_CASES="' + " ".join(rerun_ids) + '"')

    if not args.delete:
        print("")
        print("Dry run only. Re-run with --delete to remove incomplete subdirectories.")
        return 0

    print("")
    print("Deleting incomplete subdirectories:")
    for row in incomplete:
        print(f"  {row['path']}")
        shutil.rmtree(row["path"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
