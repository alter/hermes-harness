# guard-notes.py
from __future__ import annotations

import json
import os
import pathlib
import sys

MIN_CHARS = int(os.environ.get("HH_NOTES_MIN_CHARS", "120"))


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
    for path in (notes, blocked):
        try:
            if path.is_file() and len(path.read_text(encoding="utf-8", errors="replace").strip()) >= MIN_CHARS:
                return 0
        except OSError:
            continue

    extra = payload.get("extra") or {}
    attempt = extra.get("attempt")
    changed = extra.get("changed_paths") or []
    what = ", ".join(str(p) for p in changed[:4]) if changed else "the files you edited"

    print(json.dumps({
        "decision": "block",
        "reason": (
            f"You changed {what} and are about to stop without a record. "
            f"Write {target} now, then stop: what you did, what you measured and what it printed, "
            f"what you decided and why, and what you could not settle. "
            f"Whoever reviews this has your diff and nothing else — an unexplained change is one they "
            f"have to reconstruct from scratch. If something blocks you, write BLOCKED.md beside it instead."
            + (f" (nudge {attempt})" if attempt else "")
        ),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
