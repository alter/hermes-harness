#!/usr/bin/env bash
# review.sh
set -euo pipefail

HARNESS=${HH_HOME:-$HOME/.hermes/harness}
PROJECT=${1:-$(pwd)}
PROJECT=$(cd "$PROJECT" && pwd)
ROOT=${HH_TASK_ROOT:-$PROJECT/tasks}
WORKDIR=${HH_WORKDIR:-$PROJECT}
[ -d "$WORKDIR" ] || { echo "no such working directory: $WORKDIR" >&2; exit 1; }
WORKDIR=$(cd "$WORKDIR" && pwd)
MAX=${HH_REVIEW_MAX:-0}
MAX_ROUNDS=${HH_REVIEW_MAX_ROUNDS:-2}
MODEL=${HH_REVIEW_MODEL:-opus}
EFFORT=${HH_REVIEW_EFFORT:-high}
BUDGET=${HH_REVIEW_BUDGET:-5}
TEST_CMD=${HH_TEST_COMMAND:-}
ONLY=${HH_REVIEW_ONLY:-}
DIFF_LIMIT=${HH_REVIEW_DIFF_CHARS:-200000}
STATE="$PROJECT/.hermes-harness"
LOGS="$STATE/logs"

command -v claude >/dev/null 2>&1 || { echo "claude is not on PATH" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "no task tree at $ROOT" >&2; exit 1; }
[ -f "$HARNESS/tasks.py" ] || { echo "harness not installed at $HARNESS (run install.sh)" >&2; exit 1; }
mkdir -p "$LOGS" "$STATE/review-rounds" "$STATE/review"
printf '*\n' > "$STATE/.gitignore"

help=$(claude --help 2>/dev/null || true)
effort_flag=()
case "$help" in
  *--effort*) effort_flag=(--effort "$EFFORT") ;;
  *) echo "note: this claude has no --effort; the review runs at its default depth" ;;
esac
case "$help" in
  *--permission-prompts*) prompts_flag=(--permission-prompts none) ;;
  *) prompts_flag=() ;;
esac

LOCK="$STATE/review.lock"
if ! ( set -o noclobber; printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK" ) 2>/dev/null; then
  holder=$(cut -d' ' -f1 "$LOCK" 2>/dev/null)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "another review is already working this tree: pid $holder" >&2
    exit 1
  fi
  echo "note: a stale review lock from pid ${holder:-unknown} is being taken over"
  printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK"
fi
release_lock() { [ "$(cut -d' ' -f1 "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"; }
trap release_lock EXIT
interrupted() { echo; echo "== interrupted: the task under review keeps its status"; release_lock; exit 130; }
trap interrupted INT TERM

tasks() { python3 "$HARNESS/tasks.py" --root "$ROOT" "$@"; }
slug()  { printf '%s' "${1#$ROOT/}" | tr '/' '-'; }

# What the writing loop left behind: a commit it made, or the uncommitted state
# of the working tree. A new file is untracked, so `git diff HEAD` alone would
# show the reviewer a change with its most important half missing.
capture_diff() {
  local name=$1 out=$2 ref
  ref=$(cat "$STATE/review/$name" 2>/dev/null || echo worktree)
  ( cd "$WORKDIR"
    case "$ref" in
      commit\ *)
        printf '# the change under review is commit %s\n\n' "${ref#commit }"
        git show --stat --patch "${ref#commit }" -- . ':!.hermes-notes' 2>/dev/null ;;
      *)
        printf '# the change under review is what is uncommitted in %s\n\n' "$WORKDIR"
        git diff HEAD -- . ':!.hermes-notes' 2>/dev/null
        git ls-files -o --exclude-standard -- . ':!.hermes-notes' 2>/dev/null \
          | while IFS= read -r f; do
              printf '\n--- /dev/null\n+++ b/%s\n' "$f"
              sed 's/^/+/' "$f" 2>/dev/null
            done ;;
    esac ) > "$out" 2>/dev/null || true
  if [ "$(wc -c < "$out")" -gt "$DIFF_LIMIT" ]; then
    head -c "$DIFF_LIMIT" "$out" > "$out.cut"
    printf '\n\n# ... truncated at %s characters. Read the files themselves for the rest.\n' \
      "$DIFF_LIMIT" >> "$out.cut"
    mv -f "$out.cut" "$out"
  fi
}

SCHEMA='{"type":"object","additionalProperties":false,"properties":{
  "verdict":{"type":"string","enum":["passed","failed","blocked"]},
  "summary":{"type":"string"},
  "evidence":{"type":"array","items":{"type":"object","additionalProperties":false,
    "properties":{"claim":{"type":"string"},"command":{"type":"string"},"output":{"type":"string"}},
    "required":["claim"]}},
  "unmet":{"type":"array","items":{"type":"string"}},
  "next_step":{"type":"string"}},
  "required":["verdict","summary","evidence","unmet"]}'

# One named task instead of the queue. The queue is in priority order, which is
# rarely the order a first look wants, and a task whose change is not in this
# working copy is worse than unreviewed.
only_dir=""
if [ -n "$ONLY" ]; then
  case "$ONLY" in /*) only_dir=$ONLY ;; *) only_dir=$ROOT/$ONLY ;; esac
  [ -d "$only_dir" ] || { echo "no such task: $only_dir" >&2; exit 1; }
  only_status=$(python3 - "$only_dir" <<'PY'
import pathlib, sys
for line in pathlib.Path(sys.argv[1], "labels.txt").read_text(encoding="utf-8").splitlines():
    if line.split(":", 1)[0].strip() == "status":
        print(line.split(":", 1)[1].strip()); break
PY
)
  [ "$only_status" = "review" ] || { echo "$ONLY is $only_status, not review" >&2; exit 1; }
  MAX=1
fi

judged=0
started=0
while :; do
  if [ "$MAX" != "0" ] && [ "$started" -ge "$MAX" ]; then
    echo "== $MAX review(s) done, stopping as asked"
    break
  fi
  if [ -n "$only_dir" ]; then
    task=$only_dir
  else
    task=$(tasks queue review | head -n 1) || { echo "== nothing waiting in review"; break; }
  fi
  [ -n "$task" ] || { echo "== nothing waiting in review"; break; }
  name=$(slug "$task")
  rounds_file="$STATE/review-rounds/$name"
  rounds=$(cat "$rounds_file" 2>/dev/null || echo 0)
  started=$((started + 1))

  echo "== $name (review round $((rounds + 1))/$MAX_ROUNDS)"
  diff_file="$LOGS/$name.under-review.diff"
  capture_diff "$name" "$diff_file"
  echo "   change under review: $(head -n 1 "$diff_file" | sed 's/^# //'), $(wc -c < "$diff_file") characters"

  allowed=(Read Grep Glob
           "Bash(git diff:*)" "Bash(git show:*)" "Bash(git log:*)" "Bash(git status:*)"
           "Bash(git ls-files:*)" "Bash(rg:*)" "Bash(sed -n:*)" "Bash(wc:*)" "Bash(ls:*)")
  [ -n "$TEST_CMD" ] && allowed+=("Bash(${TEST_CMD%% *}:*)") || true

  set +e
  tasks review-prompt "$task" --diff "$diff_file" --test-command "$TEST_CMD" --workdir "$WORKDIR" \
    | ( cd "$WORKDIR" && claude -p \
        --model "$MODEL" "${effort_flag[@]}" \
        --permission-mode dontAsk "${prompts_flag[@]}" \
        --tools "Bash,Read,Grep,Glob" \
        --allowedTools "${allowed[@]}" \
        --output-format json --json-schema "$SCHEMA" \
        --max-budget-usd "$BUDGET" ) > "$LOGS/$name.review.json" 2>"$LOGS/$name.review.err"
  rc=$?
  set -e

  if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
    echo "   the review was interrupted (exit $rc); the task keeps its status"
    interrupted
  fi

  outcome=$(python3 "$HARNESS/verdict.py" "$LOGS/$name.review.json" "$task" "$rc" "$TEST_CMD")
  read -r verdict denied usable <<<"$outcome"

  echo "   verdict: $verdict (denied commands: $denied, usable: $usable)"

  if [ "$usable" != "yes" ]; then
    rounds=$((rounds + 1))
    printf '%s' "$rounds" > "$rounds_file"
    if [ "$rounds" -ge "$MAX_ROUNDS" ]; then
      echo "   $rounds unusable review(s) -> blocked, a human has to look"
      tasks set "$task" status blocked --as reviewer
    else
      echo "   the review could not be relied on; see $task/REVIEW.unusable.md"
    fi
    [ -s "$LOGS/$name.review.err" ] && tail -n 5 "$LOGS/$name.review.err" | sed 's/^/     /'
    printf '   result: %s\n' "$(python3 -c "
import json,sys
try:
    print(str(json.load(open(sys.argv[1])).get('result',''))[:400])
except Exception as exc:
    print(f'the envelope could not be read: {exc}')" "$LOGS/$name.review.json")"
    continue
  fi

  rm -f "$rounds_file"
  case "$verdict" in
    passed)
      tasks set "$task" verify passed --as reviewer
      tasks set "$task" status done --as reviewer
      echo "   -> done"
      judged=$((judged + 1)) ;;
    failed)
      tasks set "$task" verify failed --as reviewer
      tasks set "$task" status todo --as reviewer
      rm -f "$STATE/attempts/$name" "$STATE/sessions/$name"
      echo "   -> back to todo, with REVIEW.md for the next run to read"
      judged=$((judged + 1)) ;;
    blocked)
      tasks set "$task" status blocked --as reviewer
      echo "   -> blocked, a human has to settle it"
      judged=$((judged + 1)) ;;
  esac
done

echo
echo "reviewed: $started, settled: $judged"
tasks queue review >/dev/null || echo "the review queue is empty"
