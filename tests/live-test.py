#!/usr/bin/env python3
"""Live test: run real Claude Code sessions and check how the hook answers the rm prompt.

Each scenario starts an interactive `claude` session in a temporary directory and asks it to
run `cd <dir> && cd sub && rm -f *`, which always triggers Claude Code's rm safety prompt.
The session loads this checkout's hook through --settings and skips your user settings
(--setting-sources project,local), so an installed copy of the hook doesn't interfere.

macOS and Linux only (it drives the terminal through a pty). It uses your normal Claude Code
login, costs a little Haiku usage and takes about a minute
per scenario. Run it after upgrading Claude Code to confirm the hook still works.

usage: tests/live-test.py [--model MODEL] [--keep] [SCENARIO ...]
scenarios: deny-rm allow-all deny-all attended (default: all)
"""

import argparse
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(REPO, "hooks", "permission-hook.sh")
ANSI = re.compile(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[=>()][0-9A-Za-z]?")

# bypass: start with --dangerously-skip-permissions (otherwise the default permission mode)
# hook:   text the transcript must show, or None when the hook must not answer
# gone:   whether the files must end up deleted, or None to not check
SCENARIOS = {
    "deny-rm": dict(bypass=True, hook="Denied by PermissionRequest hook", gone=True),
    "allow-all": dict(bypass=True, hook="Allowed by PermissionRequest hook", gone=True),
    "deny-all": dict(bypass=True, hook="Denied by PermissionRequest hook", gone=None),
    "attended": dict(bypass=False, hook=None, gone=False, mode="deny-rm"),
}

# Variables that tie a process to the Claude Code session it runs in. Removing them lets this
# script run from inside a Claude Code session too.
SESSION_VARS = re.compile(r"^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_PERMISSION_HOOK_.*|"
                          r"CLAUDE_CODE_.*(SESSION|MESSAGING|BRIDGE|ENTRYPOINT|EXECPATH).*)$")


def squash(text):
    return re.sub(r"\s+", "", text)


def run(name, spec, model, keep):
    work = tempfile.mkdtemp(prefix=f"permission-hook-{name}-")
    sub = os.path.join(work, "sub")
    os.makedirs(sub)
    for f in ("a.txt", "b.txt"):
        open(os.path.join(sub, f), "w").close()

    settings = {"hooks": {"PermissionRequest": [
        {"matcher": "*", "hooks": [{"type": "command", "command": HOOK}]}]}}
    env = {k: v for k, v in os.environ.items() if not SESSION_VARS.match(k)}
    env.update(TERM="xterm-256color", CLAUDE_PERMISSION_HOOK_MODE=spec.get("mode", name),
               CLAUDE_PERMISSION_HOOK_LOG="0")
    prompt = (f"Run this exact bash command as one Bash tool call, unmodified: cd {work} && cd sub && rm -f * "
              "-- If the call is denied, follow the denial message and retry once, then stop.")
    argv = ["claude", "--model", model, "--setting-sources", "project,local",
            "--settings", json.dumps(settings)]
    argv += ["--dangerously-skip-permissions"] if spec["bypass"] else ["--permission-mode", "default"]

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
    proc = subprocess.Popen(argv + [prompt], cwd=work, env=env, stdin=slave, stdout=slave,
                            stderr=slave, start_new_session=True)
    os.close(slave)

    raw, start, trusted, prompt_seen, hook_seen, gone_at = "", time.time(), False, None, None, None
    while time.time() - start < 180:
        if select.select([master], [], [], 0.5)[0]:
            try:
                raw += os.read(master, 65536).decode("utf-8", "replace")
            except OSError:
                break
        text = squash(ANSI.sub("", raw))
        now = time.time()
        if not trusted and "Itrustthisfolder" in text:
            trusted = True
            time.sleep(1)
            os.write(master, b"\x1b[B")  # the dialog defaults to "No, exit"
            time.sleep(0.5)
            os.write(master, b"\r")
        if prompt_seen is None and "Doyouwanttoproceed" in text:
            prompt_seen = now
        if hook_seen is None and "PermissionRequesthook" in text:
            hook_seen = now
        if gone_at is None and not os.listdir(sub):
            gone_at = now
        if gone_at and now - gone_at > 3:
            break
        if prompt_seen and not hook_seen and now - prompt_seen > 20:
            break  # the prompt is waiting for a person
        if hook_seen and now - hook_seen > 45:
            break
        if proc.poll() is not None:
            break

    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.close(master)

    text = squash(ANSI.sub("", raw))
    gone = not os.listdir(sub)
    problems = []
    if spec["hook"] and squash(spec["hook"]) not in text:
        problems.append(f"expected {spec['hook']!r}")
    if not spec["hook"]:
        if "PermissionRequesthook" in text:
            problems.append("the hook answered a prompt it should have left alone")
        if prompt_seen is None:
            problems.append("no permission prompt appeared")
    if spec["gone"] is not None and gone != spec["gone"]:
        problems.append("files were deleted" if gone else "files were not deleted")

    log = os.path.join(work, "screen.txt")
    with open(log, "w") as f:
        f.write(ANSI.sub("", raw))
    status = "PASS" if not problems else "FAIL"
    print(f"{status} {name}: {'; '.join(problems) or 'ok'} ({time.time() - start:.0f}s)")
    if problems or keep:
        print(f"     screen capture: {log}")
    else:
        shutil.rmtree(work, ignore_errors=True)
    return not problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--model", default="haiku", help="model for the test sessions (default: haiku)")
    parser.add_argument("--keep", action="store_true", help="keep each scenario's directory and screen capture")
    parser.add_argument("scenarios", nargs="*", metavar="SCENARIO", help=f"any of: {' '.join(SCENARIOS)}")
    args = parser.parse_args()
    unknown = [name for name in args.scenarios if name not in SCENARIOS]
    if unknown:
        parser.error(f"unknown scenario: {' '.join(unknown)}")
    if not shutil.which("claude"):
        sys.exit("claude is not on PATH")
    names = args.scenarios or list(SCENARIOS)
    results = [run(name, SCENARIOS[name], args.model, args.keep) for name in names]
    print(f"{sum(results)} of {len(results)} scenarios passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
