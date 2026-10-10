#!/usr/bin/env bash
# permission-hook.sh: a Claude Code PermissionRequest hook that answers permission prompts
# automatically, so sessions nobody is watching don't stall on a prompt.
#
# Modes:
#   deny-rm    (default) In --dangerously-skip-permissions sessions, deny prompts for Bash
#              commands that run rm or rmdir, and tell Claude how to rewrite the command.
#   deny-all   In --dangerously-skip-permissions sessions, deny every prompt.
#   allow-all  Approve every prompt, in every permission mode.
#   off        Do nothing; every prompt reaches you.
#
# The mode comes from the first of:
#   1. the CLAUDE_PERMISSION_HOOK_MODE environment variable (unknown values are ignored)
#   2. the mode file, <config dir>/hooks/permission-hook.mode
#   3. deny-rm
#
# Run the script yourself to manage the mode:
#   permission-hook.sh [status | deny-rm | deny-all | allow-all | off | reset]
#
# When it answers a prompt it prints the decision as JSON and logs it. In every other case,
# including errors, it prints nothing and Claude Code shows the prompt as usual.

config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
mode_file=$config_dir/hooks/permission-hook.mode
log_file=$config_dir/hooks/permission-hook.log
default_mode=deny-rm

# shellcheck disable=SC2016 # the $(...) and ${...} are text for Claude, not expansions
deny_rm_message='Denied automatically by permission-hook (deny-rm): Claude Code could not verify what this rm deletes, and nobody is watching this session to approve it. Rewrite the command so every rm target is a literal absolute path: no cd before the rm, no $(...) or backticks, no unguarded $VAR (use \"${VAR:?}\"), no rm inside bash -c, and do not glob-clear the working directory itself. Then run the rewritten command.'
deny_all_message='Denied automatically by permission-hook (deny-all): nobody is watching this session to approve permission prompts. Do this another way that does not need approval. If there is none, stop and report which action needs approval and why.'

is_mode() {
  case $1 in
    deny-rm | deny-all | allow-all | off) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints "<mode> <source>", where source is env, file or default.
resolve_mode() {
  local mode=${CLAUDE_PERMISSION_HOOK_MODE:-}
  if is_mode "$mode"; then
    echo "$mode env"
    return
  fi
  mode=$(head -n 1 "$mode_file" 2>/dev/null | tr -d '[:space:]')
  if is_mode "$mode"; then
    echo "$mode file"
    return
  fi
  echo "$default_mode default"
}

usage() {
  cat <<'EOF'
usage: permission-hook.sh [status | deny-rm | deny-all | allow-all | off | reset]

  status     show the current mode and recent decisions (the default)
  deny-rm    in --dangerously-skip-permissions sessions, deny rm prompts and tell Claude
             how to rewrite the command (the default mode)
  deny-all   in --dangerously-skip-permissions sessions, deny every prompt
  allow-all  approve every prompt, in every permission mode
  off        answer nothing; every prompt reaches you
  reset      delete the mode file, going back to deny-rm

The mode applies to every session and takes effect on the next prompt. To set it for one
session, start Claude with CLAUDE_PERMISSION_HOOK_MODE=<mode> instead.
EOF
}

cli() {
  case ${1:-status} in
    status) ;;
    reset) rm -f "$mode_file" ;;
    -h | --help | help)
      usage
      return 0
      ;;
    *)
      if ! is_mode "$1"; then
        usage >&2
        return 2
      fi
      mkdir -p "$(dirname "$mode_file")" && echo "$1" >"$mode_file" || return 1
      ;;
  esac
  local mode source
  read -r mode source <<<"$(resolve_mode)"
  echo "mode: $mode ($source)"
  echo "mode file: $mode_file"
  echo "log: $log_file"
  if [ -s "$log_file" ]; then
    echo "recent decisions:"
    tail -n 5 "$log_file" | sed 's/^/  /'
  fi
}

# Claude Code runs the hook with JSON on stdin and no arguments.
if [ $# -gt 0 ] || [ -t 0 ]; then
  cli "$@"
  exit
fi

input=$(cat)

# field <jq path> <key>: read a string field from the hook input. Uses jq when it is
# installed; otherwise a sed match on the compact JSON that Claude Code sends. jq on Windows
# can end lines with CRLF, so carriage returns are dropped.
field() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // empty" <<<"$input" 2>/dev/null | tr -d '\r'
  else
    sed -nE 's/.*"'"$2"'": *"(([^"\\]|\\.)*)".*/\1/p' <<<"$input" | head -n 1
  fi
}

tool=$(field .tool_name tool_name)
permission_mode=$(field .permission_mode permission_mode)
command=$(field .tool_input.command command)
read -r mode _ <<<"$(resolve_mode)"

log() {
  [ "${CLAUDE_PERMISSION_HOOK_LOG:-1}" = 0 ] && return 0
  mkdir -p "$(dirname "$log_file")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$mode" \
    "${permission_mode:-?}" "${tool:-?}" "$(printf '%s' "$command" | tr '\n\t' '  ' | cut -c 1-300)" \
    >>"$log_file" 2>/dev/null
  return 0
}

allow() {
  log allow
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
}

# deny <message>: the message must already be escaped for a JSON string.
deny() {
  log deny
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}\n' "$1"
}

# Without jq the command is still JSON-escaped, so a newline or tab before rm arrives as \n or \t.
runs_rm() {
  grep -Eq '(^|[^[:alnum:]_.-]|\\[nrt])rm(dir)?([^[:alnum:]_.-]|$)' <<<"$1"
}

case $mode in
  allow-all)
    allow
    ;;
  deny-all)
    if [ "$permission_mode" = bypassPermissions ]; then deny "$deny_all_message"; fi
    ;;
  deny-rm)
    if [ "$permission_mode" = bypassPermissions ] && [ "$tool" = Bash ] && runs_rm "$command"; then
      deny "$deny_rm_message"
    fi
    ;;
esac
exit 0
