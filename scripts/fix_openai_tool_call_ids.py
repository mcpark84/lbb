#!/usr/bin/env python3
"""Fix OpenAI trajectory datasets whose tool messages lack ``tool_call_id``.

SWE-Hero exports flatten every message into a uniform ``{role, content,
tool_calls}`` record. Two spec violations result:

  - tool messages lose the OpenAI-required ``tool_call_id`` (they carry a
    meaningless ``"tool_calls": null`` instead)
  - system/user messages carry a spec-foreign ``"tool_calls": null`` key

Strict OpenAI-compatible frontends (e.g. Dynamo's Rust serde) reject such
tool messages with HTTP 400 "missing field `tool_call_id`", which breaks
every replay turn whose prefix contains a tool result.

Repair (in place, atomic replace):
  - tool messages: set ``tool_call_id`` from the nearest preceding
    assistant's ``tool_calls`` (matched in call order — the OpenAI protocol
    requires tool results to follow their calls in order) and drop the
    bogus ``tool_calls`` key
  - all other roles: drop a null ``tool_calls`` key (assistant messages
    keep their real, non-null ``tool_calls``)

Originals are recoverable from the danmcpark84/lbb image (/app/config),
so no backup files are written.

Usage:
    python3 scripts/fix_openai_tool_call_ids.py config/swe_openai_*.json config/claude_code_openai_1000.json
    python3 scripts/fix_openai_tool_call_ids.py --dry-run config/*.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


def fix_messages(messages: list[dict]) -> dict:
    """Repair one trajectory's message list in place. Returns stats."""
    stats = {"tool_fixed": 0, "tool_synthetic": 0, "null_keys_dropped": 0}
    pending: list[str] = []
    for msg in messages:
        role = msg.get("role")
        if role == "assistant" and msg.get("tool_calls"):
            pending = [
                tc.get("id") or f"call_{i}"
                for i, tc in enumerate(msg["tool_calls"])
            ]
            continue
        if role == "tool":
            if "tool_calls" in msg:
                del msg["tool_calls"]
                stats["null_keys_dropped"] += 1
            if not msg.get("tool_call_id"):
                if pending:
                    msg["tool_call_id"] = pending.pop(0)
                else:
                    msg["tool_call_id"] = "call_0"
                    stats["tool_synthetic"] += 1
                stats["tool_fixed"] += 1
            elif pending:
                pending.pop(0)
        elif msg.get("tool_calls") is None and "tool_calls" in msg:
            del msg["tool_calls"]
            stats["null_keys_dropped"] += 1
    return stats


def verify_messages(messages: list[dict]) -> int:
    """Return the number of tool messages still missing tool_call_id."""
    return sum(
        1 for m in messages if m.get("role") == "tool" and not m.get("tool_call_id")
    )


def fix_file(path: Path, dry_run: bool) -> bool:
    """Fix one dataset file. Returns True on success."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, list) or not data or "messages" not in data[0]:
        print(f"[skip] {path}: not an OpenAI trajectory file (no messages key)")
        return True

    totals = {"tool_fixed": 0, "tool_synthetic": 0, "null_keys_dropped": 0}
    remaining = 0
    for traj in data:
        s = fix_messages(traj.get("messages", []))
        for k in totals:
            totals[k] += s[k]
        remaining += verify_messages(traj.get("messages", []))

    tag = "[dry-run]" if dry_run else "[fixed]"
    print(
        f"{tag} {path}: {len(data)} trajectories, "
        f"tool_call_id added={totals['tool_fixed']} "
        f"(synthetic={totals['tool_synthetic']}), "
        f"null tool_calls dropped={totals['null_keys_dropped']}, "
        f"still missing={remaining}"
    )
    if remaining:
        print(f"[error] {path}: {remaining} tool messages left unfixed", file=sys.stderr)
        return False

    if not dry_run:
        fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    args = parser.parse_args(argv)

    ok = True
    for path in args.files:
        ok = fix_file(path, args.dry_run) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
