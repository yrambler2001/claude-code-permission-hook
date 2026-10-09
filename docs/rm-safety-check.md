# How Claude Code's rm safety check behaves

These notes describe what Claude Code 2.1.295 does. The check is internal and undocumented,
so details can change in any release.

## What it checks

Before Claude Code runs a Bash command, it finds every `rm` and `rmdir` in it, including ones
inside `$(...)` and `bash -c` scripts, and works out what each one would delete. When it can't
tell, or the target is dangerous, it shows a prompt like this:

```
Bash command
  cd /work/out && mkdir -p tmp && cd tmp && rm -f *
  Dangerous rm operation on statically-unresolvable target: /work/project/*

Do you want to proceed?
❯ 1. Yes
  2. No
```

The path in the prompt can look wrong. The check resolves a relative target against the
session's working directory, ignoring any `cd` earlier in the command, and asks because it
knows that guess may be wrong.

Every variant says the removal "requires explicit approval and cannot be auto-allowed by
permission rules". These are the cases it asks about:

| Prompt says | Example that triggers it |
|---|---|
| the command changes directories before the removal, so the relative glob target cannot be statically resolved | `cd out && rm -f *` |
| the removal target cannot be statically resolved to a directory | `rm -rf ../*`, `rm -rf ~/cache/*`, `rm -rf */`, `rmdir -p a/*` |
| the glob pattern traverses directories that cannot be statically enumerated | `rm -rf /work/build_*/obj/*` |
| the target is the output of a command substitution | `rm -rf $(ls -d /work/run_*)` |
| the target is built from a variable that may be empty | `rm -rf "$DIR"/*` |
| a `sh -c` script runs rm on a value known only when it runs | `bash -c 'rm -rf "$1"/*' _ "$DIR"` |
| the command would remove a critical system directory | `rm -rf /usr` |
| the command would remove a workspace directory (the working directory, an additional working directory, or one of their parents) | `rm -f /path/to/project/*` when `/path/to/project` is the session's working directory |
| too many command substitutions to analyze | more than 64 `$(...)` in a command that runs rm |

Commands like these pass without a prompt:

- `rm -f /work/out/*`: a literal absolute path, with the glob only in the last part.
- `rm -rf /work/tmp && mkdir -p /work/tmp`
- `rm -rf "${OUT:?}"/*`: the `:?` makes the shell stop when `OUT` is empty.
- `rm -rf /work/run_1 /work/run_2`, after listing the directories in a separate command.

## What doesn't skip the prompt

- **`--dangerously-skip-permissions`** (bypass mode): still asks.
- **Allow rules** in `permissions.allow`: can't approve it, as the prompt itself says.
- **Auto mode**: its classifier isn't allowed to approve it.
- **A PreToolUse hook that returns `allow`**: Claude Code runs the full permission check
  anyway and still asks. Its debug log says `Hook returned 'allow' for Bash, but ask
  rule/safety check requires full permission pipeline`.
- **Environment variables**: `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT` turns off only the
  command-substitution case (`rm -r $(...)`). It's undocumented.

## What does: PermissionRequest hooks

A [PermissionRequest hook](https://code.claude.com/docs/en/hooks) runs when a permission prompt
is about to appear, and it runs for this prompt too. Its input looks like this:

```json
{
  "session_id": "2bf81776-…",
  "cwd": "/work",
  "permission_mode": "bypassPermissions",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": { "command": "cd sub && rm -f *", "description": "…" },
  "permission_suggestions": []
}
```

The input doesn't say why the prompt appeared. In a bypass session, though, nearly every
prompt that still appears comes from a safety check like this one.

The hook can answer `allow` or `deny`. A deny can carry a message, which Claude receives as
the tool error, so it can fix the command and retry. In 2.1.295 both answers work for the rm
prompt, including prompts raised by subagents; `tests/live-test.py` checks this against your
installed version.

Claude Code skips PermissionRequest hooks for some prompts that it reserves for a person. The
rm check isn't one of them in 2.1.295, but a later release could change that. If it does,
the hook stops answering and you get the prompt again; nothing is approved by mistake.
