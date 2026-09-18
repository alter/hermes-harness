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
check "verify: is refused"                              "$(tp set "$T/10-a/01-first" verify passed)" 'not ours to write'
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
