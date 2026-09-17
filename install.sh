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
cp "$SRC/tasks.py" "$HARNESS/tasks.py"
cp "$SRC/run.sh" "$HARNESS/run.sh"
cp "$SRC"/hooks/*.py "$HARNESS/hooks/"
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

if [ -f "$TARGET/shell-hooks-allowlist.json" ] && grep -q "$HARNESS/hooks" "$TARGET/shell-hooks-allowlist.json" 2>/dev/null; then
  echo "== hook consent"
  echo "   the hook scripts were just replaced, so their approved fingerprints are stale."
  echo "   \`hermes hooks doctor\` will warn until you refresh them:"
  for h in "$HARNESS"/hooks/*.py; do echo "     hermes hooks revoke \"python3 $h\""; done
  echo "     echo ok | hermes chat -Q --query-file - --accept-hooks"
  echo "     hermes hooks doctor"
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
