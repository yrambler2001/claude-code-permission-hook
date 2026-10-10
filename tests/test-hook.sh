#!/usr/bin/env bash
# Unit tests for hooks/permission-hook.sh. Runs every case in tests/cases.json (shared with
# tests/test-hook.ps1) twice: with jq on PATH, and without jq to cover the sed fallback (on
# macOS that run also uses /bin/bash, which is bash 3.2). Then checks the deny message, the
# log and the command line.
#
# Needs jq to read the cases. Usage: tests/test-hook.sh

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
mkdir -p "$CLAUDE_CONFIG_DIR/hooks"

# A PATH without jq. Drop the directories that hold jq when the other tools live elsewhere
# (Git Bash on Windows); otherwise link the tools the hook needs into a directory of their own.
hook_tools="bash cat cut date dirname grep head mkdir rm sed tail tr"
no_jq_path=
old_ifs=$IFS
IFS=:
for dir in $PATH; do
  if [ ! -x "$dir/jq" ] && [ ! -x "$dir/jq.exe" ]; then no_jq_path=${no_jq_path:+$no_jq_path:}$dir; fi
done
IFS=$old_ifs
missing=
for tool in $hook_tools; do
  PATH=$no_jq_path command -v "$tool" >/dev/null 2>&1 || missing=1
done
if [ -n "$missing" ]; then
  no_jq_path=$tmp/bin
  mkdir -p "$no_jq_path"
  ln -s /bin/bash "$no_jq_path/bash"
  for tool in ${hook_tools#bash }; do
    ln -s "$(command -v "$tool")" "$no_jq_path/$tool"
  done
fi
if PATH=$no_jq_path command -v jq >/dev/null 2>&1; then
  echo "could not build a PATH without jq" >&2
  exit 1
fi

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  echo "FAIL: $*"
}

# hook_input <case>: the PermissionRequest input Claude Code would send for a case.
hook_input() {
  jq -c '{session_id: "test", cwd: "/work", permission_mode: .permission_mode,
    hook_event_name: "PermissionRequest", tool_name: .tool,
    tool_input: (if .command then {command: .command, description: "test"}
                 else {file_path: "/work/a.txt", content: "x"} end),
    permission_suggestions: []}' <<<"$1"
}

# decision <hook output>: allow, deny, none (no output) or invalid
decision() {
  if [ -z "$1" ]; then
    echo none
  else
    jq -er '.hookSpecificOutput | select(.hookEventName == "PermissionRequest") | .decision.behavior' <<<"$1" 2>/dev/null || echo invalid
  fi
}

# run_hook <PATH> <input> [mode for the environment variable]
run_hook() {
  if [ -n "${3:-}" ]; then
    printf '%s' "$2" | env PATH="$1" CLAUDE_PERMISSION_HOOK_MODE="$3" "$hook"
  else
    printf '%s' "$2" | env PATH="$1" "$hook"
  fi
}

while IFS= read -r case; do
  if jq -e 'has("file")' <<<"$case" >/dev/null; then jq -j .file <<<"$case" >"$mode_file"; else rm -f "$mode_file"; fi
  want=$(jq -r .expect <<<"$case")
  env_mode=$(jq -r '.env // empty' <<<"$case")
  input=$(hook_input "$case")
  for variant in jq no-jq; do
    path=$PATH
    [ "$variant" = no-jq ] && path=$no_jq_path
    got=$(decision "$(run_hook "$path" "$input" "$env_mode")")
    if [ "$got" = "$want" ]; then pass; else fail "[$variant] $case: got $got"; fi
  done
done < <(jq -c '.[] | select(has("expect"))' "$repo_dir/tests/cases.json")

B=bypassPermissions
input() { hook_input "$(jq -cn --arg pm "$1" --arg tool "$2" --arg cmd "$3" '{permission_mode: $pm, tool: $tool, command: $cmd}')"; }

# The deny message reaches Claude intact.
rm -f "$mode_file"
message=$(run_hook "$PATH" "$(input "$B" Bash 'rm -f *')" | jq -r '.hookSpecificOutput.decision.message')
case $message in
  *'literal absolute path'*'"${VAR:?}"'*) pass ;;
  *) fail "deny-rm message: $message" ;;
esac

# Decisions are logged as tab-separated lines; CLAUDE_PERMISSION_HOOK_LOG=0 turns that off.
rm -f "$log_file"
run_hook "$PATH" "$(input "$B" Bash 'rm -f *')" >/dev/null
line=$(tail -n 1 "$log_file" 2>/dev/null)
if [ "$(printf '%s' "$line" | cut -f 2-6)" = "$(printf 'deny\tdeny-rm\t%s\tBash\trm -f *' "$B")" ]; then pass; else fail "log line: $line"; fi
input "$B" Bash 'rm -f *' | CLAUDE_PERMISSION_HOOK_LOG=0 "$hook" >/dev/null
if [ "$(wc -l <"$log_file" | tr -d ' ')" = 1 ]; then pass; else fail "CLAUDE_PERMISSION_HOOK_LOG=0 still logged"; fi
run_hook "$PATH" "$(input "$B" Bash 'ls')" >/dev/null
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
