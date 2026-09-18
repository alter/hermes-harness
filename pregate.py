# pregate.py
from __future__ import annotations

import argparse
import pathlib
import re
import sys

DEFAULT_PATTERN = r"^(?:FAILED|ERROR)\s+(\S+)"

GO = 0       # nothing new is broken: the change is worth a reader's time
BACK = 1     # the change broke something that was not broken before
UNKNOWN = 2  # the baseline says nothing usable, so decide nothing on it


def failures(text: str, pattern: str) -> set[str]:
    found = set()
    for match in re.finditer(pattern, text, re.M):
        found.add(match.group(1) if match.groups() else match.group(0))
    return found


def compare(baseline: str, work: str, baseline_rc: int, work_rc: int, pattern: str) -> tuple[int, list[str]]:
    before = failures(baseline, pattern)
    after = failures(work, pattern)
    if baseline_rc != 0 and not before:
        # The check failed at the baseline and named nothing: a collection error,
        # a missing dependency, the wrong directory. Whatever it is, it is not a
        # measurement, and a gate built on it would reject honest work.
        return UNKNOWN, []
    new = sorted(after - before)
    if new:
        return BACK, new
    if work_rc != 0 and baseline_rc == 0:
        return BACK, []
    return GO, []


def main() -> int:
    parser = argparse.ArgumentParser(prog="pregate.py")
    parser.add_argument("baseline")
    parser.add_argument("work")
    parser.add_argument("--baseline-rc", type=int, default=0)
    parser.add_argument("--work-rc", type=int, default=0)
    parser.add_argument("--pattern", default=DEFAULT_PATTERN)
    args = parser.parse_args()

    read = lambda path: pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    try:
        verdict, new = compare(read(args.baseline), read(args.work),
                               args.baseline_rc, args.work_rc, args.pattern)
    except OSError as exc:
        print(f"the outputs could not be read: {exc}", file=sys.stderr)
        return UNKNOWN
    for name in new:
        print(name)
    return verdict


if __name__ == "__main__":
    sys.exit(main())
