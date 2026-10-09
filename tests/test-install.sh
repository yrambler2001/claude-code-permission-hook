#!/usr/bin/env bash
# Tests for install.sh and uninstall.sh, run against a throwaway CLAUDE_CONFIG_DIR.
#
# Needs jq and python3. Usage: tests/test-install.sh
set -uo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export CLAUDE_CONFIG_DIR=$tmp/config
settings=$CLAUDE_CONFIG_DIR/settings.json
hook=$CLAUDE_CONFIG_DIR/hooks/permission-hook.sh

passed=0
failed=0
# check <description> <command...>: passes when the command succeeds.
check() {
  local description=$1
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $description"
  fi
}

ours() { jq '[.hooks.PermissionRequest[]?.hooks[]? | select(.command | contains("permission-hook.sh"))] | length' "$settings"; }
backups() { find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name 'settings.json.bak-*' | wc -l | tr -d ' '; }

mkdir -p "$CLAUDE_CONFIG_DIR"
cat >"$settings" <<'EOF'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(npm run *)"] },
  "hooks": {
    "PermissionRequest": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "other-hook.sh" }] }
    ],
    "Stop": [{ "hooks": [{ "type": "command", "command": "notify.sh" }] }]
  }
}
EOF

# Install into existing settings, keeping everything else.
"$repo_dir/install.sh" >/dev/null
check "install exits 0" test $? = 0
check "hook copied and executable" test -x "$hook" -a ! -L "$hook"
check "one hook entry" test "$(ours)" = 1
check "entry matches every tool" test "$(jq -r '.hooks.PermissionRequest[-1].matcher' "$settings")" = '*'
check "entry runs the installed hook" test "$(jq -r '.hooks.PermissionRequest[-1].hooks[0].command' "$settings")" = "$(printf '%q' "$hook")"
check "other PermissionRequest hook kept" test "$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$settings")" = other-hook.sh
check "other hook events kept" test "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")" = notify.sh
check "other settings kept" test "$(jq -r '.model + " " + .permissions.allow[0]' "$settings")" = "opus Bash(npm run *)"
check "settings backed up" test "$(backups)" = 1

# Running it again changes nothing.
"$repo_dir/install.sh" >/dev/null
check "second install keeps one entry" test "$(ours)" = 1
check "second install makes no backup" test "$(backups)" = 1

# --link symlinks the hook to the checkout.
"$repo_dir/install.sh" --link >/dev/null
check "--link symlinks the hook" test "$(readlink "$hook")" = "$repo_dir/hooks/permission-hook.sh"
check "--link keeps one entry" test "$(ours)" = 1
"$repo_dir/install.sh" --bogus >/dev/null 2>&1
check "unknown option exits 2" test $? = 2

# Uninstall takes out only our entry and files.
"$hook" allow-all >/dev/null
"$repo_dir/uninstall.sh" >/dev/null
check "uninstall exits 0" test $? = 0
check "hook removed" test ! -e "$hook" -a ! -L "$hook"
check "mode file removed" test ! -e "$CLAUDE_CONFIG_DIR/hooks/permission-hook.mode"
check "no entries left" test "$(ours)" = 0
check "other PermissionRequest hook kept on uninstall" test "$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$settings")" = other-hook.sh
check "other settings kept on uninstall" test "$(jq -r .model "$settings")" = opus
"$repo_dir/uninstall.sh" >/dev/null
check "second uninstall is harmless" test $? = 0

# With no settings file, install creates one, and uninstall leaves no empty hooks object.
rm -f "$settings" "$CLAUDE_CONFIG_DIR"/settings.json.bak-*
"$repo_dir/install.sh" >/dev/null
check "install creates settings.json" test "$(ours)" = 1
"$repo_dir/uninstall.sh" >/dev/null
check "uninstall drops the empty hooks object" test "$(jq -c . "$settings")" = '{}'

# Invalid JSON is left alone.
printf '{ "model": "opus", }' >"$settings"
"$repo_dir/install.sh" >/dev/null 2>&1
check "install fails on invalid settings" test $? != 0
check "invalid settings untouched" test "$(cat "$settings")" = '{ "model": "opus", }'

# A symlinked settings.json is updated through the link.
printf '{"model": "opus"}\n' >"$tmp/real-settings.json"
ln -sf "$tmp/real-settings.json" "$settings"
"$repo_dir/install.sh" >/dev/null
check "symlinked settings.json stays a symlink" test -L "$settings"
check "symlink target updated" test "$(jq '.hooks.PermissionRequest | length' "$tmp/real-settings.json")" = 1

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
