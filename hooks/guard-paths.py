# guard-paths.py
from __future__ import annotations

import json
import os
import pathlib
import re
import shlex
import sys

PROTECTED_ROOT = os.environ.get("HH_PROTECTED_ROOT", "tasks")
WRITABLE_NAMES = set(filter(None, os.environ.get("HH_WRITABLE_NAMES", "NOTES.md,BLOCKED.md").split(",")))
V4A_FILE_HEADER = re.compile(r"^\*\*\*\s*(?:Update|Add|Delete)\s+File:\s*(.+)$", re.M)
V4A_MOVE_HEADER = re.compile(r"^\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)$", re.M)
REDIRECT = re.compile(r"[12]?>>?|\|\s*(?:tee|sponge)\b")
MUTATORS = {
    "sed", "awk", "perl", "python", "python3", "tee", "dd", "truncate", "install",
    "mv", "cp", "rm", "rmdir", "ln", "touch", "shred", "patch", "ed", "sponge",
}


def block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(2)


def protected(path_text: str, cwd: pathlib.Path) -> bool:
    if not path_text:
        return False
    candidate = pathlib.Path(os.path.expanduser(path_text))
    if not candidate.is_absolute():
        candidate = cwd / candidate
    try:
        resolved = candidate.resolve(strict=False)
    except OSError:
        resolved = candidate
    parts = resolved.parts
    if PROTECTED_ROOT not in parts:
        return False
    return resolved.name not in WRITABLE_NAMES


def written_paths(tool_name: str, args: dict) -> list[str]:
    if tool_name == "write_file":
        return [str(args.get("path") or "")]
    if tool_name != "patch":
        return []
    if (args.get("mode") or "replace") == "replace":
        return [str(args.get("path") or "")]
    body = args.get("patch") or ""
    if not isinstance(body, str):
        return []
    out = [m.group(1).strip() for m in V4A_FILE_HEADER.finditer(body)]
    for m in V4A_MOVE_HEADER.finditer(body):
        out.extend((m.group(1).strip(), m.group(2).strip()))
    return out


def command_touches_protected(command: str, cwd: pathlib.Path) -> str:
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    words = {t for t in tokens if t and not t.startswith("-")}
    mutator = bool(MUTATORS & {pathlib.Path(t).name for t in words}) or bool(REDIRECT.search(command))
    for token in tokens:
        if token.startswith("-"):
            continue
        if protected(token.strip("'\"<>"), cwd):
            if mutator:
                return f"the command would write inside {PROTECTED_ROOT}/ ({token})"
            return f"the command reaches into {PROTECTED_ROOT}/ ({token}) through the shell"
    if re.search(r"(?<![\w/])%s/" % re.escape(PROTECTED_ROOT), command) and mutator:
        return f"the command writes somewhere under {PROTECTED_ROOT}/"
    return ""


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError) as exc:
        block(f"guard-paths could not read its input ({exc}); refusing rather than guessing.")
    tool_name = payload.get("tool_name") or ""
    args = payload.get("tool_input") or {}
    if not isinstance(args, dict):
        args = {}
    cwd = pathlib.Path(payload.get("cwd") or ".")

    if tool_name in {"write_file", "patch"}:
        for path_text in written_paths(tool_name, args):
            if protected(path_text, cwd):
                block(
                    f"{path_text} is inside {PROTECTED_ROOT}/ and is not yours to write. "
                    f"The task tree is the record of what you were told to do and how it was judged; "
                    f"the harness writes status:, another reviewer writes verify:. "
                    f"Put what you learned in NOTES.md, or what stopped you in BLOCKED.md, and carry on."
                )
        return 0

    if tool_name == "terminal":
        command = args.get("command")
        if isinstance(command, str) and command.strip():
            reason = command_touches_protected(command, cwd)
            if reason:
                block(
                    f"Refused: {reason}. Read a task with read_file; write only NOTES.md or BLOCKED.md, "
                    f"and only with write_file or patch. Rephrasing this command will not help."
                )
    return 0


if __name__ == "__main__":
    sys.exit(main())
