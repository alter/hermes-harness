# guard-read.py
from __future__ import annotations

import json
import os
import pathlib
import shlex
import sys

LIMIT = int(os.environ.get("HH_READ_GUARD_LINES", "500"))
WHOLE_FILE_READERS = {"cat", "less", "more", "bat", "nl", "strings"}
WINDOWED_READERS = {"head", "tail"}
EXEMPT_SUFFIXES = {".md", ".json", ".toml", ".yaml", ".yml", ".lock", ".txt", ".cfg", ".ini"}
PROCESSED = ("|", ">", "<", "$(", "`")
UNBOUNDED = 1 << 30


def window_size(tokens: list[str]) -> int:
    size = 10
    i = 1
    while i < len(tokens):
        token = tokens[i]
        if token == "-n" and i + 1 < len(tokens):
            value = tokens[i + 1]
            return UNBOUNDED if value.startswith("+") else int(value) if value.lstrip("-").isdigit() else size
        if token.startswith("-n") and token[2:]:
            value = token[2:]
            return UNBOUNDED if value.startswith("+") else int(value) if value.lstrip("-").isdigit() else size
        if token.startswith("-") and token[1:].isdigit():
            return int(token[1:])
        i += 1
    return size


def line_count(path: pathlib.Path) -> int:
    try:
        with path.open("rb") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def judge(segment: str, cwd: pathlib.Path) -> str:
    try:
        tokens = shlex.split(segment)
    except ValueError:
        return ""
    if not tokens:
        return ""
    name = pathlib.Path(tokens[0]).name
    if name not in WHOLE_FILE_READERS and name not in WINDOWED_READERS:
        return ""
    allowed = UNBOUNDED if name in WINDOWED_READERS and window_size(tokens) >= UNBOUNDED else (
        window_size(tokens) if name in WINDOWED_READERS else 0
    )
    for token in tokens[1:]:
        if token.startswith("-"):
            continue
        path = pathlib.Path(os.path.expanduser(token))
        if not path.is_absolute():
            path = cwd / path
        if path.suffix.lower() in EXEMPT_SUFFIXES or not path.is_file():
            continue
        total = line_count(path)
        if total <= LIMIT:
            continue
        if allowed and allowed <= LIMIT:
            continue
        return (
            f"{token} is {total} lines and `{name}` would pour all of it into your context. "
            f"Find the part you need with search_files, then read_file with offset and limit, "
            f"or narrow the window (`{name} -n {LIMIT}`)."
        )
    return ""


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if (payload.get("tool_name") or "") != "terminal":
        return 0
    args = payload.get("tool_input") or {}
    command = args.get("command") if isinstance(args, dict) else None
    if not isinstance(command, str) or not command.strip():
        return 0
    if any(marker in command for marker in PROCESSED):
        return 0
    cwd = pathlib.Path(payload.get("cwd") or ".")
    for segment in command.replace("&&", ";").replace("||", ";").split(";"):
        reason = judge(segment.strip(), cwd)
        if reason:
            print(json.dumps({"decision": "block", "reason": reason}))
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
