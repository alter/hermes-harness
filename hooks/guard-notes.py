# guard-notes.py
from __future__ import annotations

import json
import os
import pathlib
import sys

MIN_CHARS = int(os.environ.get("HH_NOTES_MIN_CHARS", "120"))
NOT_CHECKED = "(not checked)"
WRITE_HERE = "(write here)"


def unfilled(text: str) -> list[str]:
    rows = []
    for line in text.splitlines():
        if NOT_CHECKED in line and line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rows.append(cells[0] if cells else line.strip())
    if WRITE_HERE in text:
        rows.append("a section still reading " + WRITE_HERE)
    return rows


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0

    target = os.environ.get("HH_NOTES_FILE", "").strip()
    if not target:
        return 0

    notes = pathlib.Path(target)
    blocked = notes.with_name("BLOCKED.md")
    try:
        if blocked.is_file() and len(blocked.read_text(encoding="utf-8", errors="replace").strip()) >= MIN_CHARS:
            return 0
    except OSError:
        pass

    text = ""
    try:
        if notes.is_file():
            text = notes.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""

    extra = payload.get("extra") or {}
    attempt = extra.get("attempt")
    changed = extra.get("changed_paths") or []
    what = ", ".join(str(p) for p in changed[:4]) if changed else "the files you edited"
    tag = f" (nudge {attempt})" if attempt else ""

    missing = unfilled(text)
    if missing:
        listed = "; ".join(missing[:6]) + ("; …" if len(missing) > 6 else "")
        print(json.dumps({
            "decision": "block",
            "reason": (
                f"You changed {what} and are about to stop with {target} still unfilled: {listed}. "
                f"Fill each row from something you actually ran or read — the command and what it printed, "
                f"or the file and what it says. A row you cannot fill is a finding: write why in it. "
                f"If something blocks you entirely, write BLOCKED.md beside it instead." + tag
            ),
        }))
        return 0

    if len(text.strip()) >= MIN_CHARS:
        return 0

    print(json.dumps({
        "decision": "block",
        "reason": (
            f"You changed {what} and are about to stop without a record. "
            f"Write {target} now, then stop: what you did, what you measured and what it printed, "
            f"what you decided and why, and what you could not settle. "
            f"Whoever reviews this has your diff and nothing else — an unexplained change is one they "
            f"have to reconstruct from scratch. If something blocks you, write BLOCKED.md beside it instead."
            + tag
        ),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
