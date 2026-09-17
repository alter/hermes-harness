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
  "$(hook guard-paths.py "$(p terminal '{"command":"sed -i s/todo/done/ tasks/10-x/01-y/labels.txt"}')")" 'would write inside'
check "a redirect into the tree is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"echo done > tasks/10-x/01-y/labels.txt"}')")" 'would write inside'
check "python -c writing into the tree is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"python3 -c open(\"tasks/10-x/01-y/labels.txt\",\"w\")"}')")" 'writes somewhere under'
check "reading the tree through the shell is blocked" \
  "$(hook guard-paths.py "$(p terminal '{"command":"cat tasks/10-x/01-y/labels.txt"}')")" 'reaches into'
empty "an unrelated command is allowed" "$(hook guard-paths.py "$(p terminal '{"command":"pytest -q"}')")"
empty "git add of NOTES.md is allowed" \
  "$(hook guard-paths.py "$(p terminal '{"command":"git add tasks/10-x/01-y/NOTES.md"}')")"
check "malformed input fails closed" "$(hook guard-paths.py 'not json')" 'refusing rather than guessing'
[ "$(rc guard-paths.py "$(p write_file '{"path":"tasks/10-x/01-y/labels.txt","content":"x"}')")" = "2" ] \
  && ok "a block exits 2" || bad "a block exits 2" "wrong exit code"

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
check "the prompt states the tree is read-only"         "$(tp prompt "$T/10-a/01-first")" 'read-only to you except NOTES.md'
check "the prompt forbids claiming completion"          "$(tp prompt "$T/10-a/01-first")" 'never touch status: or verify:'
tp set "$T/10-a/01-first" status done >/dev/null
check "status can be written"                           "$(cat "$T/10-a/01-first/labels.txt")" 'status: done'
check "a met dependency releases the next task"         "$(tp next)" '10-a/02-second$'
check "verify: is refused"                              "$(tp set "$T/10-a/01-first" verify passed)" 'not ours to write'
check "verify: is still pending"                        "$(cat "$T/10-a/01-first/labels.txt")" 'verify: pending'
tp set "$T/10-a/02-second" status done >/dev/null
[ -z "$(tp next)" ] && ok "next says nothing when the tree is closed" || bad "next says nothing when the tree is closed" "$(tp next)"

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

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
