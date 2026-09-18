# tasks.py
from __future__ import annotations

import argparse
import pathlib
import re
import sys

READY_STATUSES = {"todo", "in_progress"}
WRITABLE_LABELS = {"agent": {"status"}, "reviewer": {"status", "verify"}}
NO_DEPENDS = {"-", "none", "нет", "n/a", "na"}
PRIORITY_ORDER = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
SECTION_RE = re.compile(r"^(TASK:|GOAL|CONTEXT|SCOPE|OUTCOME|VERIFY|ROLE|DEPENDS)\b.*$", re.M)


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


def write_label(task_dir: pathlib.Path, key: str, value: str, role: str = "agent") -> None:
    allowed = WRITABLE_LABELS.get(role)
    if allowed is None:
        raise ValueError(f"no such role: {role}; known roles are {sorted(WRITABLE_LABELS)}")
    if key not in allowed:
        raise ValueError(f"{key} is not {role}'s to write: that role owns only {sorted(allowed)}")
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


def depends_of(labels: dict[str, str]) -> list[str]:
    raw = re.split(r"[,\s]+", labels.get("depends", "").strip())
    return [d for d in raw if d and d.lower() not in NO_DEPENDS]


def depends_met(root: pathlib.Path, labels: dict[str, str]) -> tuple[bool, str]:
    for dep in depends_of(labels):
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


def queue(root: pathlib.Path, status: str) -> list[pathlib.Path]:
    out = []
    for task_dir in task_dirs(root):
        labels = read_labels(task_dir)
        if labels.get("status", "") != status:
            continue
        if "HUMAN" in re.split(r"[,\s]+", labels.get("role", "")):
            continue
        out.append((PRIORITY_ORDER.get(labels.get("priority", ""), 9), str(task_dir), task_dir))
    out.sort()
    return [task_dir for _, _, task_dir in out]


def section(body: str, name: str) -> str:
    starts = [(m.group(1), m.start(), m.end()) for m in SECTION_RE.finditer(body)]
    for i, (found, _, end) in enumerate(starts):
        if found.rstrip(":") != name:
            continue
        stop = starts[i + 1][1] if i + 1 < len(starts) else len(body)
        return body[end:stop].strip()
    return ""


def build_prompt(root: pathlib.Path, task_dir: pathlib.Path, notes: str = "") -> str:
    body = (task_dir / "task.txt").read_text(encoding="utf-8")
    labels = read_labels(task_dir)
    rel = task_dir.relative_to(root.parent) if root.parent in task_dir.parents else task_dir
    notes_file = task_dir / "NOTES.md"
    notes_dir = notes or "<unset>"
    parts = [
        f"You are working on one task: {rel}",
        "",
        "Its definition follows. It is an order, not a suggestion, and it is not yours to edit.",
        "",
        body.strip(),
        "",
        "Labels: " + ", ".join(f"{k}={v}" for k, v in sorted(labels.items())),
        "",
        "Rules for this run:",
        "- OUTCOME describes what must become true in the repository. VERIFY lists the criteria a human"
        "  reviewer will judge it by — they are not a command for you to run unless one is written as a"
        "  shell command in backticks. Make OUTCOME true and leave evidence a reviewer can check.",
        "- The task tree is not in your working directory and is not yours to write. Do not recreate it,"
        "  under any name. Your code and artefacts go where the project already keeps that kind of file.",
        "- You never decide the task is finished and you never write status: or verify:. A reviewer does"
        "  that, from what you leave behind. Overstating what you did only makes the review fail.",
        f"- Write your record to {notes_dir}/NOTES.md: what you did, what you measured, what you decided,"
        "  and what you could not settle. The harness moves it into the task directory afterwards.",
        f"- If you cannot proceed, write {notes_dir}/BLOCKED.md with what is missing and what you tried,"
        "  then stop. Stopping honestly is a result; a workaround that hides the problem is not.",
        "",
        "Finish by printing one line: DONE <what is now true> or BLOCKED <what is missing>.",
    ]
    check_file = task_dir / "CHECK.md"
    if check_file.exists():
        parts[5:5] = ["", "The project's own check was run against your work and it went backwards.",
                      "This is why the task is open again — answer it first:", "",
                      check_file.read_text(encoding="utf-8").strip()[:8000], ""]
    review_file = task_dir / "REVIEW.md"
    if review_file.exists():
        verdict = review_file.read_text(encoding="utf-8").strip()
        parts[5:5] = ["", "This task was reviewed and sent back. The review is the reason you are here again;",
                      "read it before you touch anything, and answer it rather than starting over:", "",
                      verdict[:8000], ""]
    if notes_file.exists():
        tail = notes_file.read_text(encoding="utf-8").strip().splitlines()[-20:]
        if tail:
            parts[5:5] = ["", "Earlier notes on this task (the tail of NOTES.md):", "", "\n".join(tail), ""]
    return "\n".join(parts)


def build_review_prompt(root: pathlib.Path, task_dir: pathlib.Path, diff: str, test_cmd: str,
                        workdir: str = "", check_output: str = "") -> str:
    body = (task_dir / "task.txt").read_text(encoding="utf-8")
    labels = read_labels(task_dir)
    rel = task_dir.relative_to(root.parent) if root.parent in task_dir.parents else task_dir
    notes_file = task_dir / "NOTES.md"
    notes = notes_file.read_text(encoding="utf-8").strip() if notes_file.exists() else ""
    if len(notes) > 12000:
        notes = notes[-12000:]
    parts = [
        f"You are judging one finished piece of work against the task it was given: {rel}",
        "",
        "## The task, as it was set",
        "",
        body.strip(),
        "",
        "Labels: " + ", ".join(f"{k}={v}" for k, v in sorted(labels.items())),
        "",
        "OUTCOME states what had to become true in the repository. VERIFY lists the criteria the work is",
        "judged by. Judge against those two, not against what you would have done.",
        "",
        "## What the worker says it did",
        "",
        notes or "(no notes were left)",
        "",
        "These are claims. They are not evidence, and a confident note is not a passing one.",
        "",
        "## The change itself",
        "",
        "```diff",
        diff.strip() or "(no diff was captured; find the change yourself with git)",
        "```",
        "",
        "## How to judge",
        "",
        f"You are already in {workdir or 'the working directory the change was made in'}, and every path",
        "below is relative to it. You can read files and run read-only commands. You cannot write, and",
        "nothing you do should change the repository. A command that is refused is not a dead end: read",
        "the file instead, and say in your answer what you could not run.",
        "",
        "Do not accept a claim you have not checked. For every criterion in VERIFY, either run something",
        "that shows it holds, or read the code closely enough to say why it does or does not. Look for the",
        "failure the task was about, not for tidy code: a change that compiles, passes its own new tests and",
        "does not do what OUTCOME asked for is a failure. Tests written alongside the change are part of what",
        "you are judging, not proof: read them and say whether they would catch the thing going wrong.",
    ]
    if test_cmd and check_output:
        tail = check_output.strip()[-20000:]
        parts += ["", f"The project's own check, `{test_cmd}`, has already been run against exactly this",
                  "working tree, and nothing has changed since. Its output ends like this:", "",
                  "```", tail, "```", "",
                  "Treat that as measured, not claimed. Run it again only if you need something it does not",
                  "show — a narrower selection, or a second look after you have read the code."]
    elif test_cmd:
        parts += ["", f"The project's own check is `{test_cmd}`. Run it. Its result is evidence; your"
                      " impression is not."]
    parts += [
        "",
        "## Your answer",
        "",
        "Answer in the schema you were given, and nothing else.",
        "- verdict `passed`: OUTCOME is true and every criterion in VERIFY holds, and you have the evidence.",
        "- verdict `failed`: something the task asked for is missing, wrong, or unproven. Say exactly what,",
        "  and put in `next_step` the one thing that would fix it — the worker reads it and tries again.",
        "- verdict `blocked`: the work cannot be judged here — the task is ambiguous, or checking it needs",
        "  something you do not have. Say what is missing. This stops the task and calls a human.",
        "",
        "`evidence` carries what you actually ran or read: the claim, the command, and the part of its",
        "output that settles it. A `passed` verdict with no evidence is refused by the harness, so do not",
        "give one you cannot support. Say plainly when you are unsure — an honest `failed` costs one more",
        "run, a wrong `passed` ships the defect.",
    ]
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
    print(build_prompt(root, pathlib.Path(args.task).resolve(), args.notes))
    return 0


def cmd_queue(args: argparse.Namespace) -> int:
    root = pathlib.Path(args.root).resolve()
    found = queue(root, args.status)
    for task_dir in found:
        print(task_dir)
    return 0 if found else 1


def cmd_review_prompt(args: argparse.Namespace) -> int:
    root = pathlib.Path(args.root).resolve()
    read = lambda path: pathlib.Path(path).read_text(encoding="utf-8", errors="replace") if path else ""
    print(build_review_prompt(root, pathlib.Path(args.task).resolve(), read(args.diff), args.test_command,
                              args.workdir, read(args.check_output)))
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    try:
        write_label(pathlib.Path(args.task).resolve(), args.key, args.value, args.role)
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
    p.add_argument("--notes", default="", help="where the agent should write NOTES.md and BLOCKED.md")
    p.set_defaults(func=cmd_prompt)
    p = sub.add_parser("queue")
    p.add_argument("status", nargs="?", default="review")
    p.set_defaults(func=cmd_queue)
    p = sub.add_parser("review-prompt")
    p.add_argument("task")
    p.add_argument("--diff", default="", help="a file holding the change under review")
    p.add_argument("--test-command", default="", help="the project's own check, if it has one")
    p.add_argument("--workdir", default="", help="where the reviewer will be standing")
    p.add_argument("--check-output", default="", help="what the project's own check printed, if it has run")
    p.set_defaults(func=cmd_review_prompt)
    p = sub.add_parser("set")
    p.add_argument("task")
    p.add_argument("key")
    p.add_argument("value")
    p.add_argument("--as", dest="role", default="agent", choices=sorted(WRITABLE_LABELS))
    p.set_defaults(func=cmd_set)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
