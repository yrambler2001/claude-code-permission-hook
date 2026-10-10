# claude-code-permission-hook

A [Claude Code](https://code.claude.com) hook that answers permission prompts for you, so a
session nobody is watching doesn't get stuck on one. Works on macOS, Linux and Windows, in
the CLI and in the desktop app and IDE extensions.

The main use is the prompt Claude Code shows for an `rm` it can't verify. That prompt appears
even with `--dangerously-skip-permissions`, and no allow rule or PreToolUse hook can approve it
([Critical paths](https://code.claude.com/docs/en/permission-modes#critical-paths) in the docs):

```
Bash command · from the general-purpose agent
  cd /work/out && mkdir -p tmp && cd tmp && rm -f *
  Dangerous rm operation on statically-unresolvable target: /work/project/*

Do you want to proceed?
❯ 1. Yes
  2. No
```

In a bypass session in the terminal, Claude Code waits two minutes for an answer, then denies
the command; after three unanswered prompts it denies these removals straight away. In the default mode, this
hook answers at once: it denies the prompt and tells Claude how to rewrite the command so the
check passes. Claude retries with `rm -f /work/out/tmp/*`, which runs without a prompt, and
the session carries on. If you'd rather approve everything, there's a mode for that too.

## How it works

Claude Code runs [PermissionRequest hooks](https://code.claude.com/docs/en/hooks#permissionrequest)
when it is about to show a permission prompt, and the docs say they can answer the `rm` prompt
too. A hook answers `allow` or `deny`, and a deny can include a message that Claude reads as
the tool error. This repo has one such hook in two versions: `permission-hook.sh` for macOS
and Linux and `permission-hook.ps1` for Windows. Both have the same four modes:

| Mode | What it does | Where it applies |
|---|---|---|
| `deny-rm` (default) | Denies prompts for Bash commands that run `rm`/`rmdir`, telling Claude to use literal absolute paths | `--dangerously-skip-permissions` sessions only |
| `deny-all` | Denies every prompt, telling Claude to find a way that doesn't need approval or stop and report | `--dangerously-skip-permissions` sessions only |
| `allow-all` | Approves every prompt | Every permission mode |
| `off` | Does nothing | — |

The deny modes only act in `--dangerously-skip-permissions` sessions because those are the
unattended ones; in any other mode, prompts reach you as usual. If the hook can't run or has
nothing to say, Claude Code shows the prompt as if the hook weren't there.

Background on what the `rm` check catches and how it behaves in each mode:
[docs/rm-safety-check.md](docs/rm-safety-check.md).

## Where it works

The hook is part of your Claude Code settings, so it works wherever Claude Code runs on a
machine where it's installed:

| Where you use Claude Code | Works | Notes |
|---|---|---|
| CLI, including in JetBrains and other IDE terminals | Yes | |
| Desktop app, local sessions | Yes | The app reads the same `~/.claude/settings.json` as the CLI |
| VS Code extension | Yes | Same settings file. Bypass mode needs `allowDangerouslySkipPermissions` |
| `claude -p` and the Agent SDK | Yes | |
| Remote Control | Yes | The session still runs on your machine |
| Desktop app SSH and WSL sessions | Yes, if installed there | Claude Code runs on the remote host or inside WSL, so install the hook there |
| Cloud sessions (claude.ai/code, cloud sessions from the app, routines) | No | They run on Anthropic's machines, don't read your `~/.claude`, and don't offer bypass mode |

In `auto` mode, the desktop app, the VS Code chat panel and `claude -p` don't ask about these
removals at all; they deny them right away and tell Claude to leave them to you. With no
prompt, there's nothing for the hook to answer. In bypass mode the hook gets to answer
everywhere in this table that says Yes.

Tested: CLI sessions, `claude -p`, and a session driven through the Agent SDK's permission
channel, which is how the desktop app and VS Code show approval cards. The desktop app itself
wasn't driven by hand.

## Requirements

- Claude Code with PermissionRequest hooks. Tested with 2.1.295.
- **macOS and Linux:** `bash` 3.2 or newer, `sed` and `grep`. The hook uses `jq` when it's
  installed and falls back to `sed` when it isn't. The installer needs `python3`.
- **Windows:** Windows PowerShell 5.1, which comes with Windows 10 and 11, or PowerShell 7.
  Git Bash isn't needed.

## Install

### macOS and Linux

```bash
git clone https://github.com/yrambler2001/claude-code-permission-hook.git
cd claude-code-permission-hook
./install.sh
```

`install.sh`:

- copies the hook to `~/.claude/hooks/permission-hook.sh`
  (`./install.sh --link` symlinks it to the checkout instead)
- adds it to `~/.claude/settings.json` as a PermissionRequest hook for all tools, after
  backing the file up to `settings.json.bak-<timestamp>`; other settings and hooks are kept
- uses `$CLAUDE_CONFIG_DIR` instead of `~/.claude` when that's set

### Windows

In PowerShell:

```powershell
git clone https://github.com/yrambler2001/claude-code-permission-hook.git
cd claude-code-permission-hook
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` does the same as `install.sh`, with Windows paths: it copies
`permission-hook.ps1` and `permission-hook.cmd` to `%USERPROFILE%\.claude\hooks` and registers
the hook to run through `powershell.exe`, so it works with or without Git Bash. `-Link`
symlinks the hook instead, which needs Developer Mode or an elevated prompt.

### Either way

Run the installer again after pulling a new version. Sessions started after installing use
the hook; restart any that are already open.

To install by hand, copy the hook somewhere and add it to `settings.json`. On macOS and
Linux, make it executable and use:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/permission-hook.sh" }]
      }
    ]
  }
}
```

On Windows:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                     "C:\\Users\\you\\.claude\\hooks\\permission-hook.ps1"]
          }
        ]
      }
    ]
  }
}
```

## Switching modes

The mode lives in `~/.claude/hooks/permission-hook.mode`. The hook reads it on every prompt,
so a change applies to all sessions from their next prompt, without a restart.

```bash
~/.claude/hooks/permission-hook.sh status      # current mode and the last few decisions
~/.claude/hooks/permission-hook.sh allow-all
~/.claude/hooks/permission-hook.sh deny-all
~/.claude/hooks/permission-hook.sh off
~/.claude/hooks/permission-hook.sh deny-rm
~/.claude/hooks/permission-hook.sh reset       # delete the mode file, back to deny-rm
```

On Windows, use `permission-hook.cmd`, which works from cmd and PowerShell without changing
the execution policy:

```powershell
& "$HOME\.claude\hooks\permission-hook.cmd" allow-all     # PowerShell
%USERPROFILE%\.claude\hooks\permission-hook.cmd allow-all  # cmd
```

To use a mode for one session only, set it in that session's environment. This overrides the
mode file:

```bash
CLAUDE_PERMISSION_HOOK_MODE=allow-all claude --dangerously-skip-permissions
```

```powershell
$env:CLAUDE_PERMISSION_HOOK_MODE = 'allow-all'   # applies to everything started from this window
claude --dangerously-skip-permissions
```

## Decision log

Every prompt the hook answers is appended to `~/.claude/hooks/permission-hook.log`, one
tab-separated line each:

```
2026-10-10T08:12:44Z	deny	deny-rm	bypassPermissions	Bash	cd sub && rm -f *
```

The fields are time (UTC), decision, mode, permission mode, tool and command (first 300
characters). Prompts the hook leaves alone aren't logged. Set `CLAUDE_PERMISSION_HOOK_LOG=0`
to turn logging off. The log isn't rotated; delete it whenever you like.

## Avoiding the prompt in the first place

`deny-rm` costs Claude a retry each time it writes an `rm` the check can't verify. Adding a
few rules to `CLAUDE.md` or `AGENTS.md` prevents most of those:
[docs/agent-instructions.md](docs/agent-instructions.md) has a section ready to paste, with
bad and good examples.

## Uninstall

```bash
./uninstall.sh                                                           # macOS and Linux
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1      # Windows
```

This takes the hook out of `settings.json` (with a backup), deletes the hook and mode file, and
keeps the decision log.

## Caveats

- **`allow-all` approves everything.** That includes the `rm` safety check, so Claude can
  delete anything your user account can. Use it in a container, a VM or on a machine you can
  rebuild. Your deny and ask rules still apply.
- **`deny-rm` only covers `rm` and `rmdir` in the Bash tool.** On Windows, Claude often uses
  the PowerShell tool instead. Claude Code handles `Remove-Item` itself: it denies wildcards
  and system paths outright without asking, and bypass mode skips its working-directory check,
  so there's no prompt for the hook to answer.
- **`deny-rm` matches the word `rm` anywhere in the command,** including inside quotes, as in
  `echo "rm"`. This only matters when that command would prompt anyway in a bypass session.
- **The Windows version hasn't run against a live Claude Code session on Windows.** CI tests
  the hook and installers on Windows PowerShell 5.1 and PowerShell 7, and the bash hook under
  Git Bash. Live tests cover macOS.
- **Claude Code changes.** This is tested with 2.1.295. If a later release stops running
  PermissionRequest hooks for the `rm` prompt, the hook stops answering and you get the prompt
  again; nothing is approved by mistake. Run `tests/live-test.py` after upgrading to check.

## Development

```bash
tests/test-hook.sh            # the bash hook: cases in tests/cases.json, with and without jq (needs jq)
tests/test-install.sh         # install.sh and uninstall.sh in a throwaway config dir (needs jq, python3)
pwsh -File tests/test-hook.ps1     # the PowerShell hook, same cases
pwsh -File tests/test-install.ps1  # install.ps1 and uninstall.ps1
tests/live-test.py            # real Claude Code sessions, one per scenario (uses Haiku, ~2 minutes)
```

CI runs shellcheck and PSScriptAnalyzer, then the unit tests on Ubuntu, macOS and Windows,
where the PowerShell tests run under both Windows PowerShell 5.1 and PowerShell 7. The live
test needs a logged-in Claude Code, so run it yourself.

## License

[MIT](LICENSE). This project isn't affiliated with or endorsed by Anthropic.
