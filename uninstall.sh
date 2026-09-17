#!/usr/bin/env bash
# uninstall.sh
set -euo pipefail

BACKUP=${1:?usage: uninstall.sh ~/.hermes-harness-backup/<stamp> [profile]}
BACKUP=${BACKUP/#\~/$HOME}
[ -d "$BACKUP" ] || { echo "no such backup: $BACKUP" >&2; exit 1; }

TARGET=$(sed -n 's/^target=//p' "$BACKUP/INFO.txt" 2>/dev/null | head -n 1)
if [ -z "$TARGET" ]; then
  HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
  PROFILE=${2:-}
  TARGET=$HERMES_HOME${PROFILE:+/profiles/$PROFILE}
  echo "   $BACKUP/INFO.txt names no target; falling back to $TARGET" >&2
fi
[ -d "$TARGET" ] || { echo "the target that backup names does not exist: $TARGET" >&2; exit 1; }
HARNESS=$TARGET/harness
echo "== target $TARGET"

echo "== remove $HARNESS"
rm -rf "$HARNESS"

echo "== restore from $BACKUP"
if [ -f "$BACKUP/config.yaml" ]; then
  cp "$BACKUP/config.yaml" "$TARGET/config.yaml"
  echo "   config.yaml restored"
else
  echo "   there was no config.yaml before; leaving the current one in place" >&2
  echo "   remove the harness keys by hand, or delete $TARGET/config.yaml" >&2
fi
[ -d "$BACKUP/harness" ] && cp -R "$BACKUP/harness" "$HARNESS" && echo "   previous harness restored"

python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$TARGET/config.yaml" 2>/dev/null \
  && echo "   config.yaml is valid YAML" || echo "   warning: $TARGET/config.yaml does not parse" >&2

echo "Done."
