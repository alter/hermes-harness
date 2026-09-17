# tasks.py
from __future__ import annotations

import argparse
import pathlib
import re
import sys

READY_STATUSES = {"todo", "in_progress"}
AGENT_WRITABLE_LABELS = {"status"}
PRIORITY_ORDER = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
SECTION_RE = re.compile(r"^(TASK:|GOAL|CONTEXT|SCOPE|OUTCOME|VERIFY|ROLE|DEPENDS)\s*$", re.M)


def read_labels(task_dir: pathlib.Path) -> dict[str, str]:
    path = task_dir / "labels.txt"
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        out[key.strip()] = value.strip()
    return out


def write_label(task_dir: pathlib.Path, key: str, value: str) -> None:
    if key not in AGENT_WRITABLE_LABELS:
        raise ValueError(f"{key} is not ours to write: the harness owns only {sorted(AGENT_WRITABLE_LABELS)}")
    path = task_dir / "labels.txt"
    lines = path.read_text(encoding="utf-8").splitlines()
    replaced = False
    for i, line in enumerate(lines):
        if line.split(":", 1)[0].strip() == key:
            lines[i] = f"{key}: {value}"
            replaced = True
            break
    if not replaced:
        lines.append(f"{key}: {value}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def task_dirs(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted(p.parent for p in root.rglob("task.txt"))


def depends_met(root: pathlib.Path, labels: dict[str, str]) -> tuple[bool, str]:
    dep = labels.get("depends", "").strip()
    if not dep:
        return True, ""
    dep_dir = root / dep
    if not dep_dir.is_dir():
        return False, f"depends points nowhere: {dep}"
    dep_status = read_labels(dep_dir).get("status", "")
    if dep_status != "done":
        return False, f"depends {dep} is {dep_status or 'unlabelled'}, not done"
    return True, ""


def is_ready(root: pathlib.Path, task_dir: pathlib.Path) -> tuple[bool, str]:
    labels = read_labels(task_dir)
    if not labels:
        return False, "no labels.txt"
    status = labels.get("status", "")
    if status not in READY_STATUSES:
        return False, f"status is {status or 'unset'}"
    if "HUMAN" in re.split(r"[,\s]+", labels.get("role", "")):
        return False, "role is HUMAN"
    return depends_met(root, labels)


def next_task(root: pathlib.Path) -> pathlib.Path | None:
    candidates = []
    for task_dir in task_dirs(root):
        ready, _ = is_ready(root, task_dir)
        if ready:
            labels = read_labels(task_dir)
            candidates.append((PRIORITY_ORDER.get(labels.get("priority", ""), 9), str(task_dir), task_dir))
    if not candidates:
        return None
    candidates.sort()
    return candidates[0][2]


def section(body: str, name: str) -> str:
    starts = [(m.group(1), m.start(), m.end()) for m in SECTION_RE.finditer(body)]
    for i, (found, _, end) in enumerate(starts):
        if found.rstrip(":") != name:
            continue
        stop = starts[i + 1][1] if i + 1 < len(starts) else len(body)
        return body[end:stop].strip()
    return ""


def build_prompt(root: pathlib.Path, task_dir: pathlib.Path) -> str:
    body = (task_dir / "task.txt").read_text(encoding="utf-8")
    labels = read_labels(task_dir)
    rel = task_dir.relative_to(root.parent) if root.parent in task_dir.parents else task_dir
    notes = task_dir / "NOTES.md"
    parts = [
        f"You are working on one task: {rel}",
        "",
        "Its definition follows. It is an order, not a suggestion, and it is not yours to edit.",
        "",
        body.strip(),
        "",
        f"Labels: " + ", ".join(f"{k}={v}" for k, v in sorted(labels.items())),
        "",
        "Rules for this run:",
        "- The whole tasks/ tree is read-only to you except NOTES.md and BLOCKED.md in this directory.",
        "  A guard blocks every other write there; do not try to work around it.",
        "- You do not decide that the task is done and you never touch status: or verify:.",
        "  The harness reads the evidence and decides. Your job is the work and the record of it.",
        "- Produce the artefact named under OUTCOME, at the path it names. Nothing counts without it.",
        "- Run the command under VERIFY yourself and record what it printed. If it fails, say so plainly.",
        "- Append what you did, what you decided and what you could not settle to NOTES.md in this directory.",
        "- If you cannot proceed, write BLOCKED.md here saying what is missing and what you tried, and stop.",
        "",
        "Finish by printing one line: DONE <what exists now> or BLOCKED <what is missing>.",
    ]
    if notes.exists():
        tail = notes.read_text(encoding="utf-8").strip().splitlines()[-20:]
        if tail:
            parts[5:5] = ["", "Earlier notes on this task (the tail of NOTES.md):", "", "\n".join(tail), ""]
    return "\n".join(parts)


def cmd_next(args: argparse.Namespace) -> int:
    root = pathlib.Path(args.root).resolve()
    task_dir = next_task(root)
    if task_dir is None:
        return 1
    print(task_dir)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    root = pathlib.Path(args.root).resolve()
    for task_dir in task_dirs(root):
        ready, why = is_ready(root, task_dir)
        labels = read_labels(task_dir)
        mark = "ready " if ready else "      "
        print(f"{mark} {labels.get('priority', '--')} {labels.get('status', '?'):<12} "
              f"{task_dir.relative_to(root)}" + (f"   ({why})" if not ready else ""))
    return 0


def cmd_prompt(args: argparse.Namespace) -> int:
    root = pathlib.Path(args.root).resolve()
    print(build_prompt(root, pathlib.Path(args.task).resolve()))
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    try:
        write_label(pathlib.Path(args.task).resolve(), args.key, args.value)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 2
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="tasks.py")
    parser.add_argument("--root", default="tasks", help="the task tree (default: tasks)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("next").set_defaults(func=cmd_next)
    sub.add_parser("list").set_defaults(func=cmd_list)
    p = sub.add_parser("prompt")
    p.add_argument("task")
    p.set_defaults(func=cmd_prompt)
    p = sub.add_parser("set")
    p.add_argument("task")
    p.add_argument("key")
    p.add_argument("value")
    p.set_defaults(func=cmd_set)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
