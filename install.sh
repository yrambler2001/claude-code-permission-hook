#!/usr/bin/env bash
# Install permission-hook for the current user: put the hook script in <config dir>/hooks and
# register it as a PermissionRequest hook in <config dir>/settings.json. Safe to run again,
# for example after pulling a new version.
#
# usage: ./install.sh [--link]
#   --link  symlink the hook to this checkout instead of copying it, so edits apply at once
#
# The config dir is $CLAUDE_CONFIG_DIR, or ~/.claude when that is not set.
set -euo pipefail

usage() { sed -n 's/^# \{0,1\}//; 6,7p' "$0"; }

link=0
case ${1:-} in
  "") ;;
  --link) link=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
target=$config_dir/hooks/permission-hook.sh

if ! command -v python3 >/dev/null 2>&1; then
  echo "install.sh needs python3 to edit settings.json" >&2
  exit 1
fi

mkdir -p "$config_dir/hooks"
rm -f "$target"
if [ "$link" = 1 ]; then
  ln -s "$repo_dir/hooks/permission-hook.sh" "$target"
else
  cp "$repo_dir/hooks/permission-hook.sh" "$target"
  chmod 755 "$target"
fi
echo "hook: $target$([ "$link" = 1 ] && echo " -> $repo_dir/hooks/permission-hook.sh")"

# Keep the portable ~ form for the default config dir, so a synced settings.json works anywhere.
if [ "$config_dir" = "$HOME/.claude" ]; then
  # shellcheck disable=SC2088 # the tilde is expanded by the shell Claude Code runs hooks in
  hook_command='~/.claude/hooks/permission-hook.sh'
else
  hook_command=$(printf '%q' "$target")
fi
python3 "$repo_dir/lib/edit_settings.py" add "$config_dir/settings.json" "$hook_command"

echo
"$target" status
echo
echo "Installed. Sessions started from now on use the hook; restart any session already open."
