#!/usr/bin/env bash
# run.sh
set -euo pipefail

HARNESS=${HH_HOME:-$HOME/.hermes/harness}
PROJECT=${1:-$(pwd)}
PROJECT=$(cd "$PROJECT" && pwd)
ROOT=${HH_TASK_ROOT:-$PROJECT/tasks}
WORKDIR=${HH_WORKDIR:-$PROJECT}
[ -d "$WORKDIR" ] || { echo "no such working directory: $WORKDIR" >&2; exit 1; }
WORKDIR=$(cd "$WORKDIR" && pwd)
PROFILE=${HH_PROFILE:-}
MAX_TASKS=${HH_MAX_TASKS:-0}
MAX_ATTEMPTS=${HH_MAX_ATTEMPTS:-3}
RUN_VERIFY=${HH_RUN_VERIFY:-1}
COMMIT=${HH_COMMIT:-1}
TEST_CMD=${HH_TEST_COMMAND:-}
MEASURE=${HH_MEASURE:-1}
BUSY_WAIT=${HH_BUSY_WAIT:-3600}
LOG_KEEP=${HH_LOG_KEEP:-20}
STATE="$PROJECT/.hermes-harness"
LOGS="$STATE/logs"

command -v hermes >/dev/null 2>&1 || { echo "hermes is not on PATH" >&2; exit 1; }
hermes ${PROFILE:+-p "$PROFILE"} chat --help 2>/dev/null | grep -q -- 'stream-json' \
  || { echo "this hermes has no 'chat --format stream-json'; the harness needs a build that has it (see README)" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "no task tree at $ROOT" >&2; exit 1; }
[ -f "$HARNESS/tasks.py" ] || { echo "harness not installed at $HARNESS (run install.sh)" >&2; exit 1; }
mkdir -p "$LOGS" "$STATE/attempts" "$STATE/sessions" "$STATE/own"
printf '*\n' > "$STATE/.gitignore"

LOCK="$STATE/run.lock"
if ! ( set -o noclobber; printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK" ) 2>/dev/null; then
  holder=$(cut -d' ' -f1 "$LOCK" 2>/dev/null)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "another run is already working this tree: pid $holder, since $(cut -d' ' -f2 "$LOCK" 2>/dev/null)" >&2
    echo "two loops share the task state and the log names, so this one stops." >&2
    exit 1
  fi
  echo "note: a stale lock from pid ${holder:-unknown} is being taken over"
  printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK"
fi
release_lock() { [ "$(cut -d' ' -f1 "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"; }
trap release_lock EXIT

interrupted() {
  echo
  echo "== interrupted: stopping here, the current task keeps its status and its attempt count"
  release_lock
  exit 130
}
trap interrupted INT TERM

guard_root=${HH_PROTECTED_ROOT:-$(basename "$ROOT")}
if [ -e "$WORKDIR/$guard_root" ]; then
  echo "WARNING: $WORKDIR/$guard_root exists — the agent can see the task tree."
  echo "         Exclude it from the worktree, or the guard is the only thing in the way."
fi
export HH_PROTECTED_ROOT="$guard_root"

case "$ROOT" in
  "$WORKDIR"/*) echo "note: the task tree is inside the agent's working directory."
                echo "      Only guard-paths.py stands between the agent and it, and a guard that reads"
                echo "      command text cannot see a path an interpreter builds at run time."
                echo "      HH_WORKDIR=<a worktree without tasks/> removes the file instead of guarding it." ;;
esac

tasks() { python3 "$HARNESS/tasks.py" --root "$ROOT" "$@"; }
slug()  { printf '%s' "${1#$ROOT/}" | tr '/' '-'; }

section() {
  python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
body = pathlib.Path(sys.argv[1], "task.txt").read_text(encoding="utf-8")
marks = [(m.group(1).rstrip(":"), m.start(), m.end())
         for m in re.finditer(r"^(TASK:|GOAL|CONTEXT|SCOPE|OUTCOME|VERIFY|ROLE|DEPENDS)\b.*$", body, re.M)]
for i, (name, _, end) in enumerate(marks):
    if name == sys.argv[2]:
        stop = marks[i + 1][1] if i + 1 < len(marks) else len(body)
        print(body[end:stop].strip())
        break
PY
}

snapshot_id() { python3 "$HARNESS/snapshot.py" "$WORKDIR" "$guard_root" 2>/dev/null || true; }

record_check() {
  printf '%s' "$2" > "$LOGS/$1.check.rc"
  snapshot_id > "$LOGS/$1.check.snap"
  printf '%s' "$TEST_CMD" > "$LOGS/$1.check.cmd"
}

check_is_fresh() {
  local snap; snap=$(snapshot_id)
  [ -n "$snap" ] && [ -f "$LOGS/$1.check.out" ] && [ -f "$LOGS/$1.check.rc" ] \
    && [ "$(cat "$LOGS/$1.check.snap" 2>/dev/null)" = "$snap" ] \
    && [ "$(cat "$LOGS/$1.check.cmd" 2>/dev/null)" = "$TEST_CMD" ]
}

tree_is_clean() { [ -z "$(cd "$WORKDIR" && git status --porcelain -- . ':!.hermes-notes' ":!$guard_root" 2>/dev/null)" ]; }

trim_history() {
  ls -t "$LOGS/history/$1."*".$2" 2>/dev/null | tail -n "+$((LOG_KEEP + 1))" | while IFS= read -r f; do rm -f "$f"; done || true
}

changed_files() {
  ( cd "$WORKDIR" && git status --porcelain -- . ':!.hermes-notes' 2>/dev/null | wc -l ) || echo 0
}

verify_command() {
  section "$1" VERIFY | grep -oE '`[^`]+`' | head -n 1 | tr -d '`' || true
}

note() {
  local task=$1; shift
  printf '\n- %s %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$*" >> "$task/NOTES.md"
}

status_of() {
  python3 - "$1" <<'PY'
import pathlib, sys
for line in pathlib.Path(sys.argv[1], "labels.txt").read_text(encoding="utf-8").splitlines():
    if line.split(":", 1)[0].strip() == "status":
        print(line.split(":", 1)[1].strip()); break
PY
}

# One line per transition, for the question "why is this task where it is":
# time, task, who moved it, from, to, why, and what it cost when something did.
ledger() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "${6:-}" \
    >> "$STATE/ledger.tsv"
}

# The worker's claims and the harness's measurement, side by side in the same
# file. A note that says "2 failed" above and "did not run it" below is only
# possible when nobody measures.
measure() {
  local task=$1 name=$2 attempt=$3 rc=0
  [ "$MEASURE" = "1" ] && [ -n "$TEST_CMD" ] || return 0
  echo "   measuring: $TEST_CMD"
  ( cd "$WORKDIR" && eval "$TEST_CMD" ) > "$LOGS/$name.check.out" 2>&1 || rc=$?
  record_check "$name" "$rc"
  echo "   it exited $rc"
  {
    printf '\n## Measured by the harness (attempt %s)\n\n' "$attempt"
    printf '`%s` in %s, exit %s.\n\n' "$TEST_CMD" "$WORKDIR" "$rc"
    if grep -qE '^(FAILED|ERROR) ' "$LOGS/$name.check.out"; then
      printf 'Failure lines:\n\n```\n'
      grep -E '^(FAILED|ERROR) ' "$LOGS/$name.check.out" | head -n 40
      printf '```\n\n'
    fi
    printf 'Last lines:\n\n```\n'
    tail -n 15 "$LOGS/$name.check.out"
    printf '```\n'
  } >> "$task/NOTES.md"
}

finished=0
started=0
while :; do
  waited=0
  while [ -f "$STATE/workdir.busy" ]; do
    holder=$(cat "$STATE/workdir.busy" 2>/dev/null)
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
      rm -f "$STATE/workdir.busy"
      break
    fi
    if [ "$waited" -ge "$BUSY_WAIT" ]; then
      echo "a review is using this working copy (pid $holder); gave up waiting after ${BUSY_WAIT}s" >&2
      exit 75
    fi
    step=10
    remaining=$((BUSY_WAIT - waited))
    [ "$remaining" -lt "$step" ] && step=$remaining
    sleep "$step"
    waited=$((waited + step))
  done

  if [ "$MAX_TASKS" != "0" ] && [ "$started" -ge "$MAX_TASKS" ]; then
    echo "== $MAX_TASKS task(s) attempted, stopping as asked"
    break
  fi
  task=$(tasks next) || { echo "== nothing ready in $ROOT"; break; }
  name=$(slug "$task")
  attempts_file="$STATE/attempts/$name"
  attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)
  own_file="$STATE/own/$name"

  was=$(status_of "$task")
  if [ "$was" = "todo" ] && [ "$attempts" -gt 0 ]; then
    echo "== $name: status was reset to todo, so the attempt counter goes with it"
    rm -f "$attempts_file" "$STATE/sessions/$name" "$own_file"
    attempts=0
  fi

  started=$((started + 1))
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    echo "== $name: $attempts attempts without progress -> blocked"
    echo "   (clear $attempts_file to give it another run)"
    [ -f "$task/BLOCKED.md" ] || printf '# Blocked\n\nStopped after %s attempts with no artefact and no passing check.\nSee NOTES.md and %s.\n' \
      "$attempts" "$LOGS/$name.ndjson" > "$task/BLOCKED.md"
    tasks set "$task" status blocked
    ledger "$name" worker "$was" blocked "$attempts attempts without progress"
    continue
  fi

  echo "== $name (attempt $((attempts + 1))/$MAX_ATTEMPTS)"
  if [ -f "$task/BLOCKED.md" ]; then
    mv -f "$task/BLOCKED.md" "$task/BLOCKED.previous.md"
    echo "   the previous BLOCKED.md is kept as BLOCKED.previous.md"
  fi
  tasks set "$task" status in_progress
  ledger "$name" worker "$was" in_progress "attempt $((attempts + 1))"
  printf '%s' "$((attempts + 1))" > "$attempts_file"

  session_file="$STATE/sessions/$name"
  resume_id=$(cat "$session_file" 2>/dev/null || true)
  notes_dir="$WORKDIR/.hermes-notes/$name"
  export HH_NOTES_FILE="$notes_dir/NOTES.md"
  rm -rf "$notes_dir" 2>/dev/null || true
  mkdir -p "$notes_dir"
  tasks scaffold "$task" > "$notes_dir/NOTES.md"
  cp "$notes_dir/NOTES.md" "$notes_dir/.scaffold"

  before=$(snapshot_id)
  if tree_is_clean; then
    printf '%s' "$before" > "$own_file"
  elif [ ! -s "$own_file" ] || [ "$(cat "$own_file")" != "$before" ]; then
    rm -f "$own_file"
  fi
  if [ -n "$resume_id" ]; then
    echo "   resuming session $resume_id rather than starting over"
    prompt_source=continuation
  else
    prompt_source=task
  fi
  set +e
  if [ "$prompt_source" = "continuation" ]; then
    printf '%s\n' \
      "You stopped in the middle of this task: your last turn ended with prose instead of an action." \
      "Pick up exactly where you left off — the work you already did is still there." \
      "" \
      "Before you stop this time, fill in $notes_dir/NOTES.md — it is a form: one row per VERIFY criterion," \
      "from what you ran or read, and two sections to write. A row left unfilled is read as unchecked," \
      "and \"there was nothing left to do\" is itself a finding worth writing down." \
      "If something blocks you, write $notes_dir/BLOCKED.md instead and stop." \
      | ( cd "$WORKDIR" && hermes ${PROFILE:+-p "$PROFILE"} chat --resume "$resume_id" \
          -Q --format stream-json --query-file - --accept-hooks ) > "$LOGS/$name.ndjson" 2>"$LOGS/$name.err"
  else
    tasks prompt "$task" --notes "$notes_dir" | ( cd "$WORKDIR" && hermes ${PROFILE:+-p "$PROFILE"} chat \
        -Q --format stream-json --query-file - --accept-hooks ) > "$LOGS/$name.ndjson" 2>"$LOGS/$name.err"
  fi
  rc=$?
  set -e

  mkdir -p "$LOGS/history"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  cp "$LOGS/$name.ndjson" "$LOGS/history/$name.$stamp.a$((attempts + 1)).ndjson" 2>/dev/null || true
  cp "$LOGS/$name.err" "$LOGS/history/$name.$stamp.a$((attempts + 1)).err" 2>/dev/null || true
  trim_history "$name" ndjson
  trim_history "$name" err

  new_session=$(python3 - "$LOGS/$name.ndjson" <<'PY'
import json, pathlib, sys
last = ""
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if row.get("type") == "result" and row.get("session_id"):
        last = row["session_id"]
print(last)
PY
)
  [ -n "$new_session" ] && printf '%s' "$new_session" > "$session_file"
  after=$(snapshot_id)
  [ -f "$own_file" ] && printf '%s' "$after" > "$own_file"

  notes_written=0
  if [ -s "$notes_dir/NOTES.md" ] && ! cmp -s "$notes_dir/NOTES.md" "$notes_dir/.scaffold"; then
    notes_written=1
    printf '\n## %s (attempt %s)\n\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$((attempts + 1))" >> "$task/NOTES.md"
    cat "$notes_dir/NOTES.md" >> "$task/NOTES.md"
  fi
  [ -s "$notes_dir/BLOCKED.md" ] && cp "$notes_dir/BLOCKED.md" "$task/BLOCKED.md"

  verify_cmd=$(verify_command "$task")
  verify_rc=0
  if [ "$RUN_VERIFY" = "1" ] && [ -n "$verify_cmd" ]; then
    set +e
    ( cd "$WORKDIR" && eval "$verify_cmd" ) > "$LOGS/$name.verify" 2>&1
    verify_rc=$?
    set -e
    echo "   VERIFY \`$verify_cmd\` exited $verify_rc"
  fi

  if [ -s "$notes_dir/BLOCKED.md" ]; then
    echo "   the agent says it is blocked"
    tasks set "$task" status blocked
    ledger "$name" worker in_progress blocked "agent wrote BLOCKED.md"
    rm -f "$session_file" "$own_file"
    note "$task" "harness: agent wrote BLOCKED.md, exit $rc"
    continue
  fi

  if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
    printf '%s' "$attempts" > "$attempts_file"
    echo "   the run was interrupted (exit $rc); the attempt does not count"
    ledger "$name" worker in_progress in_progress "interrupted, exit $rc"
    note "$task" "harness: run interrupted (exit $rc) before it could finish"
    interrupted
  fi

  if [ "$rc" -ne 0 ]; then
    echo "   hermes exited $rc -> stays open"
    ledger "$name" worker in_progress in_progress "hermes exited $rc"
    note "$task" "harness: hermes exited $rc; log $LOGS/$name.ndjson"
    continue
  fi

  if [ -n "$before" ] && [ "$after" = "$before" ] && [ "$notes_written" = "0" ]; then
    echo "   the working tree is byte-for-byte what it was, and the notes form was left untouched -> stays open"
    ledger "$name" worker in_progress in_progress "no change, no notes"
    note "$task" "harness: run exited 0 but left the working tree unchanged and the notes form untouched; log $LOGS/$name.ndjson"
    continue
  fi

  if ! missing=$(tasks notes-check "$notes_dir/NOTES.md"); then
    echo "   the notes form is unfilled -> stays open"
    ledger "$name" worker in_progress in_progress "notes form unfilled"
    note "$task" "harness: the run ended with the notes form unfilled: $(printf '%s' "$missing" | tr '\n' ';')"
    continue
  fi

  touched=$(changed_files)
  if [ -n "$before" ] && [ "$after" = "$before" ]; then
    what="the working tree is unchanged, but notes were written"
  else
    what="the working tree changed, $touched path(s) differ from HEAD"
  fi
  { [ -z "$before" ] || [ "$after" != "$before" ]; } && measure "$task" "$name" "$((attempts + 1))" || true
  echo "   $what -> review"
  mkdir -p "$STATE/review"
  printf 'worktree\n' > "$STATE/review/$name"

  # The commit is the owner's, made with the repository's own identity. Stamping
  # the tool into the author field announces what made the change to everyone who
  # ever reads the log, which is not this harness's call to make.
  if [ "$COMMIT" = "0" ]; then
    echo "   not committing (HH_COMMIT=0); the work is left for review"
  elif [ -e "$WORKDIR/.git" ]; then
    if ! ( cd "$WORKDIR" && git config user.email >/dev/null 2>&1 ); then
      echo "   not committing: git has no user.email here; set one and commit yourself"
      note "$task" "harness: not committed — git has no identity configured in $WORKDIR"
    elif [ ! -s "$own_file" ]; then
      echo "   not committing: the working copy already held changes that are not this task's"
      note "$task" "harness: not committed — the working copy held changes from before this task; the work is left uncommitted for review"
    else
      ( cd "$WORKDIR" && git add -- . ":!$guard_root" ':!.hermes-notes' >/dev/null 2>&1 || true )
      if commit_out=$( cd "$WORKDIR" && git commit -m "$name: $(section "$task" GOAL | head -n 1)" -- . ":!$guard_root" ':!.hermes-notes' 2>&1 ); then
        echo "   committed in $WORKDIR"
        printf 'commit %s\n' "$( cd "$WORKDIR" && git rev-parse HEAD )" > "$STATE/review/$name"
      else
        echo "   NOT committed — the work is safe but uncommitted:"
        printf '%s\n' "$commit_out" | tail -n 4 | sed 's/^/     /'
        note "$task" "harness: commit refused in $WORKDIR; $(printf '%s' "$commit_out" | tail -n 1)"
      fi
    fi
  fi

  note "$task" "harness: $what$(
      [ -n "$verify_cmd" ] && printf ', `%s` exited %s' "$verify_cmd" "$verify_rc"); handed to review"
  tasks set "$task" status review
  ledger "$name" worker in_progress review "$what"
  rm -f "$attempts_file" "$session_file" "$own_file"
  finished=$((finished + 1))

done

echo
echo "attempted: $started, handed to review: $finished"
tasks list
