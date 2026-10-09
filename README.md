# claude-code-permission-hook

A [Claude Code](https://code.claude.com) hook that answers permission prompts for you, so a
session nobody is watching doesn't sit waiting on a prompt.

The main use is the prompt Claude Code shows for an `rm` it can't verify. That prompt appears
even with `--dangerously-skip-permissions`, and no allow rule or PreToolUse hook can skip it:

```
Bash command · from the general-purpose agent
  cd /work/out && mkdir -p tmp && cd tmp && rm -f *
  Dangerous rm operation on statically-unresolvable target: /work/project/*

Do you want to proceed?
❯ 1. Yes
  2. No
```

In the default mode, the hook denies that prompt and tells Claude how to rewrite the command
so the check passes. Claude retries with `rm -f /work/out/tmp/*`, which runs without a
prompt, and the session carries on. If you'd rather approve everything, there's a mode for
that too.

## How it works

Claude Code runs [PermissionRequest hooks](https://code.claude.com/docs/en/hooks#permissionrequest)
when it is about to show a permission prompt. The hook can answer `allow` or `deny`, and a deny
can include a message that Claude reads as the tool error. `permission-hook.sh` is one such
hook with four modes:

| Mode | What it does | Where it applies |
|---|---|---|
| `deny-rm` (default) | Denies prompts for Bash commands that run `rm`/`rmdir`, telling Claude to use literal absolute paths | `--dangerously-skip-permissions` sessions only |
| `deny-all` | Denies every prompt, telling Claude to find a way that doesn't need approval or stop and report | `--dangerously-skip-permissions` sessions only |
| `allow-all` | Approves every prompt | Every permission mode |
| `off` | Does nothing | — |

The deny modes only act in `--dangerously-skip-permissions` sessions because those are the
unattended ones; in any other mode, prompts reach you as usual. If the hook can't run or has
nothing to say, Claude Code shows the prompt as if the hook weren't there.

Background on what the `rm` check catches and what doesn't get past it:
[docs/rm-safety-check.md](docs/rm-safety-check.md).

## Requirements

- Claude Code with PermissionRequest hooks. Tested with 2.1.295.
- macOS or Linux with `bash` 3.2 or newer, `sed` and `grep`. The hook uses `jq` when it's
  installed and falls back to `sed` when it isn't. Windows isn't supported.
- `python3` for `install.sh` and `uninstall.sh`, which edit `settings.json`.

## Install

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

Run it again after pulling a new version. Sessions started after installing use the hook;
restart any that are already open.

To install by hand, copy `hooks/permission-hook.sh` somewhere, make it executable, and add
this to `~/.claude/settings.json`:

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

To use a mode for one session only, set it in that session's environment. This overrides the
mode file:

```bash
CLAUDE_PERMISSION_HOOK_MODE=allow-all claude --dangerously-skip-permissions
```

An alias saves typing: `alias claude-perm=~/.claude/hooks/permission-hook.sh`.

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
./uninstall.sh
```

This takes the hook out of `settings.json` (with a backup), deletes the hook and mode file, and
keeps the decision log.

## Caveats

- **`allow-all` approves everything.** That includes the `rm` safety check, so Claude can
  delete anything your user account can. Use it in a container, a VM or on a machine you can
  rebuild. Your deny and ask rules still apply.
- **Future versions of Claude Code may stop running hooks for the `rm` check.** Claude Code
  already keeps some prompts for a person only. If that happens, the hook stops answering and
  you get the prompt again; nothing is approved by mistake. Run `tests/live-test.py` after
  upgrading to check.
- **`deny-rm` matches the word `rm` anywhere in the command,** including inside quotes, as in
  `echo "rm"`. This only matters when that command would prompt anyway in a bypass session.
- **Sessions that can't show a prompt,** such as `claude -p`, already deny it when no hook
  answers. There the deny modes only add the message telling Claude what to do instead, and
  `allow-all` approves.

## Development

```bash
tests/test-hook.sh       # the hook: every mode, with and without jq (needs jq)
tests/test-install.sh    # install.sh and uninstall.sh in a throwaway config dir (needs jq, python3)
tests/live-test.py       # real Claude Code sessions, one per scenario (uses Haiku, ~2 minutes)
```

CI runs shellcheck and the first two on Ubuntu and macOS. The live test needs a logged-in
Claude Code, so run it yourself.

## License

[MIT](LICENSE). This project isn't affiliated with or endorsed by Anthropic.
