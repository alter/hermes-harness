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
STATE="$PROJECT/.hermes-harness"
LOGS="$STATE/logs"

command -v hermes >/dev/null 2>&1 || { echo "hermes is not on PATH" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "no task tree at $ROOT" >&2; exit 1; }
[ -f "$HARNESS/tasks.py" ] || { echo "harness not installed at $HARNESS (run install.sh)" >&2; exit 1; }
mkdir -p "$LOGS" "$STATE/attempts"
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

# What the working tree holds, not how many lines git prints about it: an edit
# inside an already-modified file moves no counter, and a count says nothing
# about what changed.
work_fingerprint() {
  ( cd "$WORKDIR" || exit 0
    { git diff HEAD -- . ':!.hermes-notes' 2>/dev/null
      git ls-files -o --exclude-standard -- . ':!.hermes-notes' 2>/dev/null \
        | while IFS= read -r f; do printf '%s ' "$f"; sha1sum "$f" 2>/dev/null | cut -d' ' -f1; echo; done
    } | sha1sum | cut -d' ' -f1 ) || echo none
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

finished=0
started=0
while :; do
  if [ "$MAX_TASKS" != "0" ] && [ "$started" -ge "$MAX_TASKS" ]; then
    echo "== $MAX_TASKS task(s) attempted, stopping as asked"
    break
  fi
  task=$(tasks next) || { echo "== nothing ready in $ROOT"; break; }
  name=$(slug "$task")
  attempts_file="$STATE/attempts/$name"
  attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)

  if [ "$(python3 - "$task" <<'PY'
import pathlib, sys
for line in pathlib.Path(sys.argv[1], "labels.txt").read_text(encoding="utf-8").splitlines():
    if line.split(":", 1)[0].strip() == "status":
        print(line.split(":", 1)[1].strip()); break
PY
)" = "todo" ] && [ "$attempts" -gt 0 ]; then
    echo "== $name: status was reset to todo, so the attempt counter goes with it"
    rm -f "$attempts_file"
    attempts=0
  fi

  started=$((started + 1))
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    echo "== $name: $attempts attempts without progress -> blocked"
    echo "   (clear $attempts_file to give it another run)"
    [ -f "$task/BLOCKED.md" ] || printf '# Blocked\n\nStopped after %s attempts with no artefact and no passing check.\nSee NOTES.md and %s.\n' \
      "$attempts" "$LOGS/$name.ndjson" > "$task/BLOCKED.md"
    tasks set "$task" status blocked
    continue
  fi

  echo "== $name (attempt $((attempts + 1))/$MAX_ATTEMPTS)"
  if [ -f "$task/BLOCKED.md" ]; then
    mv -f "$task/BLOCKED.md" "$task/BLOCKED.previous.md"
    echo "   the previous BLOCKED.md is kept as BLOCKED.previous.md"
  fi
  tasks set "$task" status in_progress
  printf '%s' "$((attempts + 1))" > "$attempts_file"

  notes_dir="$WORKDIR/.hermes-notes/$name"
  rm -rf "$notes_dir" 2>/dev/null || true
  mkdir -p "$notes_dir"

  before=$(work_fingerprint)
  set +e
  tasks prompt "$task" --notes "$notes_dir" | ( cd "$WORKDIR" && hermes ${PROFILE:+-p "$PROFILE"} chat \
      -Q --format stream-json --query-file - --accept-hooks ) > "$LOGS/$name.ndjson" 2>"$LOGS/$name.err"
  rc=$?
  set -e
  after=$(work_fingerprint)

  [ -s "$notes_dir/NOTES.md" ] && { printf '\n## %s (attempt %s)\n\n' "$(date -u +%Y-%m-%dT%H:%MZ)" \
      "$((attempts + 1))" >> "$task/NOTES.md"; cat "$notes_dir/NOTES.md" >> "$task/NOTES.md"; }
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
    note "$task" "harness: agent wrote BLOCKED.md, exit $rc"
    continue
  fi

  if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
    printf '%s' "$attempts" > "$attempts_file"
    echo "   the run was interrupted (exit $rc); the attempt does not count"
    note "$task" "harness: run interrupted (exit $rc) before it could finish"
    interrupted
  fi

  if [ "$rc" -ne 0 ]; then
    echo "   hermes exited $rc -> stays open"
    note "$task" "harness: hermes exited $rc; log $LOGS/$name.ndjson"
    continue
  fi

  if [ "$after" = "$before" ] && [ ! -s "$notes_dir/NOTES.md" ]; then
    echo "   the working tree is byte-for-byte what it was, and no notes were written -> stays open"
    note "$task" "harness: run exited 0 but left the working tree unchanged and wrote no notes; log $LOGS/$name.ndjson"
    continue
  fi

  touched=$(changed_files)
  echo "   the working tree changed, $touched path(s) differ from HEAD -> review"
  note "$task" "harness: the working tree changed, $touched path(s) differ from HEAD$(
      [ -n "$verify_cmd" ] && printf ', `%s` exited %s' "$verify_cmd" "$verify_rc"); handed to review"
  tasks set "$task" status review
  rm -f "$attempts_file"
  finished=$((finished + 1))

  # The commit is the owner's, made with the repository's own identity. Stamping
  # the tool into the author field announces what made the change to everyone who
  # ever reads the log, which is not this harness's call to make.
  if [ -e "$WORKDIR/.git" ]; then
    if ! ( cd "$WORKDIR" && git config user.email >/dev/null 2>&1 ); then
      echo "   not committing: git has no user.email here; set one and commit yourself"
    else
      ( cd "$WORKDIR" && git add -- . ':!tasks' ':!.hermes-notes' >/dev/null 2>&1 || true
        git commit -q -m "$name: $(section "$task" GOAL | head -n 1)" >/dev/null 2>&1 || true )
    fi
  fi

done

echo
echo "attempted: $started, handed to review: $finished"
tasks list
