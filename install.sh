#!/usr/bin/env bash
# install.sh
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
PROFILE=${1:-}
TARGET=$HERMES_HOME${PROFILE:+/profiles/$PROFILE}
HARNESS=$TARGET/harness
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=${HH_BACKUP_DIR:-$HOME/.hermes-harness-backup/$STAMP}

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "pyyaml is required: pip install pyyaml" >&2; exit 1; }
command -v hermes >/dev/null 2>&1 || echo "warning: hermes is not on PATH; installing anyway" >&2

echo "== backup -> $BACKUP"
mkdir -p "$BACKUP"
[ -f "$TARGET/config.yaml" ] && cp "$TARGET/config.yaml" "$BACKUP/config.yaml"
[ -d "$HARNESS" ] && cp -R "$HARNESS" "$BACKUP/harness"
printf 'source=%s\ntarget=%s\ndate=%s\n' "$SRC" "$TARGET" "$STAMP" > "$BACKUP/INFO.txt"

echo "== install -> $HARNESS"
mkdir -p "$HARNESS/hooks"

# Replace by rename, never in place: bash reads a script as it runs it, so
# overwriting run.sh under a live loop makes it misread its own body.
put() {
  local src=$1 dst=$2 tmp="$2.incoming.$$"
  cp "$src" "$tmp"
  [ -x "$src" ] && chmod +x "$tmp"
  mv -f "$tmp" "$dst"
}
put "$SRC/tasks.py" "$HARNESS/tasks.py"
put "$SRC/run.sh" "$HARNESS/run.sh"
for h in "$SRC"/hooks/*.py; do put "$h" "$HARNESS/hooks/$(basename "$h")"; done
chmod +x "$HARNESS/run.sh"
for f in "$HARNESS/tasks.py" "$HARNESS"/hooks/*.py; do
  python3 -c "import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())" "$f"
done
bash -n "$HARNESS/run.sh"

echo "== config.yaml: merge"
python3 - "$SRC/config.yaml" "$TARGET/config.yaml" "$TARGET" <<'PY'
import pathlib, sys, yaml

ours_path, theirs_path, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
ours = yaml.safe_load(ours_path.read_text(encoding="utf-8")) or {}
theirs = yaml.safe_load(theirs_path.read_text(encoding="utf-8")) if theirs_path.exists() else {}
theirs = theirs if isinstance(theirs, dict) else {}


def hook_entries(block):
    return [e for e in (block or []) if isinstance(e, dict)]


def merge(base, over, path=""):
    out = dict(base)
    for key, value in over.items():
        here = f"{path}.{key}" if path else key
        if key == "hooks":
            existing = out.get("hooks") if isinstance(out.get("hooks"), dict) else {}
            merged = dict(existing)
            for event, entries in (value or {}).items():
                mine = hook_entries(entries)
                names = {pathlib.Path(str(e.get("command", "")).split()[-1]).name for e in mine}
                kept = [e for e in hook_entries(merged.get(event))
                        if pathlib.Path(str(e.get("command", "")).split()[-1]).name not in names]
                merged[event] = kept + mine
                print(f"   hooks.{event}: {len(kept)} kept, {len(mine)} ours")
            out["hooks"] = merged
        elif isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value, here)
        else:
            if key in out and out[key] != value:
                print(f"   {here}: {out[key]!r} -> {value!r}")
            elif key not in out:
                print(f"   {here}: {value!r}")
            out[key] = value
    return out


model = theirs.get("model")
if isinstance(model, dict) and model.get("default") and "REPLACE" not in str(model.get("default")):
    ours["model"] = {**ours.get("model", {}), **{k: v for k, v in model.items() if k in {"default", "base_url", "provider", "api_key"}}}
    print(f"   model.default kept as {model['default']!r}")

for event, entries in (ours.get("hooks") or {}).items():
    for entry in entries:
        entry["command"] = str(entry["command"]).replace("~/.hermes/harness", f"{target}/harness")

merged = merge(theirs, ours)
theirs_path.parent.mkdir(parents=True, exist_ok=True)
theirs_path.write_text(yaml.safe_dump(merged, sort_keys=False, allow_unicode=True), encoding="utf-8")
PY

echo "== check"
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TARGET/config.yaml"
echo "   hooks: $(python3 -c "
import yaml,sys
c=yaml.safe_load(open(sys.argv[1])) or {}
print(sum(len(v or []) for v in (c.get('hooks') or {}).values()))" "$TARGET/config.yaml")"
model=$(python3 -c "
import yaml,sys
c=yaml.safe_load(open(sys.argv[1])) or {}
m=c.get('model')
print((m or {}).get('default') if isinstance(m, dict) else m)" "$TARGET/config.yaml")
echo "   model: $model"

echo "== hook consent"
# Hermes ties an approval to the script's fingerprint, so replacing a hook
# invalidates it. register_from_config(..., accept_hooks=True) is the same
# public call the CLI makes at startup: it re-records the approvals against the
# files just installed. No model call, no running server, no hand-edited JSON.
hermes_python() {
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('agent.shell_hooks') else 1)" 2>/dev/null \
      && { echo "$candidate"; return 0; }
  done
  local launcher head
  launcher=$(command -v hermes 2>/dev/null) || return 1
  head=$(head -c 256 "$launcher" 2>/dev/null | tr -d '\000')
  case "$head" in
    '#!'*) head=$(printf '%s\n' "$head" | head -n 1 | sed 's/^#![[:space:]]*//; s/^.*\/env //') ;;
    *) return 1 ;;
  esac
  case "$head" in *[!a-zA-Z0-9/_.@:-]*) return 1 ;; esac
  [ -x "$head" ] && "$head" -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('agent.shell_hooks') else 1)" 2>/dev/null \
    && { echo "$head"; return 0; }
  return 1
}

if PY=$(hermes_python); then
  HERMES_HOME="$TARGET" "$PY" - "$HARNESS" <<'PYAPPROVE'
import sys
from hermes_cli.config import load_config
from agent.shell_hooks import (
    allowlist_entry_for, iter_configured_hooks, register_from_config, revoke, script_mtime_iso,
)

harness = sys.argv[1]
mine = [h for h in iter_configured_hooks(load_config()) if harness in h.command]
if not mine:
    print("   no harness hooks in this config; nothing to approve")
    sys.exit(0)

# An approval is matched by (event, command) alone, so an entry whose recorded
# fingerprint is stale still counts as present and would never be refreshed.
# Drop ours first, exactly as `hermes hooks revoke` does, then re-record.
for h in mine:
    revoke(h.command)
register_from_config(load_config(), accept_hooks=True)

failed = 0
for h in mine:
    entry = allowlist_entry_for(h.event, h.command)
    fresh = entry is not None and entry.get("script_mtime_at_approval") == script_mtime_iso(h.command)
    failed += 0 if fresh else 1
    print(f"   {'approved' if fresh else 'NOT approved'}: {h.event} -> {h.command.split('/')[-1]}")
sys.exit(1 if failed else 0)
PYAPPROVE
  rc=$?
  [ "$rc" -eq 0 ] && echo "   verify with: hermes hooks doctor" \
                  || echo "   some hooks were not approved; run \`hermes hooks doctor\`" >&2
else
  echo "   could not import agent.shell_hooks from any python on PATH." >&2
  echo "   Approve by hand, or the hooks will not fire:" >&2
  for h in "$HARNESS"/hooks/*.py; do echo "     hermes hooks revoke \"python3 $h\"" >&2; done
  echo "     echo ok | hermes chat -Q --query-file - --accept-hooks" >&2
  echo "     hermes hooks doctor" >&2
fi

cat <<EOF

Done.
  backup:   $BACKUP
  rollback: $SRC/uninstall.sh $BACKUP ${PROFILE:-}
  selftest: $SRC/selftest.sh $TARGET
EOF

case "$model" in
  *REPLACE*) cat <<'EOF'

Next, and nothing works until you do it:
  curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool   # the id your server reports
  hermes config set model.default '<that id>'
  hermes config set model.base_url 'http://127.0.0.1:8080/v1'
Your server must emit native tool_calls (llama.cpp --jinja, vLLM --enable-auto-tool-choice
--tool-call-parser hermes). Hermes has no text fallback: a <tool_call> block in the reply text
is stripped and discarded, and the agent will look busy while doing nothing.
EOF
;;
esac
