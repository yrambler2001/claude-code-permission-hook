# Instructions that keep agents away from the rm prompt

The hook's `deny-rm` mode corrects Claude after it writes an `rm` the safety check can't
verify. Telling Claude the rules up front avoids most of those round trips.

Copy the section below into your `CLAUDE.md` or `AGENTS.md`: the project's file for one
project, or `~/.claude/CLAUDE.md` for all of them. Claude reads it at the start of every
session, and subagents read it too.

---

```markdown
## Deleting files (rm)

Claude Code won't run an `rm`/`rmdir` whose target it can't work out before the command runs;
it stops and waits for a person to approve it. No setting turns this off, so an unclear rm
stalls the session. Write every removal so the exact paths are visible in the command.

- Use literal absolute paths in `rm`. Never `rm` a relative path or glob after a `cd` in the
  same command.
- Don't build the target from `$(...)`, backticks or an unguarded variable. If you must use a
  variable, guard it: `"${DIR:?}"`.
- Don't put `rm` inside `bash -c` / `sh -c` scripts. Run it directly.
- Don't put globs or `..` in the directory part of the path (`build_*/obj/*`, `../*`).
- Don't glob-clear or delete the working directory or any of its parents. Write output to a
  subdirectory and clear that.
- Prefer a new output directory per run over clearing an old one.
- Never disguise a removal to get past the check (`find -delete`, `xargs rm`, `eval`, a
  script file). Make the target visible instead.

| Bad | Good |
|---|---|
| `cd /work/out && rm -f *` | `rm -f /work/out/*` |
| `cd /work && mkdir -p tmp && cd tmp && rm -f *` | `rm -rf /work/tmp && mkdir -p /work/tmp` |
| `rm -rf $OUT/*` | `rm -rf "${OUT:?}"/*` or `rm -rf /work/out/*` |
| `rm -rf $(ls -d /work/run_*)` | Run `ls -d /work/run_*` first, then `rm -rf /work/run_1 /work/run_2` |
| `bash -c 'rm -rf "$1"/*' _ /work/out` | `rm -rf /work/out/*` |
| `rm -rf /work/build_*/obj/*` | List the directories, then `rm -rf /work/build_a/obj/* /work/build_b/obj/*` |
| `cd build && rm -rf ../dist/*` | `rm -rf /work/dist/*` |
| `rm -f /path/to/working-dir/*` | `rm -rf /path/to/working-dir/out && mkdir /path/to/working-dir/out` |
```
