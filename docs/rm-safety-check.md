# How Claude Code's rm safety check behaves

The official description is in the Claude Code docs, under
[Critical paths](https://code.claude.com/docs/en/permission-modes#critical-paths). This page
summarizes it and adds what we observed with Claude Code 2.1.295.

## What it checks

Before Claude Code runs a Bash command, it finds every `rm` and `rmdir` in it, including ones
inside subshells, `$(...)` and `bash -c` scripts, and works out what each would delete. It
asks before removing a *critical path*: the filesystem root and its top-level directories,
your home directory, Windows drive roots, and your working directory and its parents. It also
treats a target as critical when it can't tell where it points:

| Example | Why it's flagged |
|---|---|
| `cd out && rm -f *` | It can't tell which directory the glob expands in after a `cd` |
| `rm -rf "$DIR"/*` | If `DIR` is empty, this removes everything under `/` |
| `rm -rf "$(pwd)"` | It can't check command output before the command runs |
| `D=$(pwd); rm -rf "$D"` | The variable can name your working directory |
| `rm -rf logs/*/*` | It can't tell which directories the glob reaches |
| `rm -f /path/to/project/*` when that's the working directory | It's the working directory |
| `bash -c "rm -rf \"$1\"/*"` | The outer shell expands `$1` to nothing first |

Every variant says the removal "requires explicit approval and cannot be auto-allowed by
permission rules". The path in the prompt can look wrong: the check resolves a relative
target against the session's working directory, ignoring any `cd` earlier in the command,
and asks because it knows that guess may be wrong.

Commands like these pass without a prompt:

- `rm -f /work/out/*`: a literal absolute path, with the glob only in the last part.
- `rm -rf /work/tmp && mkdir -p /work/tmp`
- `rm -rf "${OUT:?}"/*`: the `:?` makes the shell stop when `OUT` is empty.
- `rm -rf /work/run_1 /work/run_2`, after listing the directories in a separate command.

## What happens in each permission mode

From the docs:

| Mode | What Claude Code does |
|---|---|
| `default`, `acceptEdits` | Asks you |
| `plan` | Asks you |
| `auto` | Asks you in the terminal, with a two-minute limit. Elsewhere (desktop app, VS Code chat, `-p`, Agent SDK) denies it immediately |
| `dontAsk` | Denies it |
| `bypassPermissions` | Asks you, with a two-minute limit in the terminal |

When the two-minute limit runs out, Claude Code denies the command and tells Claude what to
do instead. After three unanswered prompts in a session, it denies these removals without
asking until you send a new message. `CLAUDE_CODE_DISABLE_DANGEROUS_RM_TIMEOUT=1` turns the
limit off: in bypass mode the prompt then waits indefinitely, and in auto mode these removals
go to the classifier instead.

## What doesn't skip the prompt

- **`--dangerously-skip-permissions`** (bypass mode): still asks.
- **Allow rules** in `permissions.allow`: never approve it.
- **Auto mode**: its classifier doesn't review it.
- **A PreToolUse hook that returns `allow`**: doesn't approve it either.
- **Environment variables**: `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1` turns off only the
  command-substitution case, and `CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1` only critical
  paths typed directly into a `-c` script.

## What does: PermissionRequest hooks

The docs say: "In modes that ask, a
[`PermissionRequest` hook](https://code.claude.com/docs/en/hooks#permissionrequest) can answer
the prompt." The hook runs when the prompt is about to appear, and its input looks like this:

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

The hook can answer `allow` or `deny`. A deny can carry a message, which Claude receives as the
tool error, so it can fix the command and retry. In 2.1.295 both answers work for the rm
prompt, including prompts raised by subagents and sessions driven through the Agent SDK's
permission channel; `tests/live-test.py` checks this against your installed version.

## PowerShell on Windows

When the PowerShell tool is enabled, `Remove-Item` and the `cmd` built-ins `rd`, `rmdir`,
`del` and `erase` get their own checks
([Remove-Item in PowerShell](https://code.claude.com/docs/en/permission-modes#remove-item-in-powershell)):

- System paths and wildcard targets (`*`, `dir\*`) are denied in every mode, without a prompt.
- `Remove-Item -Recurse` on the working directory or a parent asks in modes that ask; bypass
  mode skips this check.

So in a bypass session these never produce a prompt, and the hook has nothing to answer. The
`rm` check above still applies to the Bash tool, which runs through Git Bash on Windows.
