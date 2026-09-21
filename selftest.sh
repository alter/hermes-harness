#!/usr/bin/env bash
# selftest.sh
set -uo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
TARGET=${1:-$SRC}
TARGET=${TARGET/#\~/$HOME}
[ -d "$TARGET/harness" ] && H="$TARGET/harness" || H="$TARGET"
[ -d "$H/hooks" ] || { echo "no hooks dir at $H/hooks" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n        got: %s\n' "$1" "$(printf '%s' "$2" | head -c 240)"; }
check(){ if printf '%s' "$2" | grep -qE "$3"; then ok "$1"; else bad "$1" "$2"; fi; }
empty(){ if [ -z "$2" ]; then ok "$1"; else bad "$1" "$2"; fi; }
hook() { printf '%s' "$2" | python3 "$H/hooks/$1" 2>/dev/null; }
rc()   { printf '%s' "$2" | python3 "$H/hooks/$1" >/dev/null 2>&1; echo $?; }

echo "== syntax"
for f in "$H"/hooks/*.py "$H/tasks.py"; do
  [ -e "$f" ] || continue
  if python3 -c "import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())" "$f" 2>/dev/null
  then ok "python -m ast $(basename "$f")"; else bad "python -m ast $(basename "$f")" "syntax error"; fi
done
for f in "$SRC"/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")" "syntax error"; fi
  # A script that arrives without its executable bit is a script nobody can run,
  # and git records the bit, so losing it survives the next clone.
  if [ -x "$f" ]; then ok "$(basename "$f") is executable"; else bad "$(basename "$f") is executable" "mode 644"; fi
done
if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$SRC/config.yaml" 2>/dev/null
then ok "config.yaml is valid YAML"; else bad "config.yaml is valid YAML" "does not parse"; fi

echo "== guard-paths"
cwd="$TMP/repo"; mkdir -p "$cwd/tasks/10-x/01-y"
p() { printf '{"tool_name":"%s","tool_input":%s,"cwd":"%s"}' "$1" "$2" "$cwd"; }
check "write_file into labels.txt is blocked" \
  "$(hook guard-paths.py "$(p write_file '{"path":"tasks/10-x/01-y/labels.txt","content":"x"}')")" 'is not yours to write'
empty "write_file NOTES.md is allowed" \
  "$(hook guard-paths.py "$(p write_file '{"path":"tasks/10-x/01-y/NOTES.md","content":"x"}')")"
empty "write_file BLOCKED.md is allowed" \
  "$(hook guard-paths.py "$(p write_file '{"path":"tasks/10-x/01-y/BLOCKED.md","content":"x"}')")"
empty "write_file outside the tree is allowed" \
  "$(hook guard-paths.py "$(p write_file '{"path":"src/app.py","content":"x"}')")"
check "patch on task.txt is blocked" \
  "$(hook guard-paths.py "$(p patch '{"path":"tasks/10-x/01-y/task.txt","old_string":"a","new_string":"b"}')")" 'is not yours to write'
check "a V4A patch header into the tree is blocked" \
  "$(hook guard-paths.py "$(p patch '{"mode":"patch","patch":"*** Update File: tasks/10-x/01-y/labels.txt\n-a\n+b\n"}')")" 'is not yours to write'
check "an absolute path into the tree is blocked" \
  "$(hook guard-paths.py "$(p write_file "{\"path\":\"$cwd/tasks/10-x/01-y/labels.txt\",\"content\":\"x\"}")")" 'is not yours to write'
check "traversal into the tree is blocked" \
  "$(hook guard-paths.py "$(p write_file '{"path":"sub/../tasks/10-x/01-y/labels.txt","content":"x"}')")" 'is not yours to write'
check "sed -i through the shell is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"sed -i s/todo/done/ tasks/10-x/01-y/labels.txt"}')")" 'names labels.txt'
check "a redirect into the tree is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"echo done > tasks/10-x/01-y/labels.txt"}')")" 'names labels.txt'
check "python -c writing into the tree is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"python3 -c open(\"tasks/10-x/01-y/labels.txt\",\"w\")"}')")" 'names labels.txt'
check "reading the tree through the shell is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"cat tasks/10-x/01-y/labels.txt"}')")" 'names labels.txt'
empty "an unrelated command is allowed" "$(hook guard-paths.py "$(p terminal '{"command":"pytest -q"}')")"
check "the shell may not touch the tree at all, even to git add" \
  "$(hook guard-paths.py "$(p terminal '{"command":"git add tasks/10-x/01-y/NOTES.md"}')")" 'names a path under'
check "malformed input fails closed" "$(hook guard-paths.py 'not json')" 'refusing rather than guessing'

for probe in \
  'python3 -c "import pathlib;pathlib.Path(\"tasks\",\"10-x\",\"labels.txt\").write_text(\"x\")"|a path built piece by piece' \
  'python3 -c "import os;open(os.path.join(\"tasks\",\"labels.txt\"),\"w\")"|os.path.join' \
  'perl -e "open(F,\">\",\"tasks/10-x/labels.txt\")"|perl' \
  'node -e "require(\"fs\").writeFileSync(\"tasks/10-x/labels.txt\",\"x\")"|node' \
  'bash -c "echo done > tasks/10-x/labels.txt"|a nested shell' \
  'cd tasks/10-x/01-hello && echo x > labels.txt|cd then write' \
  'python3 -c "open(\"labels.txt\",\"w\")"|the bare protected name'
do
  cmd=${probe%|*}; label=${probe##*|}
  out=$(hook guard-paths.py "$(p terminal "{\"command\":\"$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')\"}")")
  if [ -n "$out" ]; then ok "bypass refused: $label"; else bad "bypass refused: $label" "allowed: $cmd"; fi
done

for probe in \
  'pytest tests/test_tasks.py -q|a test file whose name contains tasks' \
  'python3 scripts/build.py --out dist|a project script' \
  'python3 -c "open(\"src/a.py\",\"w\").write(\"x\")"|writing outside the tree' \
  'python3 -m celery -A app.tasks worker|a module path containing tasks'
do
  cmd=${probe%|*}; label=${probe##*|}
  out=$(hook guard-paths.py "$(p terminal "{\"command\":\"$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')\"}")")
  empty "still allowed: $label" "$out"
done
[ "$(rc guard-paths.py "$(p write_file '{"path":"tasks/10-x/01-y/labels.txt","content":"x"}')")" = "2" ] \
  && ok "a block exits 2" || bad "a block exits 2" "wrong exit code"

echo "== guard-notes"
nt="$TMP/notes"; mkdir -p "$nt"
gn() { printf '%s' "$2" | HH_NOTES_FILE="$nt/NOTES.md" python3 "$H/hooks/guard-notes.py" 2>/dev/null; }
check "stopping with no record is refused" \
  "$(gn x '{"extra":{"attempt":1,"changed_paths":["src/a.py"]}}')" 'about to stop without a record'
check "the refusal names the files that changed" \
  "$(gn x '{"extra":{"changed_paths":["src/a.py"]}}')" 'src/a\.py'
echo "done" > "$nt/NOTES.md"
check "a one-word record is not a record" "$(gn x '{"extra":{}}')" 'without a record'
python3 -c "import sys; open(sys.argv[1],'w').write('x'*200)" "$nt/NOTES.md"
empty "a real record lets it stop" "$(gn x '{"extra":{}}')"
rm -f "$nt/NOTES.md"; python3 -c "import sys; open(sys.argv[1],'w').write('y'*200)" "$nt/BLOCKED.md"
empty "an honest BLOCKED.md counts as a record" "$(gn x '{"extra":{}}')"
empty "without HH_NOTES_FILE the guard stays out of the way" \
  "$(printf '%s' '{"extra":{}}' | python3 "$H/hooks/guard-notes.py" 2>/dev/null)"
check "config registers it on pre_verify" "$(cat "$SRC/config.yaml")" 'pre_verify'
check "and raises the nudge ceiling"      "$(cat "$SRC/config.yaml")" 'max_verify_nudges: 8'

echo "== guard-read"
big="$cwd/big.py"; seq 1 900 | sed 's/^/x = /' > "$big"; seq 1 900 > "$cwd/big.md"; seq 1 100 > "$cwd/small.py"
check "cat on a 900-line file is blocked" \
  "$(hook guard-read.py "$(p terminal '{"command":"cat big.py"}')")" 'would pour all of it'
empty "cat on a small file is allowed"    "$(hook guard-read.py "$(p terminal '{"command":"cat small.py"}')")"
empty "cat on markdown is allowed"        "$(hook guard-read.py "$(p terminal '{"command":"cat big.md"}')")"
check "head -n 900 is blocked"            "$(hook guard-read.py "$(p terminal '{"command":"head -n 900 big.py"}')")" 'would pour all of it'
empty "head -n 20 is allowed"             "$(hook guard-read.py "$(p terminal '{"command":"head -n 20 big.py"}')")"
empty "tail -5 is allowed"                "$(hook guard-read.py "$(p terminal '{"command":"tail -5 big.py"}')")"
check "tail -n +5 is blocked"             "$(hook guard-read.py "$(p terminal '{"command":"tail -n +5 big.py"}')")" 'would pour all of it'
empty "a pipeline is left alone"          "$(hook guard-read.py "$(p terminal '{"command":"cat big.py | head -20"}')")"
check "a segment after && is judged"      "$(hook guard-read.py "$(p terminal '{"command":"cd . && cat big.py"}')")" 'would pour all of it'
empty "guard-read ignores other tools"    "$(hook guard-read.py "$(p write_file '{"path":"big.py","content":"x"}')")"

echo "== tasks.py"
T="$TMP/tree"; mkdir -p "$T/10-a/01-first" "$T/10-a/02-second" "$T/20-b/01-human"
mk() { printf 'TASK: %s\nGOAL\n  %s\nCONTEXT\n  -\nSCOPE\n  + x\n  − y\nOUTCOME\n  %s\nVERIFY\n  `%s`\nROLE\n  %s\nDEPENDS\n  %s\n' \
        "$2" "$2" "$3" "$4" "$5" "${6:--}" > "$1/task.txt"; }
mk "$T/10-a/01-first"  "first"  "src/a.py" "true"  "AGENT"
mk "$T/10-a/02-second" "second" "src/b.py" "false" "AGENT" "10-a/01-first"
mk "$T/20-b/01-human"  "human"  "docs/x.md" "true" "HUMAN"
printf 'phase: a\nrole: AGENT\ntype: feature\npriority: P1\nstatus: todo\nverify: pending\nmilestone: M1\n' > "$T/10-a/01-first/labels.txt"
printf 'phase: a\nrole: AGENT\ntype: feature\npriority: P0\nstatus: todo\nverify: pending\nmilestone: M1\ndepends: 10-a/01-first\n' > "$T/10-a/02-second/labels.txt"
printf 'phase: b\nrole: HUMAN\ntype: chore\npriority: P0\nstatus: todo\nverify: pending\nmilestone: M1\n' > "$T/20-b/01-human/labels.txt"
tp() { python3 "$H/tasks.py" --root "$T" "$@" 2>&1; }
check "next skips a HUMAN task and an unmet dependency" "$(tp next)" '10-a/01-first$'
check "list marks the ready one"                        "$(tp list)" 'ready .*01-first'
check "list explains why a task is not ready"           "$(tp list)" 'role is HUMAN'
check "list explains an unmet dependency"               "$(tp list)" 'depends 10-a/01-first is todo'
check "the prompt carries the task body"                "$(tp prompt "$T/10-a/01-first")" 'GOAL'
check "the prompt states the tree is not the agent's"   "$(tp prompt "$T/10-a/01-first")" 'not in your working directory and is not yours to write'
check "the prompt forbids claiming completion"          "$(tp prompt "$T/10-a/01-first")" 'never write status: or verify:'
tp set "$T/10-a/01-first" status done >/dev/null
check "status can be written"                           "$(cat "$T/10-a/01-first/labels.txt")" 'status: done'
check "a met dependency releases the next task"         "$(tp next)" '10-a/02-second$'
check "verify: is refused"                              "$(tp set "$T/10-a/01-first" verify passed)" "not agent's to write"
check "verify: is still pending"                        "$(cat "$T/10-a/01-first/labels.txt")" 'verify: pending'
tp set "$T/10-a/02-second" status done >/dev/null
[ -z "$(tp next)" ] && ok "next says nothing when the tree is closed" || bad "next says nothing when the tree is closed" "$(tp next)"

mkdir -p "$T/30-c/01-multi"
mk "$T/30-c/01-multi" "multi" "src/c.py" "true" "AGENT" "10-a/01-first, 20-b/01-human"
printf 'phase: c\nrole: AGENT\ntype: feature\npriority: P0\nstatus: todo\nverify: pending\nmilestone: M1\ndepends: 10-a/01-first, 20-b/01-human\n' > "$T/30-c/01-multi/labels.txt"
check "a comma-separated depends waits on the unmet one" "$(tp list)" 'depends 20-b/01-human is todo'
tp set "$T/20-b/01-human" status done >/dev/null
check "it becomes ready when every dependency is done" "$(tp list)" 'ready .*30-c/01-multi'
printf 'phase: c\nrole: AGENT\ntype: feature\npriority: P0\nstatus: todo\nverify: pending\nmilestone: M1\ndepends: -\n' > "$T/30-c/01-multi/labels.txt"
check "a dash means no dependency" "$(tp list)" 'ready .*30-c/01-multi'

sfx="$TMP/suffix"; mkdir -p "$sfx"
printf 'TASK: t\nGOAL\n  g\nCONTEXT\n  -\nSCOPE\n  + a\n  \xe2\x88\x92 b\nOUTCOME\n  prose, no path at all\nVERIFY (architect / verifier)\n  1. a criterion a human judges\nROLE\n  AGENT\nDEPENDS\n  -\n' > "$sfx/task.txt"
out=$(python3 - "$sfx/task.txt" "$H" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[2])
import tasks
body = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
print("OUTCOME=" + tasks.section(body, "OUTCOME"))
print("VERIFY=" + tasks.section(body, "VERIFY").splitlines()[0].strip())
print("ROLE=" + tasks.section(body, "ROLE"))
PY
)
check "a suffixed VERIFY header is still the VERIFY section" "$out" 'VERIFY=1\. a criterion'
check "OUTCOME stops at the suffixed header"                 "$out" 'OUTCOME=prose, no path at all'
check "the section after it is still found"                  "$out" 'ROLE=AGENT'
printf 'phase: c\nrole: AGENT\ntype: research\npriority: P0\nstatus: todo\nverify: pending\nmilestone: M1\n' > "$sfx/labels.txt"
out=$(python3 "$H/tasks.py" --root "$TMP" prompt "$sfx" --notes /tmp/notes-here 2>&1)
check "the prompt names the notes directory"        "$out" '/tmp/notes-here/NOTES.md'
check "the prompt says VERIFY is judged by a human" "$out" 'criteria a human'
check "the prompt forbids recreating the tree"      "$out" 'Do not recreate it'

echo "== review"
rv="$TMP/rv"; mkdir -p "$rv"
printf 'TASK: t\nGOAL\n  g\nOUTCOME\n  o\nVERIFY (architect)\n  1. a criterion\nROLE\n  AGENT\nDEPENDS\n  -\n' > "$rv/task.txt"
printf 'priority: P0\nstatus: review\nverify: pending\nrole: AGENT\ndepends: none\n' > "$rv/labels.txt"
check "depends: none is no dependency at all" "$(python3 "$H/tasks.py" --root "$TMP" list 2>&1)" 'review .*rv'
out=$(python3 "$H/tasks.py" --root "$TMP" set "$rv" verify passed 2>&1); rcv=$?
check "the agent may not write verify:" "$out" "not agent's to write"
[ "$rcv" -ne 0 ] && ok "refusing to write verify: exits non-zero" || bad "refusing to write verify: exits non-zero" "exit 0"
python3 "$H/tasks.py" --root "$TMP" set "$rv" verify passed --as reviewer >/dev/null 2>&1
check "the reviewer may write verify:" "$(cat "$rv/labels.txt")" 'verify: passed'
python3 "$H/tasks.py" --root "$TMP" set "$rv" status review --as reviewer >/dev/null 2>&1
check "the review queue holds it" "$(python3 "$H/tasks.py" --root "$TMP" queue review 2>&1)" 'rv$'
printf 'priority: P0\nstatus: review\nverify: pending\nrole: HUMAN\ndepends: -\n' > "$rv/labels.txt"
empty "a HUMAN task is not queued for an automated review" \
  "$(python3 "$H/tasks.py" --root "$TMP" queue review 2>/dev/null)"
printf 'priority: P0\nstatus: review\nverify: pending\nrole: AGENT\ndepends: -\n' > "$rv/labels.txt"
printf 'a diff line\n' > "$TMP/d.diff"
out=$(python3 "$H/tasks.py" --root "$TMP" review-prompt "$rv" --diff "$TMP/d.diff" --test-command "pytest -q" 2>&1)
check "the review prompt carries the change"          "$out" 'a diff line'
check "the review prompt names the project check"     "$out" 'pytest -q'
check "the review prompt refuses unsupported passes"  "$out" 'refused by the harness'
check "the review prompt says notes are claims"       "$out" 'not evidence'
printf '# Review — failed\n\nthe second argument is unchecked\n' > "$rv/REVIEW.md"
check "a returned task carries its review into the next run" \
  "$(python3 "$H/tasks.py" --root "$TMP" prompt "$rv" --notes /tmp/n 2>&1)" 'the second argument is unchecked'
prompt_out=$(python3 "$H/tasks.py" --root "$TMP" prompt "$rv" --notes /tmp/n 2>&1)
check "and says so in its first lines, not halfway down" \
  "$(printf '%s' "$prompt_out" | head -n 5)" 'not a first attempt'
check "the review is argued at the end, where it is read last" \
  "$(printf '%s' "$prompt_out" | tail -n 12)" 'the second argument is unchecked'
check "the closing instruction still comes last" \
  "$(printf '%s' "$prompt_out" | tail -n 1)" 'DONE'
rvs=$(cat "$SRC/review.sh")
check "the review runs with permissions that deny writes" "$rvs" 'permission-mode dontAsk'
check "the review asks for a structured verdict"          "$rvs" 'json-schema'
check "the review runs at the effort it was given"        "$rvs" 'effort_flag'
check "the review never commits"                          "$(printf '%s' "$rvs" | grep -c 'git commit' || true)" '^0$'
check "the review never bypasses permissions"             "$(printf '%s' "$rvs" | grep -c 'skip-permissions\|bypassPermissions' || true)" '^0$'
check "one named task can be reviewed on its own"        "$rvs" 'HH_REVIEW_ONLY'
check "a task outside review is refused by name"         "$rvs" 'not review'
check "the previous envelope is kept, not overwritten"   "$rvs" 'review.previous.json'
check "the price of a review is printed"                 "$rvs" 'total_cost_usd'

echo "== pregate"
pg="$TMP/pg"; mkdir -p "$pg"
printf 'FAILED tests/a.py::test_one - boom\nFAILED tests/b.py::test_two - boom\n2 failed\n' > "$pg/base"
printf 'FAILED tests/a.py::test_one - boom\nFAILED tests/b.py::test_two - boom\n2 failed\n' > "$pg/same"
printf 'FAILED tests/a.py::test_one - boom\nFAILED tests/c.py::test_new - boom\n2 failed\n' > "$pg/worse"
printf 'FAILED tests/a.py::test_one - boom\n1 failed\n' > "$pg/better"
printf 'ImportError while loading conftest\n' > "$pg/broken"
printf 'all good\n' > "$pg/green"
pg_rc() { python3 "$H/pregate.py" "$1" "$2" --baseline-rc "$3" --work-rc "$4" >/dev/null 2>&1; echo $?; }
check "a failure that was already there is not the change's fault" "$(pg_rc "$pg/base" "$pg/same" 1 1)" '^0$'
check "a new failure sends the work back"                          "$(pg_rc "$pg/base" "$pg/worse" 1 1)" '^1$'
check "it names the failure that is new" \
  "$(python3 "$H/pregate.py" "$pg/base" "$pg/worse" --baseline-rc 1 --work-rc 1)" 'tests/c.py::test_new'
check "fixing one of them is not a reason to send it back"         "$(pg_rc "$pg/base" "$pg/better" 1 1)" '^0$'
check "a baseline that names nothing decides nothing"              "$(pg_rc "$pg/broken" "$pg/worse" 2 1)" '^2$'
check "red where it was green sends it back even unparsed"         "$(pg_rc "$pg/green" "$pg/broken" 0 1)" '^1$'
check "green stays green"                                          "$(pg_rc "$pg/green" "$pg/green" 0 0)" '^0$'
printf 'boom in module alpha\n' > "$pg/other"
check "the pattern is the caller's to choose" \
  "$(python3 "$H/pregate.py" "$pg/green" "$pg/other" --baseline-rc 0 --work-rc 1 --pattern 'boom in module (\S+)')" '^alpha$'
printf 'FAILED tests/x.py::t - e\n' > "$TMP/co"
out=$(python3 "$H/tasks.py" --root "$TMP" review-prompt "$rv" --diff "$TMP/d.diff" \
        --test-command "pytest -q" --check-output "$TMP/co" 2>&1)
check "the reviewer is told the check has already run" "$out" 'already been run'
check "and is shown what it printed"                   "$out" 'tests/x.py::t'
printf '# The check\n\n- `tests/x.py::t`\n' > "$rv/CHECK.md"
check "the gate's note reaches the next run" \
  "$(python3 "$H/tasks.py" --root "$TMP" prompt "$rv" --notes /tmp/n 2>&1)" 'went backwards'
rm -f "$rv/CHECK.md"
check "the gate measures a baseline in its own working copy" "$rvs" 'git worktree add --detach'
check "the baseline is remembered per commit and command"   "$rvs" 'cache.rc'
check "being sent back too often blocks the task"           "$rvs" 'MAX_RETURNS'
check "a gate return clears the older verdict"            "$rvs" 'verify pending --as reviewer'

vd="$TMP/vd"; mkdir -p "$vd"
env_file="$TMP/envelope.json"
verdict_of() { python3 "$H/verdict.py" "$env_file" "$vd" "$1" "$2" 2>&1; }
# The reviewer was refused a command that merely starts with python3, and ran the
# project's check anyway. Matching the refusal by the first word called that a
# review that verified nothing, and threw away a good one.
cat > "$env_file" <<'JSON'
{"is_error": false,
 "permission_denials": [{"tool_name": "Bash", "tool_input": {"command": "timeout 120 python3 tools/verify/x.py > /tmp/v.txt"}}],
 "structured_output": {"verdict": "failed", "summary": "the sentinel is a class, not a call",
   "unmet": ["OUTCOME"],
   "evidence": [{"claim": "the suite fails", "command": "python3 -m pytest -q", "output": "124 failed, 2317 passed"}],
   "next_step": "make it an instance"}}
JSON
check "a refused command that is not the project's check keeps the review" \
  "$(verdict_of 0 'python3 -m pytest -q')" '^failed 1 yes$'
check "the refusal is still written down" "$(cat "$vd/REVIEW.md")" 'not allowed to run'
check "the evidence survives into the file" "$(cat "$vd/REVIEW.md")" '124 failed'
cat > "$env_file" <<'JSON'
{"is_error": false,
 "permission_denials": [{"tool_name": "Bash", "tool_input": {"command": "python3 -m pytest -q"}}],
 "structured_output": {"verdict": "passed", "summary": "looks fine", "unmet": [],
   "evidence": [{"claim": "read the code"}]}}
JSON
check "refusing the project's own check does ruin the review" \
  "$(verdict_of 0 'python3 -m pytest -q')" '^passed 1 no$'
check "an unusable review goes to its own file" "$(cat "$vd/REVIEW.unusable.md")" 'was refused'
check "it does not overwrite the usable one" "$(cat "$vd/REVIEW.md")" 'the sentinel is a class'
cat > "$env_file" <<'JSON'
{"is_error": false, "permission_denials": [],
 "structured_output": {"verdict": "passed", "summary": "trust me", "unmet": [], "evidence": []}}
JSON
check "a pass with no evidence is refused" "$(verdict_of 0 '')" '^passed 0 no$'
cat > "$env_file" <<'JSON'
{"is_error": false, "permission_denials": [], "result": "credit balance too low"}
JSON
check "a run that produced nothing is refused" "$(verdict_of 1 '')" '^none 0 no$'
check "the reason names the exit code" "$(cat "$vd/REVIEW.unusable.md")" 'claude exited 1'
cat > "$env_file" <<'JSON'
{"is_error": false, "permission_denials": [],
 "structured_output": {"verdict": "passed", "summary": "it holds", "unmet": [],
   "evidence": [{"claim": "the suite passes", "command": "python3 -m pytest -q", "output": "all green"}]}}
JSON
check "a supported pass is usable" "$(verdict_of 0 'python3 -m pytest -q')" '^passed 0 yes$'
empty "a usable review clears the unusable one" "$(cat "$vd/REVIEW.unusable.md" 2>/dev/null)"

echo "== notes form"
sc=$(python3 "$H/tasks.py" --root "$TMP" scaffold "$rv" 2>&1)
check "the form has one row per VERIFY criterion" "$(printf '%s' "$sc" | grep -c '(not checked) | (not checked)')" '^1$'
check "the form names the criterion"              "$sc" 'a criterion'
check "the form has the two prose sections"       "$(printf '%s' "$sc" | grep -c '(write here)')" '^2$'
nf="$TMP/nf"; mkdir -p "$nf"
printf '%s\n' "$sc" > "$nf/NOTES.md"
gnf() { printf '%s' "$2" | HH_NOTES_FILE="$nf/NOTES.md" python3 "$H/hooks/guard-notes.py" 2>/dev/null; }
check "an untouched form is refused even though it is long" \
  "$(gnf x '{"extra":{"changed_paths":["a.py"],"attempt":1}}')" 'still unfilled'
check "the refusal names the unchecked criterion" \
  "$(gnf x '{"extra":{"changed_paths":["a.py"]}}')" 'a criterion'
sed -i.bak 's/| (not checked) | (not checked) |/| ran pytest -q | 3 passed |/; s/(write here)/did the thing, nothing left open/' "$nf/NOTES.md"
empty "a filled form is accepted" "$(gnf x '{"extra":{"changed_paths":["a.py"]}}')"
rs=$(cat "$SRC/run.sh")
check "the writing loop lays out the form before the run" "$rs" 'tasks scaffold'
check "an untouched form does not count as notes"        "$rs" 'cmp -s .*\.scaffold'
check "the writing loop measures the project check itself" "$rs" 'Measured by the harness'
check "the measurement is kept for the reviewer to reuse"  "$rs" 'check\.fp'
check "every transition is written to the ledger"          "$(printf '%s' "$rs" | grep -c '^ *ledger ')" '^[6-9]$|^[1-9][0-9]$'
check "the reviewer reuses a measurement of the same tree" "$rvs" 'reusing it'
check "a range of commits can be the change under review" "$rvs" 'range\\ \*'
check "the reviewer has a fallback model"                  "$rvs" 'fallback-model'
check "the reviewer writes the ledger too"                 "$(printf '%s' "$rvs" | grep -c '^ *ledger ')" '^[5-9]$|^[1-9][0-9]$'
st=$(cd "$TMP" && HH_HOME="$H" HH_TASK_ROOT="$TMP" bash "$SRC/status.sh" "$TMP" 2>&1 || true)
check "status.sh reads a tree with no ledger yet" "$st" '== tree'
check "status.sh counts by status"                "$st" 'review'

echo "== config"
cfg=$(cat "$SRC/config.yaml")
check "approvals are off"              "$cfg" 'mode: "off"'
check "single-query approvals approve" "$cfg" 'single_query_mode: approve'
check "the denial breaker is disabled" "$cfg" 'denial_breaker_threshold: 0'
check "the turn ceiling is lifted"     "$cfg" 'max_turns: 0'
check "stop nudges are raised"         "$cfg" 'max_verify_nudges: 8'
check "memory is off"                  "$cfg" 'memory_enabled: false'
check "the curator is off"             "$cfg" 'curator:'
check "guard-paths is registered"      "$cfg" 'guard-paths.py'
check "guard-paths fails closed"       "$cfg" 'fail_closed: true'
check "the deny floor covers the tree" "$cfg" 'tasks/\*labels.txt'
check "the deny floor covers git push" "$cfg" 'git push'
check "hooks are auto-accepted"        "$cfg" 'hooks_auto_accept: true'

allow="$TARGET/shell-hooks-allowlist.json"
if [ -f "$allow" ]; then
  echo "== hook consent"
  for f in "$H"/hooks/*.py; do
    out=$(python3 - "$allow" "$f" <<'PY'
import json, pathlib, sys
from datetime import datetime, timezone

allow, script = sys.argv[1], pathlib.Path(sys.argv[2])
fresh = datetime.fromtimestamp(script.stat().st_mtime, tz=timezone.utc).isoformat().replace("+00:00", "Z")
for e in (json.load(open(allow)).get("approvals") or []):
    if isinstance(e, dict) and pathlib.Path(str(e.get("command", "")).split()[-1]).name == script.name:
        print("fresh" if e.get("script_mtime_at_approval") == fresh else "stale")
        break
else:
    print("missing")
PY
)
    check "$(basename "$f") is approved against the file that is installed" "$out" '^fresh$'
  done
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
