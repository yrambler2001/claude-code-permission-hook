#!/usr/bin/env bash
# Unit tests for hooks/permission-hook.sh: feed it PermissionRequest inputs like the ones Claude
# Code sends and check what it answers. Every case runs twice: with jq on PATH, and with a PATH
# that has no jq and only /bin/bash (bash 3.2 on macOS), to cover the sed fallback.
#
# Needs jq to build the inputs. Usage: tests/test-hook.sh

# shellcheck disable=SC2016 # sample commands are single-quoted on purpose
set -uo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook=$repo_dir/hooks/permission-hook.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export CLAUDE_CONFIG_DIR=$tmp/config
unset CLAUDE_PERMISSION_HOOK_MODE CLAUDE_PERMISSION_HOOK_LOG
mode_file=$CLAUDE_CONFIG_DIR/hooks/permission-hook.mode
log_file=$CLAUDE_CONFIG_DIR/hooks/permission-hook.log

no_jq_path=$tmp/bin
mkdir -p "$no_jq_path"
ln -s /bin/bash "$no_jq_path/bash"
for tool in cat cut date dirname grep head mkdir rm sed tail tr; do
  ln -s "$(command -v "$tool")" "$no_jq_path/$tool"
done

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  echo "FAIL: $*"
}

# run_hook <PATH> <permission mode> <tool> <command> [VAR=value ...]
run_hook() {
  local path=$1 permission_mode=$2 tool=$3 command=$4
  shift 4
  jq -cn --arg pm "$permission_mode" --arg tool "$tool" --arg cmd "$command" '{
      session_id: "test", cwd: "/work", permission_mode: $pm,
      hook_event_name: "PermissionRequest", tool_name: $tool,
      tool_input: (if $tool == "Bash" then {command: $cmd, description: "test"}
                   else {file_path: "/work/a.txt", content: "x"} end),
      permission_suggestions: []}' |
    env PATH="$path" "$@" "$hook"
}

# decision <hook output>: allow, deny, none (no output) or invalid
decision() {
  if [ -z "$1" ]; then
    echo none
  else
    jq -er '.hookSpecificOutput | select(.hookEventName == "PermissionRequest") | .decision.behavior' <<<"$1" 2>/dev/null || echo invalid
  fi
}

# expect <decision> <permission mode> <tool> <command> [VAR=value ...]
expect() {
  local want=$1 variant path out got
  shift
  for variant in jq no-jq; do
    path=$PATH
    [ "$variant" = no-jq ] && path=$no_jq_path
    out=$(run_hook "$path" "$@")
    got=$(decision "$out")
    if [ "$got" = "$want" ]; then pass; else fail "[$variant] mode=$(cat "$mode_file" 2>/dev/null || echo unset) ${*:4} | $1 $2 '$3': want $want, got $got"; fi
  done
}

B=bypassPermissions

# Default mode (deny-rm): only rm prompts in bypass sessions are denied.
rm -f "$mode_file"
expect deny "$B" Bash 'cd sub && rm -f *'
expect deny "$B" Bash 'rm -rf "$OUT"/*'
expect deny "$B" Bash '/bin/rm -r build'
expect deny "$B" Bash 'rmdir -p a/b'
expect deny "$B" Bash 'sudo rm -rf /tmp/x'
expect deny "$B" Bash $'echo start\nrm -f "./a b.txt"'
expect none "$B" Bash 'ls ./rm-tools build.rm'
expect none "$B" Bash 'npm run format'
expect none "$B" Bash 'git commit -m "remove files"'
expect none "$B" Write ''
expect none auto Bash 'cd sub && rm -f *'
expect none default Bash 'cd sub && rm -f *'
expect none plan Bash 'rm x'

# deny-all: every prompt in bypass sessions, nothing elsewhere.
echo deny-all >"$mode_file"
expect deny "$B" Bash 'cd sub && rm -f *'
expect deny "$B" Bash 'ls'
expect deny "$B" Write ''
expect none auto Bash 'rm x'
expect none default Write ''

# allow-all: every prompt in every permission mode.
echo allow-all >"$mode_file"
expect allow "$B" Bash 'cd sub && rm -f *'
expect allow auto Bash 'rm -rf /tmp/x'
expect allow default Write ''
expect allow plan Bash 'ls'

# off: nothing.
echo off >"$mode_file"
expect none "$B" Bash 'cd sub && rm -f *'
expect none default Write ''

# The environment variable overrides the file; unknown values are ignored.
echo off >"$mode_file"
expect allow "$B" Bash 'rm x' CLAUDE_PERMISSION_HOOK_MODE=allow-all
echo allow-all >"$mode_file"
expect none "$B" Bash 'rm x' CLAUDE_PERMISSION_HOOK_MODE=off
expect deny "$B" Bash 'rm x' CLAUDE_PERMISSION_HOOK_MODE=deny-rm
expect allow "$B" Bash 'ls' CLAUDE_PERMISSION_HOOK_MODE=bogus
printf '  deny-all \n' >"$mode_file"
expect deny "$B" Bash 'ls'
echo bogus >"$mode_file"
expect deny "$B" Bash 'rm x'
expect none "$B" Bash 'ls'

# The deny message reaches Claude intact.
rm -f "$mode_file"
out=$(run_hook "$PATH" "$B" Bash 'rm -f *')
message=$(jq -r '.hookSpecificOutput.decision.message' <<<"$out")
case $message in
  *'literal absolute path'*'"${VAR:?}"'*) pass ;;
  *) fail "deny-rm message: $message" ;;
esac

# Decisions are logged as tab-separated lines; CLAUDE_PERMISSION_HOOK_LOG=0 turns that off.
rm -f "$log_file"
run_hook "$PATH" "$B" Bash 'rm -f *' >/dev/null
line=$(tail -n 1 "$log_file" 2>/dev/null)
if [ "$(printf '%s' "$line" | cut -f 2-6)" = "$(printf 'deny\tdeny-rm\t%s\tBash\trm -f *' "$B")" ]; then pass; else fail "log line: $line"; fi
run_hook "$PATH" "$B" Bash 'rm -f *' CLAUDE_PERMISSION_HOOK_LOG=0 >/dev/null
if [ "$(wc -l <"$log_file" | tr -d ' ')" = 1 ]; then pass; else fail "CLAUDE_PERMISSION_HOOK_LOG=0 still logged"; fi
run_hook "$PATH" "$B" Bash 'ls' >/dev/null
if [ "$(wc -l <"$log_file" | tr -d ' ')" = 1 ]; then pass; else fail "a prompt the hook did not answer was logged"; fi

# Command line.
rm -f "$mode_file"
out=$("$hook" status </dev/null)
case $out in *"mode: deny-rm (default)"*) pass ;; *) fail "status: $out" ;; esac
"$hook" allow-all </dev/null >/dev/null
if [ "$(cat "$mode_file" 2>/dev/null)" = allow-all ]; then pass; else fail "setting allow-all"; fi
out=$(CLAUDE_PERMISSION_HOOK_MODE=off "$hook" status </dev/null)
case $out in *"mode: off (env)"*) pass ;; *) fail "status with env: $out" ;; esac
"$hook" reset </dev/null >/dev/null
if [ ! -e "$mode_file" ]; then pass; else fail "reset"; fi
"$hook" bogus </dev/null >/dev/null 2>&1
if [ $? = 2 ] && [ ! -e "$mode_file" ]; then pass; else fail "an unknown mode should exit 2 and change nothing"; fi
if "$hook" --help </dev/null | grep -q 'usage: permission-hook.sh'; then pass; else fail "--help"; fi

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
