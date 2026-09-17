#!/usr/bin/env bash
# run.sh
set -euo pipefail

HARNESS=${HH_HOME:-$HOME/.hermes/harness}
PROJECT=${1:-$(pwd)}
PROJECT=$(cd "$PROJECT" && pwd)
ROOT=${HH_TASK_ROOT:-$PROJECT/tasks}
PROFILE=${HH_PROFILE:-}
MAX_TASKS=${HH_MAX_TASKS:-0}
MAX_ATTEMPTS=${HH_MAX_ATTEMPTS:-3}
RUN_VERIFY=${HH_RUN_VERIFY:-1}
STATE="$PROJECT/.hermes-harness"
LOGS="$STATE/logs"

command -v hermes >/dev/null 2>&1 || { echo "hermes is not on PATH" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "no task tree at $ROOT" >&2; exit 1; }
[ -f "$HARNESS/tasks.py" ] || { echo "harness not installed at $HARNESS (run install.sh)" >&2; exit 1; }
mkdir -p "$LOGS" "$STATE/attempts"

tasks() { python3 "$HARNESS/tasks.py" --root "$ROOT" "$@"; }
slug()  { printf '%s' "${1#$ROOT/}" | tr '/' '-'; }

section() {
  python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
body = pathlib.Path(sys.argv[1], "task.txt").read_text(encoding="utf-8")
marks = [(m.group(1).rstrip(":"), m.start(), m.end())
         for m in re.finditer(r"^(TASK:|GOAL|CONTEXT|SCOPE|OUTCOME|VERIFY|ROLE|DEPENDS)\s*$", body, re.M)]
for i, (name, _, end) in enumerate(marks):
    if name == sys.argv[2]:
        stop = marks[i + 1][1] if i + 1 < len(marks) else len(body)
        print(body[end:stop].strip())
        break
PY
}

outcome_exists() {
  local task=$1 found=1
  while read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -e "$PROJECT/$candidate" ] || [ -e "$candidate" ]; then found=0; fi
  done < <(section "$task" OUTCOME | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,8}|[A-Za-z0-9_./-]+/' || true)
  return $found
}

note() {
  local task=$1; shift
  printf '\n- %s %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$*" >> "$task/NOTES.md"
}

finished=0
while :; do
  task=$(tasks next) || { echo "== nothing ready in $ROOT"; break; }
  name=$(slug "$task")
  attempts_file="$STATE/attempts/$name"
  attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    echo "== $name: $attempts attempts without progress -> blocked"
    [ -f "$task/BLOCKED.md" ] || printf '# Blocked\n\nStopped after %s attempts with no artefact and no passing check.\nSee NOTES.md and %s.\n' \
      "$attempts" "$LOGS/$name.ndjson" > "$task/BLOCKED.md"
    tasks set "$task" status blocked
    continue
  fi

  echo "== $name (attempt $((attempts + 1))/$MAX_ATTEMPTS)"
  tasks set "$task" status in_progress
  printf '%s' "$((attempts + 1))" > "$attempts_file"

  set +e
  tasks prompt "$task" | ( cd "$PROJECT" && hermes ${PROFILE:+-p "$PROFILE"} chat \
      -Q --format stream-json --query-file - --accept-hooks ) > "$LOGS/$name.ndjson" 2>"$LOGS/$name.err"
  rc=$?
  set -e

  verify_rc=0
  verify_cmd=$(section "$task" VERIFY | grep -oE '`[^`]+`' | head -n 1 | tr -d '`' || true)
  if [ "$RUN_VERIFY" = "1" ] && [ -n "$verify_cmd" ]; then
    set +e
    ( cd "$PROJECT" && eval "$verify_cmd" ) > "$LOGS/$name.verify" 2>&1
    verify_rc=$?
    set -e
  fi

  if [ -f "$task/BLOCKED.md" ]; then
    echo "   blocked by the agent"
    tasks set "$task" status blocked
    note "$task" "harness: agent wrote BLOCKED.md, exit $rc"
    continue
  fi

  if [ "$rc" -ne 0 ]; then
    echo "   hermes exited $rc -> stays open"
    note "$task" "harness: hermes exited $rc; log $LOGS/$name.ndjson"
    continue
  fi

  if ! outcome_exists "$task"; then
    echo "   no OUTCOME artefact -> stays open"
    note "$task" "harness: run finished but the OUTCOME artefact is not in the repository"
    continue
  fi

  if [ "$verify_rc" -ne 0 ]; then
    echo "   VERIFY failed ($verify_cmd) -> stays open"
    note "$task" "harness: VERIFY \`$verify_cmd\` exited $verify_rc; output in $LOGS/$name.verify"
    continue
  fi

  echo "   artefact present, check passed -> review"
  note "$task" "harness: artefact present, \`${verify_cmd:-no check}\` passed; handed to review"
  tasks set "$task" status review
  rm -f "$attempts_file"
  finished=$((finished + 1))

  if [ -d "$PROJECT/.git" ]; then
    ( cd "$PROJECT" && git add -- . ':!tasks' >/dev/null 2>&1 || true
      git -c user.name="hermes-harness" -c user.email="hermes@localhost" \
          commit -q -m "$name: $(section "$task" GOAL | head -n 1)" >/dev/null 2>&1 || true )
  fi

  [ "$MAX_TASKS" != "0" ] && [ "$finished" -ge "$MAX_TASKS" ] && { echo "== $MAX_TASKS tasks done"; break; }
done

echo
echo "handed to review: $finished"
tasks list
