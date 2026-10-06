#!/usr/bin/python3
"""Install self-service relogin for named tenants on this host (run as root).

    python3 /opt/relogin/rollout.py vitaliy            just these people
    python3 /opt/relogin/rollout.py --status           who has it, who does not
    python3 /opt/relogin/rollout.py --all              every tenant (see below)

NAMING TENANTS IS THE POINT. This went out as a canary of one, and `--all` is kept
behind a flag on purpose: the flow writes to a person's Telegram chat, and a bug that
messages thirty-four lawyers at three in the morning is not one you can take back.
Widen it only once the canary has been through a real expiry.

WHAT LANDS IN A HOME

  ~/work/bin/relogin                          the helper, tenant-owned, 755
  ~/work/.claude/skills/relogin/              the mod, and the skill note beside it
  ~/.claude/run/                              where the flow keeps its state

The mod is installed as a skills folder rather than through settings.json for two
reasons, both learned here: a plugin in `~/work/.claude/skills/<name>` is loaded by the
engine with no settings key at all, and writing ~/.claude/settings.json under a live
session has killed the Telegram plugin before (2026-06-01).

IT TAKES EFFECT AT THE NEXT SESSION START. The helper works immediately — it is a
script, and the assistant can run it the moment this finishes. The mod's hooks are read
when a session starts, so the one thing that needs a restart is the part that catches a
code when the model cannot be reached. `graceful-restart-pod-bot <tenant>` does that
without dropping the channel.

Idempotent: safe to re-run, and it is how an updated helper reaches a tenant.
"""
from __future__ import annotations

import argparse
import glob
import os
import pwd
import shutil
import sys

SRC = os.environ.get("RELOGIN_SRC", "/opt/relogin/tenant")
HELPER = f"{SRC}/relogin"
MOD = f"{SRC}/mod"
HOME_ROOT = os.environ.get("FLEET_HOME_ROOT", "/home")
SKIP = {"cplane"}


def tenants() -> dict[str, tuple[int, int]]:
    """Every home that has a Telegram channel → (uid, gid). That is what a tenant is."""
    found = {}
    for path in sorted(glob.glob(f"{HOME_ROOT}/*/.claude/channels/telegram-*")):
        user = path.split("/")[2]
        if user in SKIP:
            continue
        try:
            entry = pwd.getpwnam(user)
        except KeyError:
            continue
        found[user] = (entry.pw_uid, entry.pw_gid)
    return found


def own(path: str, uid: int, gid: int, mode: int) -> None:
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def place_file(src: str, dst: str, uid: int, gid: int, mode: int) -> bool:
    """Copy when the content differs. Returns True when something changed."""
    if os.path.exists(dst):
        with open(src, "rb") as a, open(dst, "rb") as b:
            if a.read() == b.read():
                own(dst, uid, gid, mode)
                return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    own(dst, uid, gid, mode)
    return True


def make_dir(path: str, uid: int, gid: int, mode: int = 0o755) -> None:
    os.makedirs(path, exist_ok=True)
    own(path, uid, gid, mode)


def install(user: str, uid: int, gid: int) -> str:
    home = f"{HOME_ROOT}/{user}"
    changed = []

    make_dir(f"{home}/work/bin", uid, gid)
    if place_file(HELPER, f"{home}/work/bin/relogin", uid, gid, 0o755):
        changed.append("helper")

    mod_dst = f"{home}/work/.claude/skills/relogin"
    make_dir(mod_dst, uid, gid)
    touched = False
    for root, dirs, files in os.walk(MOD):
        rel = os.path.relpath(root, MOD)
        here = mod_dst if rel == "." else os.path.join(mod_dst, rel)
        make_dir(here, uid, gid)
        for name in files:
            if place_file(os.path.join(root, name), os.path.join(here, name),
                          uid, gid, 0o644):
                touched = True
        dirs.sort()
    if touched:
        changed.append("mod")

    # The flow's state lives beside the credentials it renews, in a directory the pod
    # mounts as a volume — so a restart does not lose a sign-in that is half done.
    make_dir(f"{home}/.claude/run", uid, gid, 0o700)

    return ", ".join(changed) if changed else "already current"


def status() -> int:
    for user, (uid, _gid) in tenants().items():
        home = f"{HOME_ROOT}/{user}"
        has_helper = os.path.exists(f"{home}/work/bin/relogin")
        has_mod = os.path.exists(f"{home}/work/.claude/skills/relogin/hooks/register.ts")
        mark = "installed" if (has_helper and has_mod) else (
            "helper only" if has_helper else "no")
        print(f"{user:24} {mark}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("users", nargs="*", help="tenants to install for")
    ap.add_argument("--all", action="store_true", help="every tenant on the host")
    ap.add_argument("--status", action="store_true", help="who has it already")
    args = ap.parse_args()

    if args.status:
        return status()
    if os.geteuid() != 0:
        print("relogin rollout: run as root", file=sys.stderr)
        return 1
    for path in (HELPER, MOD):
        if not os.path.exists(path):
            print(f"relogin rollout: {path} is missing", file=sys.stderr)
            return 1

    known = tenants()
    if args.all:
        targets = list(known)
    elif args.users:
        targets = args.users
    else:
        print("relogin rollout: name the tenants, or pass --all deliberately",
              file=sys.stderr)
        return 2

    rc = 0
    for user in targets:
        if user not in known:
            print(f"{user:24} not a tenant on this host")
            rc = 1
            continue
        uid, gid = known[user]
        print(f"{user:24} {install(user, uid, gid)}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
