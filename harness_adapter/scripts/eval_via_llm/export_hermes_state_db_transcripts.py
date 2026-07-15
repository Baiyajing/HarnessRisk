#!/usr/bin/env python3
"""Export Hermes conversation history from per-case state.db files.

This fills each run's trajectory/transcripts.jsonl from
state/hermes-home/state.db so llm_judge_multi_harness_batch_aiwave.py can read
the saved user/assistant/tool messages.

Run template:
  python scripts/eval_via_llm/export_hermes_state_db_transcripts.py /path/to/batch_run_root --overwrite
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path


DEFAULT_DB_REL = Path("state/hermes-home/state.db")
DEFAULT_OUTPUT_REL = Path("trajectory/transcripts.jsonl")


def iter_run_dirs(root):
    root = Path(root)
    if (root / DEFAULT_DB_REL).exists():
        yield root
        return
    for path in sorted(root.iterdir()):
        if path.is_dir() and (path / DEFAULT_DB_REL).exists():
            yield path


def maybe_json(value):
    if not value:
        return value
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def open_readonly_sqlite(db_path):
    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def load_messages(db_path):
    conn = open_readonly_sqlite(db_path)
    try:
        available = {
            row["name"]
            for row in conn.execute("PRAGMA table_info(messages)").fetchall()
        }
        wanted = [
            "id",
            "session_id",
            "role",
            "content",
            "tool_call_id",
            "tool_calls",
            "tool_name",
            "timestamp",
            "finish_reason",
            "reasoning",
            "reasoning_content",
            "reasoning_details",
            "codex_reasoning_items",
            "codex_message_items",
            "platform_message_id",
            "observed",
            "active",
            "compacted",
        ]
        columns = [name for name in wanted if name in available]
        if not columns:
            raise sqlite3.Error("messages table has no recognized columns")
        where = "WHERE active = 1" if "active" in available else ""
        order_terms = [name for name in ("timestamp", "id") if name in available]
        order = "ORDER BY " + ", ".join(order_terms) if order_terms else ""
        query = f"SELECT {', '.join(columns)} FROM messages {where} {order}"
        rows = conn.execute(query).fetchall()
    finally:
        conn.close()
    return rows


def row_to_transcript_record(row, db_path, line_no):
    entry = {key: row[key] for key in row.keys() if row[key] is not None}
    for key in (
        "tool_calls",
        "reasoning_details",
        "codex_reasoning_items",
        "codex_message_items",
    ):
        if key in entry:
            entry[key] = maybe_json(entry[key])
    if entry.get("tool_name"):
        entry["toolName"] = entry["tool_name"]
    if entry.get("finish_reason"):
        entry["stop_reason"] = entry["finish_reason"]
    return {
        "line": line_no,
        "source": str(db_path),
        "entry": entry,
    }


def export_run(run_dir, output_rel, overwrite, dry_run):
    db_path = run_dir / DEFAULT_DB_REL
    output_path = run_dir / output_rel
    if output_path.exists() and output_path.stat().st_size > 0 and not overwrite:
        return {
            "run_dir": str(run_dir),
            "output": str(output_path),
            "status": "skipped_existing",
            "messages": None,
        }

    rows = load_messages(db_path)
    if dry_run:
        return {
            "run_dir": str(run_dir),
            "output": str(output_path),
            "status": "would_export",
            "messages": len(rows),
        }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        for line_no, row in enumerate(rows, 1):
            record = row_to_transcript_record(row, db_path, line_no)
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    return {
        "run_dir": str(run_dir),
        "output": str(output_path),
        "status": "exported",
        "messages": len(rows),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Export Hermes state.db messages into trajectory/transcripts.jsonl files."
    )
    parser.add_argument("batch_dir", help="Batch root directory, or a single per-case run directory.")
    parser.add_argument(
        "--output-name",
        default=str(DEFAULT_OUTPUT_REL),
        help="Output path relative to each run dir. Default: trajectory/transcripts.jsonl",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite a non-empty existing transcript file.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List what would be exported without writing files.",
    )
    args = parser.parse_args(argv)

    root = Path(args.batch_dir).resolve()
    output_rel = Path(args.output_name)
    run_dirs = list(iter_run_dirs(root))
    if not run_dirs:
        print(f"No Hermes state DBs found under {root}", file=sys.stderr)
        return 2

    results = []
    for run_dir in run_dirs:
        try:
            result = export_run(run_dir, output_rel, args.overwrite, args.dry_run)
        except sqlite3.Error as exc:
            result = {
                "run_dir": str(run_dir),
                "output": str(run_dir / output_rel),
                "status": "error",
                "error": str(exc),
                "messages": None,
            }
        results.append(result)
        msg = "" if result["messages"] is None else f" ({result['messages']} messages)"
        error = f" - {result['error']}" if result.get("error") else ""
        print(f"{result['status']}: {Path(result['run_dir']).name}{msg}{error}")

    summary = {
        "total": len(results),
        "exported": sum(1 for item in results if item["status"] == "exported"),
        "would_export": sum(1 for item in results if item["status"] == "would_export"),
        "skipped_existing": sum(1 for item in results if item["status"] == "skipped_existing"),
        "errors": sum(1 for item in results if item["status"] == "error"),
    }
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 1 if summary["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
