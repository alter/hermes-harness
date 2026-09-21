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
FALLBACK=${HH_REVIEW_FALLBACK:-sonnet}
EFFORT=${HH_REVIEW_EFFORT:-high}
BUDGET=${HH_REVIEW_BUDGET:-5}
TEST_CMD=${HH_TEST_COMMAND:-}
ONLY=${HH_REVIEW_ONLY:-}
PREGATE=${HH_PREGATE:-1}
PATTERN=${HH_PREGATE_PATTERN:-}
MAX_RETURNS=${HH_MAX_RETURNS:-3}
INFRA_MAX=${HH_REVIEW_INFRA_MAX:-3}
INFRA_DEFER=${HH_REVIEW_INFRA_DEFER:-3600}
DIFF_LIMIT=${HH_REVIEW_DIFF_CHARS:-200000}
STATE="$PROJECT/.hermes-harness"
LOGS="$STATE/logs"

command -v claude >/dev/null 2>&1 || { echo "claude is not on PATH" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "no task tree at $ROOT" >&2; exit 1; }
[ -f "$HARNESS/tasks.py" ] || { echo "harness not installed at $HARNESS (run install.sh)" >&2; exit 1; }
mkdir -p "$LOGS" "$STATE/review-rounds" "$STATE/review" "$STATE/returns" "$STATE/baseline" "$STATE/review-infra"
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
fallback_flag=()
case "$help" in
  *--fallback-model*) [ -n "$FALLBACK" ] && fallback_flag=(--fallback-model "$FALLBACK") ;;
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

ledger() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "${6:-}" \
    >> "$STATE/ledger.tsv"
}

log_call() {
  python3 - "$LOGS/$1.review.json" "$1" "$2" >> "$STATE/calls.tsv" <<'PY'
import datetime, json, sys
path, name, rc = sys.argv[1:4]
try:
    env = json.load(open(path, encoding="utf-8"))
except Exception:
    env = None
env = env if isinstance(env, dict) else {}
usage = env.get("usage") if isinstance(env.get("usage"), dict) else {}
num = lambda v: str(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else "?"
print("\t".join([datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), name, rc,
                 num(env.get("total_cost_usd")), num(env.get("num_turns")),
                 num(usage.get("input_tokens")), num(usage.get("output_tokens")),
                 env.get("subtype") if isinstance(env.get("subtype"), str) else "?"]))
PY
}

is_deferred() {
  local count=0 at=0
  [ -f "$STATE/review-infra/$1" ] || return 1
  read -r count at < "$STATE/review-infra/$1" || true
  [ "${count:-0}" -ge "$INFRA_MAX" ] && [ $(( $(date +%s) - ${at:-0} )) -lt "$INFRA_DEFER" ]
}

next_in_queue() {
  local t
  while IFS= read -r t; do
    is_deferred "$(slug "$t")" || { printf '%s\n' "$t"; return 0; }
  done < <(tasks queue review || true)
  return 1
}

work_fingerprint() {
  ( cd "$WORKDIR" || exit 0
    { git diff HEAD -- . ':!.hermes-notes' 2>/dev/null
      git ls-files -o --exclude-standard -- . ':!.hermes-notes' 2>/dev/null \
        | while IFS= read -r f; do printf '%s ' "$f"; sha1sum "$f" 2>/dev/null | cut -d' ' -f1; echo; done
    } | sha1sum | cut -d' ' -f1 ) || echo none
}

# What the writing loop left behind: a commit it made, or the uncommitted state
# of the working tree. A new file is untracked, so `git diff HEAD` alone would
# show the reviewer a change with its most important half missing.
capture_diff() {
  local name=$1 out=$2 ref
  ref=$(cat "$STATE/review/$name" 2>/dev/null || echo worktree)
  ( cd "$WORKDIR"
    case "$ref" in
      range\ *)
        printf '# the change under review is the range %s\n\n' "${ref#range }"
        git log --oneline "${ref#range }" 2>/dev/null
        echo
        git diff --stat --patch "${ref#range }" -- . ':!.hermes-notes' 2>/dev/null ;;
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

# The cheap half of judging. A change that breaks a test which was passing
# before does not need a reader to say so, and a reader is the expensive part.
# The gate only ever sends work back; it never lets anything through to done.
baseline_ref() {
  local ref
  ref=$(cat "$STATE/review/$1" 2>/dev/null || echo worktree)
  case "$ref" in
    range\ *)  printf '%s' "${ref#range }" | sed 's/\.\..*//' ;;
    commit\ *) printf '%s^' "${ref#commit }" ;;
    *) printf 'HEAD' ;;
  esac
}

run_check() {
  local dir=$1 out=$2 rc=0
  ( cd "$dir" && eval "$TEST_CMD" ) > "$out" 2>&1 || rc=$?
  return "$rc"
}

# Empty means there is no baseline to compare against, which is not the same as
# a baseline of zero failures.
BASELINE_RC=""
baseline_check() {
  local ref=$1 out=$2 sha key cache tree rc=0
  BASELINE_RC=""
  sha=$( cd "$WORKDIR" && git rev-parse "$ref" 2>/dev/null ) || return 0
  key=$(printf '%s %s' "$sha" "$TEST_CMD" | sha1sum | cut -d' ' -f1)
  cache="$STATE/baseline/$key"
  if [ -f "$cache.out" ] && [ -f "$cache.rc" ]; then
    cp "$cache.out" "$out"
    BASELINE_RC=$(cat "$cache.rc")
    echo "   baseline at ${sha:0:8}: remembered, exit $BASELINE_RC"
    return 0
  fi
  tree=$(mktemp -d "${TMPDIR:-/tmp}/hh-baseline.XXXXXX")
  if ! ( cd "$WORKDIR" && git worktree add --detach "$tree" "$sha" ) >/dev/null 2>&1; then
    rmdir "$tree" 2>/dev/null || true
    echo "   baseline at ${sha:0:8}: a working copy could not be made"
    return 0
  fi
  echo "   baseline at ${sha:0:8}: measuring it once, this is the slow part"
  run_check "$tree" "$out" || rc=$?
  ( cd "$WORKDIR" && git worktree remove --force "$tree" ) >/dev/null 2>&1 || true
  cp "$out" "$cache.out"
  printf '%s' "$rc" > "$cache.rc"
  BASELINE_RC=$rc
  return 0
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
    task=$(next_in_queue) || {
      if tasks queue review >/dev/null; then
        echo "== everything waiting in review is put off after repeated reviewer failures; see status.sh"
        exit 75
      fi
      echo "== nothing waiting in review"; break
    }
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

  gate=go
  new_failures=""
  check_out="$LOGS/$name.check.out"
  if [ "$PREGATE" = "1" ] && [ -n "$TEST_CMD" ]; then
    ref=$(baseline_ref "$name")
    work_rc=0
    if [ -f "$check_out" ] && [ -f "$LOGS/$name.check.fp" ] && [ -f "$LOGS/$name.check.rc" ] \
       && [ "$(cat "$LOGS/$name.check.fp")" = "$(work_fingerprint)" ]; then
      work_rc=$(cat "$LOGS/$name.check.rc")
      echo "   the project's check was already run against this exact tree: exit $work_rc, reusing it"
    else
      echo "   the project's check first: $TEST_CMD"
      run_check "$WORKDIR" "$check_out" || work_rc=$?
      printf '%s' "$work_rc" > "$LOGS/$name.check.rc"
      work_fingerprint > "$LOGS/$name.check.fp"
      echo "   it exited $work_rc here"
    fi
    baseline_check "$ref" "$LOGS/$name.baseline.out"
    if [ -z "$BASELINE_RC" ]; then
      echo "   no baseline to compare with, so the gate decides nothing"
    else
      set +e
      new_failures=$(python3 "$HARNESS/pregate.py" "$LOGS/$name.baseline.out" "$check_out" \
        --baseline-rc "$BASELINE_RC" --work-rc "$work_rc" ${PATTERN:+--pattern "$PATTERN"})
      prc=$?
      set -e
      case "$prc" in
        1) gate=back ;;
        2) echo "   the baseline names nothing, so the gate decides nothing" ;;
        *) echo "   the check is no worse than at $ref -> worth reading" ;;
      esac
    fi
  fi

  if [ "$gate" = "back" ]; then
    count=$(printf '%s\n' "$new_failures" | grep -c . || true)
    echo "   the change breaks $count check(s) that passed at $ref -> back without a reader"
    {
      printf '# The project'"'"'s own check, before anyone read the code\n\n'
      printf '`%s`, run in %s.\n\n' "$TEST_CMD" "$WORKDIR"
      if [ "$count" -gt 0 ]; then
        printf 'It fails in %s place(s) that were passing at %s:\n\n' "$count" "$ref"
        printf '%s\n' "$new_failures" | sed 's/^/- `/; s/$/`/'
      else
        printf 'It fails here and passed at %s.\n' "$ref"
      fi
      printf '\nThe tail of its output:\n\n```\n'
      tail -n 40 "$check_out"
      printf '```\n\nNobody has read the change yet. Make the check pass, and it goes to a reviewer.\n'
    } > "$task/CHECK.md"
    # Whatever a reader concluded last time was about work that has since changed.
    tasks set "$task" verify pending --as reviewer
    returns=$(( $(cat "$STATE/returns/$name" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$returns" > "$STATE/returns/$name"
    if [ "$returns" -ge "$MAX_RETURNS" ]; then
      echo "   sent back $returns times -> blocked, a human has to look"
      tasks set "$task" status blocked --as reviewer
      ledger "$name" gate review blocked "returned $returns times; last: $count new failure(s)"
    else
      tasks set "$task" status todo --as reviewer
      ledger "$name" gate review todo "$count new failure(s) against $ref"
      rm -f "$STATE/attempts/$name" "$STATE/sessions/$name"
    fi
    continue
  fi

  allowed=(Read Grep Glob
           "Bash(git diff:*)" "Bash(git show:*)" "Bash(git log:*)" "Bash(git status:*)"
           "Bash(git ls-files:*)" "Bash(rg:*)" "Bash(sed -n:*)" "Bash(wc:*)" "Bash(ls:*)")
  [ -n "$TEST_CMD" ] && allowed+=("Bash(${TEST_CMD%% *}:*)") || true

  # One generation back is kept: the second round overwriting the first is how
  # the cost and the turn count of a good review get lost.
  [ -f "$LOGS/$name.review.json" ] && mv -f "$LOGS/$name.review.json" "$LOGS/$name.review.previous.json" || true

  set +e
  check_arg=()
  [ -s "$check_out" ] && check_arg=(--check-output "$check_out") || true
  tasks review-prompt "$task" --diff "$diff_file" --test-command "$TEST_CMD" --workdir "$WORKDIR" \
    "${check_arg[@]}" \
    | ( cd "$WORKDIR" && claude -p \
        --model "$MODEL" "${effort_flag[@]}" "${fallback_flag[@]}" \
        --permission-mode dontAsk "${prompts_flag[@]}" \
        --tools "Bash,Read,Grep,Glob" \
        --allowedTools "${allowed[@]}" \
        --output-format json --json-schema "$SCHEMA" \
        --max-budget-usd "$BUDGET" ) > "$LOGS/$name.review.json" 2>"$LOGS/$name.review.err"
  rc=$?
  set -e
  log_call "$name" "$rc"

  cost=$(python3 -c "
import json,sys
try:
    print(f\"{json.load(open(sys.argv[1])).get('total_cost_usd', 0):.2f}\")
except Exception:
    print('?')" "$LOGS/$name.review.json")

  if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
    echo "   the review was interrupted (exit $rc); the task keeps its status"
    interrupted
  fi

  outcome=$(python3 "$HARNESS/verdict.py" "$LOGS/$name.review.json" "$task" "$rc" "$TEST_CMD") || {
    echo "   the verdict could not be parsed (verdict.py failed); counted as an unusable review" >&2
    outcome="none 0 no"
  }
  read -r verdict denied usable <<<"$outcome"

  if [ "$usable" = "infra" ]; then
    infra=$(( $(cut -d' ' -f1 "$STATE/review-infra/$name" 2>/dev/null || echo 0) + 1 ))
    printf '%s %s\n' "$infra" "$(date +%s)" > "$STATE/review-infra/$name"
    echo "   the reviewer call failed (claude exited $rc); nothing is counted and nothing is blocked"
    [ -s "$LOGS/$name.review.err" ] && tail -n 5 "$LOGS/$name.review.err" | sed 's/^/     /'
    ledger "$name" reviewer review review "reviewer call failed (exit $rc), $infra in a row for this task" "$cost"
    [ "$infra" -ge "$INFRA_MAX" ] && echo "   $infra in a row: $name is put off for ${INFRA_DEFER}s so the queue can move; it stays in review"
    exit 75
  fi
  rm -f "$STATE/review-infra/$name"

  echo "   verdict: $verdict (denied commands: $denied, usable: $usable)"
  echo "   cost: $cost USD"

  if [ "$usable" != "yes" ]; then
    rounds=$((rounds + 1))
    printf '%s' "$rounds" > "$rounds_file"
    if [ "$rounds" -ge "$MAX_ROUNDS" ]; then
      echo "   $rounds unusable review(s) -> blocked, a human has to look"
      tasks set "$task" status blocked --as reviewer
      ledger "$name" reviewer review blocked "$rounds unusable reviews" "$cost"
    else
      ledger "$name" reviewer review review "unusable review" "$cost"
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
      ledger "$name" reviewer review done "passed" "$cost"
      rm -f "$STATE/returns/$name"
      echo "   -> done"
      judged=$((judged + 1)) ;;
    failed)
      returns=$(( $(cat "$STATE/returns/$name" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$returns" > "$STATE/returns/$name"
      tasks set "$task" verify failed --as reviewer
      if [ "$returns" -ge "$MAX_RETURNS" ]; then
        tasks set "$task" status blocked --as reviewer
        ledger "$name" reviewer review blocked "failed; returned $returns times" "$cost"
        echo "   -> sent back $returns times already; blocked, a human has to look"
      else
        tasks set "$task" status todo --as reviewer
        ledger "$name" reviewer review todo "failed" "$cost"
        rm -f "$STATE/attempts/$name" "$STATE/sessions/$name"
        echo "   -> back to todo, with REVIEW.md for the next run to read"
      fi
      judged=$((judged + 1)) ;;
    blocked)
      tasks set "$task" status blocked --as reviewer
      ledger "$name" reviewer review blocked "reviewer could not judge it" "$cost"
      echo "   -> blocked, a human has to settle it"
      judged=$((judged + 1)) ;;
    *)
      tasks set "$task" status blocked --as reviewer
      ledger "$name" reviewer review blocked "verdict '$verdict' is not one the harness knows" "$cost"
      echo "   -> blocked: '$verdict' is not a verdict"
      judged=$((judged + 1)) ;;
  esac
done

echo
echo "reviewed: $started, settled: $judged"
tasks queue review >/dev/null || echo "the review queue is empty"
