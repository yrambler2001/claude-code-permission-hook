#!/usr/bin/env python3
"""Add or remove the permission-hook entry in a Claude Code settings.json.

Any existing hook that runs permission-hook.sh or permission-hook.ps1 (the Windows version,
added by install.ps1) is replaced, so running `add` again is safe. Other settings and hooks
are kept. Before changing an existing file it is copied to <settings.json>.bak-<timestamp>;
a file that would not change is left alone.
"""

import json
import os
import re
import shutil
import sys
import tempfile
import time

MARKER = re.compile(r"permission-hook\.(sh|ps1)")
USAGE = """usage: edit_settings.py add <settings.json> <hook command>
       edit_settings.py remove <settings.json>"""


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        sys.exit(f"{path} is not valid JSON ({e}); fix it first, nothing was changed")
    if not isinstance(data, dict):
        sys.exit(f"{path} does not hold a JSON object; nothing was changed")
    return data


def is_ours(hook):
    if not isinstance(hook, dict):
        return False
    args = hook.get("args") if isinstance(hook.get("args"), list) else []
    return bool(MARKER.search(" ".join(str(part) for part in [hook.get("command", ""), *args])))


def without_ours(groups):
    """Return the PermissionRequest matcher groups with our hook taken out."""
    kept = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            kept.append(group)
            continue
        hooks = [h for h in group["hooks"] if not is_ours(h)]
        if hooks:
            kept.append({**group, "hooks": hooks})
    return kept


def add(data, command):
    hooks = data.setdefault("hooks", {})
    groups = without_ours(hooks.get("PermissionRequest") or [])
    groups.append({"matcher": "*", "hooks": [{"type": "command", "command": command}]})
    hooks["PermissionRequest"] = groups


def remove(data):
    hooks = data.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(hooks.get("PermissionRequest"), list):
        return
    groups = without_ours(hooks["PermissionRequest"])
    if groups:
        hooks["PermissionRequest"] = groups
    else:
        del hooks["PermissionRequest"]
    if not hooks:
        del data["hooks"]


def save(path, original, data):
    if data == original:
        print(f"{path}: already up to date" if os.path.exists(path) else f"{path}: nothing to change")
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    if os.path.exists(path):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup, n = f"{path}.bak-{stamp}", 1
        while os.path.exists(backup):
            backup, n = f"{path}.bak-{stamp}-{n}", n + 1
        shutil.copy2(path, backup)
        print(f"{path}: backed up to {backup}")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".settings-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    print(f"{path}: updated")


def main(argv):
    if len(argv) == 4 and argv[1] == "add":
        path, command = argv[2], argv[3]
    elif len(argv) == 3 and argv[1] == "remove":
        path, command = argv[2], None
    else:
        sys.exit(USAGE)
    path = os.path.realpath(path)  # write through a symlinked settings.json, not over it
    original = load(path)
    data = json.loads(json.dumps(original))
    if command is None:
        remove(data)
    else:
        add(data, command)
    save(path, original, data)


if __name__ == "__main__":
    main(sys.argv)
