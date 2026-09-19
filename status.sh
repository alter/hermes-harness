#!/usr/bin/env bash
# status.sh
set -euo pipefail

HARNESS=${HH_HOME:-$HOME/.hermes/harness}
PROJECT=${1:-$(pwd)}
PROJECT=$(cd "$PROJECT" && pwd)
ROOT=${HH_TASK_ROOT:-$PROJECT/tasks}
STATE="$PROJECT/.hermes-harness"
LEDGER="$STATE/ledger.tsv"

[ -d "$ROOT" ] || { echo "no task tree at $ROOT" >&2; exit 1; }
[ -f "$HARNESS/tasks.py" ] || { echo "harness not installed at $HARNESS" >&2; exit 1; }

python3 - "$ROOT" "$STATE" "$LEDGER" "$HARNESS" <<'PY'
import collections, pathlib, sys
root, state, ledger_path, harness = (pathlib.Path(a) for a in sys.argv[1:5])
sys.path.insert(0, str(harness))
import tasks

by_status = collections.Counter()
ready = []
for task_dir in tasks.task_dirs(root):
    labels = tasks.read_labels(task_dir)
    by_status[labels.get("status", "?")] += 1
    ok, _ = tasks.is_ready(root, task_dir)
    if ok:
        ready.append((tasks.PRIORITY_ORDER.get(labels.get("priority", ""), 9), str(task_dir.relative_to(root))))
ready.sort()

print("== tree")
for status in ("todo", "in_progress", "review", "blocked", "done", "paused"):
    if by_status.get(status):
        print(f"   {status:<12}{by_status[status]}")
for status, count in sorted(by_status.items()):
    if status not in ("todo", "in_progress", "review", "blocked", "done", "paused"):
        print(f"   {status:<12}{count}")
print(f"   ready       {len(ready)}" + (f"   next: {ready[0][1]}" if ready else ""))

rows = []
if ledger_path.exists():
    for line in ledger_path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) >= 6:
            rows.append(parts + [""] * (7 - len(parts)))

print()
print("== last word on every task that is not done")
last = {}
for row in rows:
    last[row[1]] = row
open_tasks = [(str(d.relative_to(root)), tasks.read_labels(d).get("status", "?"))
              for d in tasks.task_dirs(root) if tasks.read_labels(d).get("status") not in ("done", None)]
shown = 0
for rel, status in open_tasks:
    name = rel.replace("/", "-")
    row = last.get(name)
    if row is None:
        continue
    when, _, actor, src, dst, why, cost = row[:7]
    cost_s = f"  {cost} USD" if cost and cost != "?" else ""
    print(f"   {status:<12}{rel}")
    print(f"               {when[:16]}  {actor}: {src} -> {dst}, {why}{cost_s}")
    shown += 1
if not shown:
    print("   (nothing in the ledger yet)")

print()
print("== reviews")
spent = 0.0
verdicts = collections.Counter()
for row in rows:
    if row[2] == "reviewer":
        verdicts[row[4]] += 1
        try:
            spent += float(row[6])
        except ValueError:
            pass
gates = sum(1 for row in rows if row[2] == "gate")
print(f"   reviewer verdicts: " + (", ".join(f"{k} {v}" for k, v in sorted(verdicts.items())) or "none"))
print(f"   sent back by the gate without a reader: {gates}")
print(f"   spent on reviews: {spent:.2f} USD")

print()
print("== state")
for sub in ("attempts", "returns", "review-rounds", "sessions"):
    d = state / sub
    n = len([p for p in d.iterdir() if p.is_file()]) if d.is_dir() else 0
    if n:
        print(f"   {sub:<14}{n}: " + ", ".join(sorted(p.name for p in d.iterdir() if p.is_file())[:6])
              + (" …" if n > 6 else ""))
baseline = state / "baseline"
if baseline.is_dir():
    print(f"   baselines     {len(list(baseline.glob('*.rc')))} remembered")
for lock in ("run.lock", "review.lock"):
    p = state / lock
    if p.exists():
        pid = (p.read_text().split() or ["?"])[0]
        alive = pathlib.Path(f"/proc/{pid}").exists()
        print(f"   {lock:<14}pid {pid}, {'alive' if alive else 'stale'}")
PY
