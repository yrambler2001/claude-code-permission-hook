#!/usr/bin/env bash
# Remove permission-hook: take its entry out of <config dir>/settings.json and delete the hook
# script and mode file. The decision log is kept.
#
# usage: ./uninstall.sh
#
# The config dir is $CLAUDE_CONFIG_DIR, or ~/.claude when that is not set.
set -euo pipefail

case ${1:-} in
  "") ;;
  -h | --help)
    echo "usage: ./uninstall.sh"
    exit 0
    ;;
  *)
    echo "usage: ./uninstall.sh" >&2
    exit 2
    ;;
esac

case $(uname -s) in
  MINGW* | MSYS* | CYGWIN*)
    echo "On Windows, use uninstall.ps1: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1" >&2
    exit 1
    ;;
esac

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
hooks_dir=$config_dir/hooks

if ! command -v python3 >/dev/null 2>&1; then
  echo "uninstall.sh needs python3 to edit settings.json" >&2
  exit 1
fi

python3 "$repo_dir/lib/edit_settings.py" remove "$config_dir/settings.json"
rm -f "$hooks_dir/permission-hook.sh" "$hooks_dir/permission-hook.mode"
echo "removed: $hooks_dir/permission-hook.sh and its mode file"
if [ -e "$hooks_dir/permission-hook.log" ]; then
  echo "kept: $hooks_dir/permission-hook.log (delete it yourself if you don't need it)"
fi
echo "Restart any open Claude Code session to stop it using the hook."
