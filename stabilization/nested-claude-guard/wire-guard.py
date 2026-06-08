#!/usr/bin/env python3
"""wire-guard.py — idempotently merge the block-nested-claude PreToolUse hook
into one or more bots' ~/.claude/settings.json.

`.hooks.PreToolUse` is a JSON path INSIDE settings.json, not a separate file.
This script appends the guard hook to the existing `Bash` matcher (or creates
one), without disturbing other hooks. Safe to re-run: if the guard hook is
already present it does nothing.

Run as root (operator), e.g.:
    ./wire-guard.py /home/vitaliy/.claude/settings.json
    ./wire-guard.py /home/*/.claude/settings.json          # all bots
    ./wire-guard.py --dry-run /home/vitaliy/.claude/settings.json

NOTE: settings.json is AgentShield-protected. If AgentShield rolls the edit
back, re-baseline/approve it via the security-stack tooling before relying on
the guard.
"""
import argparse
import json
import shutil
import sys
import time

GUARD_CMD = "/usr/local/share/claude-guard/block-nested-claude.py"


def merge(settings: dict) -> bool:
    """Return True if a change was made."""
    hooks = settings.setdefault("hooks", {})
    pre = hooks.setdefault("PreToolUse", [])

    # Already wired anywhere?
    for entry in pre:
        for h in entry.get("hooks", []):
            if h.get("command") == GUARD_CMD:
                return False  # idempotent: nothing to do

    new_hook = {"type": "command", "command": GUARD_CMD, "timeout": 5}

    # Prefer appending to an existing exact "Bash" matcher.
    for entry in pre:
        if entry.get("matcher") == "Bash":
            entry.setdefault("hooks", []).append(new_hook)
            return True

    # Otherwise add a dedicated Bash matcher entry.
    pre.append({"matcher": "Bash", "hooks": [new_hook]})
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="settings.json file(s)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    rc = 0
    for path in args.paths:
        try:
            with open(path) as f:
                data = json.load(f)
        except FileNotFoundError:
            print(f"  SKIP  {path} (not found)")
            continue
        except json.JSONDecodeError as e:
            print(f"  ERR   {path} (invalid JSON: {e})")
            rc = 1
            continue

        changed = merge(data)
        if not changed:
            print(f"  ok    {path} (guard already wired)")
            continue
        if args.dry_run:
            print(f"  WOULD {path} (add guard to PreToolUse/Bash)")
            continue

        bak = f"{path}.bak-{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(path, bak)
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        print(f"  WIRED {path}  (backup: {bak})")

    sys.exit(rc)


if __name__ == "__main__":
    main()
