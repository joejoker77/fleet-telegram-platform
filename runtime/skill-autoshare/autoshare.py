#!/usr/bin/python3
"""Publish every tenant's new or changed skill to the firm catalogue, by itself.

    autoshare.py                 what it would publish, and why (default: changes nothing)
    autoshare.py --apply         actually publish
    autoshare.py --user <name>   one person only
    autoshare.py --status        what the catalogue holds for each tenant

WHY THIS EXISTS. Sharing was a thing a person had to remember to do, so almost nobody
did: on 2026-10-07 there were 101 different skills across 35 workspaces and 8 of them
in the catalogue. Six of the duplicates had been copied between homes by hand, which
means the author's later fixes never reached anyone. This closes that by default.

WHAT IT DOES NOT DO. It publishes; it never installs anything into anyone's workspace.
Distribution stays a separate decision, because a skill that lands on 35 machines takes
effect on their next message and there is no way to take it back.

PUBLIC OR PRIVATE. Dmitrii's rule, 2026-10-07: everything reaches the catalogue; what
the author does not want spread is listed but not offered to colleagues. So:
  * `share: false` / `visibility: private` in the SKILL.md frontmatter, or a `.noshare`
    file in the skill folder  -> published PRIVATE (in the catalogue, nobody else sees it)
  * a skill that is plainly one person's voice, style or standing rules -> PRIVATE too,
    by the same logic, because it cannot work for anyone else. The owner can publish it
    public by hand if they disagree.
  * everything else -> PUBLIC.

WHAT IT REFUSES TO PUBLISH. Anything carrying what looks like client identifiers - an
outside email address, a UK postcode, a National Insurance number, a phone number, a
deal id in a URL. It does not try to fix them; it names the file and the line and leaves
the skill alone, because de-identifying someone's playbook is not a machine's call.

Skills that came FROM the catalogue are skipped (same name, published by someone else),
so an install never gets republished under the wrong name.

Idempotent: a skill is published only when its content hash differs from the last
publish recorded in /var/lib/skill-autoshare/state.json.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import time

HOME_ROOT = "/home"
STATE = "/var/lib/skill-autoshare/state.json"
REPORT_DIR = "/var/log/skill-autoshare"
ROLE_DIR = "/etc/claude-role"

# Shipped with every workspace (tenant skel, relogin and smart-reminders rollouts) or
# owned by the platform — never the tenant's own work, so never published.
FIRM = {"chase-draft", "client-update", "field-lookup", "matter-brief", "send-for-signature",
        "share-skill", "week-ahead", "relogin", "smart-reminders", "synced"}

PII = [
    ("an outside email address", re.compile(r"[\w.+-]+@(?!monacosolicitors\.co\.uk|grapple|example\.)[\w-]+\.[\w.]{2,}")),
    ("a UK postcode", re.compile(r"\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b")),
    ("a National Insurance number", re.compile(r"\b[A-CEGHJ-PR-TW-Z]{2}\d{6}[A-D]\b")),
    ("a phone number", re.compile(r"(?<!\w)(?:\+44|0)(?:\d[ -]?){9,12}(?!\w)")),
    ("a deal id in a URL", re.compile(r"pipedrive\.com/deal/\d+")),
]
PERSONAL = re.compile(
    r"\b(own (?:writing )?voice|own house style|house style for every|standing rules|"
    r"standing requirements|personal (?:style|voice|rules)|in (?:his|her|their) voice|"
    r"never (?:offer|end|say|send)\b)", re.I)


def run(cmd: list[str], timeout: int = 120) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def tenants() -> list[str]:
    try:
        return sorted(u for u in os.listdir(ROLE_DIR) if os.path.isdir(f"{HOME_ROOT}/{u}"))
    except OSError:
        return []


def skills_of(user: str) -> dict[str, str]:
    root = f"{HOME_ROOT}/{user}/work/.claude/skills"
    out = {}
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for name in names:
        d = f"{root}/{name}"
        if name in FIRM or not os.path.isdir(d) or not os.path.exists(f"{d}/SKILL.md"):
            continue
        out[name] = d
    return out


def digest(path: str) -> str:
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            h.update(os.path.relpath(p, path).encode())
            try:
                with open(p, "rb") as fh:
                    h.update(fh.read())
            except OSError:
                pass
    return h.hexdigest()[:16]


def frontmatter(path: str) -> tuple[dict, str]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return {}, ""
    m = re.match(r"\s*---\n(.*?)\n---\n", text, re.S)
    head = {}
    if m:
        for line in m.group(1).splitlines():
            kv = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
            if kv:
                head[kv.group(1).lower()] = kv.group(2).strip().strip("\"'")
    return head, text


def wants_private(folder: str, head: dict, text: str, user: str, name: str) -> str | None:
    """Returns the reason this one is listed but not offered, or None for public."""
    if os.path.exists(f"{folder}/.noshare"):
        return "the folder has a .noshare file"
    if str(head.get("share", "")).lower() in ("false", "no", "private"):
        return "SKILL.md says share: false"
    if str(head.get("visibility", "")).lower() == "private":
        return "SKILL.md says visibility: private"
    first = user.split("-")[0].lower()
    if len(first) > 2 and first in name.lower():
        return f"the name carries the owner ({first})"
    desc = head.get("description", "")
    # The owner's own name in the description is the plainest statement that a skill is
    # theirs: "Zahra's follow-up", "Paul Young's own writing voice", "Malik's reply".
    if len(first) > 2 and re.search(rf"\b{re.escape(first)}\b", desc, re.I):
        return f"the description is written for {first.capitalize()} by name"
    if PERSONAL.search(desc) or PERSONAL.search(text[:2000]):
        return "it is written as one person's own voice or standing rules"
    return None


def client_data(folder: str) -> list[str]:
    hits = []
    for root, dirs, files in os.walk(folder):
        dirs.sort()
        for f in sorted(files):
            if not f.lower().endswith((".md", ".txt", ".json", ".csv")):
                continue
            p = os.path.join(root, f)
            try:
                lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                continue
            for n, line in enumerate(lines, 1):
                for label, rx in PII:
                    if rx.search(line):
                        hits.append(f"{os.path.relpath(p, folder)}:{n} looks like {label}")
                        if len(hits) >= 6:
                            return hits
    return hits


def catalogue_names(pod_user: str) -> dict[str, str]:
    """name -> publisher, read once from the catalogue through one tenant's own client."""
    rc, out = run(pod_cmd(pod_user, ["share-skill", "list"]))
    names = {}
    for line in out.splitlines():
        m = re.match(r"^\s{2}(\S+)\s+by (\S+)\s*$", line)
        if m:
            names[m.group(1)] = m.group(2)
    return names


def pod_cmd(user: str, argv: list[str]) -> list[str]:
    uid = pwd.getpwnam(user).pw_uid
    argv = [f"/home/{user}/work/bin/{argv[0]}"] + argv[1:]
    return ["podman", "exec", "-u", str(uid), "-e", f"HOME=/home/{user}", f"claude-{user}"] + argv


def publish(user: str, name: str, version: str, public: bool, note: str) -> tuple[bool, str]:
    argv = ["share-skill", "publish", name, "--version", version]
    if public:
        argv.append("--public")
    if note:
        argv += ["--note", note[:220]]
    rc, out = run(pod_cmd(user, argv))
    first = next((l for l in out.splitlines() if l.strip()), "")
    return ("Shared:" in out), first


def bump(version: str) -> str:
    a, b, c = (version.split(".") + ["0", "0"])[:3]
    return f"{a}.{b}.{int(c) + 1}"


def load_state() -> dict:
    try:
        return json.load(open(STATE))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    json.dump(state, open(tmp, "w"), indent=1, sort_keys=True)
    os.replace(tmp, STATE)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="publish (default: say what would happen)")
    ap.add_argument("--user", action="append", help="limit to these tenants")
    ap.add_argument("--status", action="store_true", help="what the catalogue holds")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("skill-autoshare: run as root", file=sys.stderr)
        return 1

    users = args.user or tenants()
    if not users:
        print("no tenants found")
        return 1

    reader = next((u for u in ("vitaliy", *users) if os.path.isdir(f"{HOME_ROOT}/{u}")), users[0])
    cat = catalogue_names(reader)
    if args.status:
        for n, who in sorted(cat.items()):
            print(f"{n:28} by {who}")
        print(f"\n{len(cat)} in the catalogue")
        return 0

    state = load_state()
    report = {"when": int(time.time()), "published": [], "skipped": [], "refused": []}

    for user in users:
        for name, folder in skills_of(user).items():
            key = f"{user}/{name}"
            owner = cat.get(name)
            if owner and owner != user:
                report["skipped"].append({"skill": key, "why": f"came from the catalogue ({owner})"})
                continue  # someone else's published skill, installed here
            h = digest(folder)
            prev = state.get(key, {})
            if prev.get("hash") == h:
                continue
            head, text = frontmatter(f"{folder}/SKILL.md")
            hits = client_data(folder)
            if hits:
                report["refused"].append({"skill": key, "why": "possible client data", "detail": hits})
                print(f"held back     {key:42} -> possible client data")
                for h in hits[:3]:
                    print(f"                 {h}")
                continue
            why_private = wants_private(folder, head, text, user, name)
            version = bump(prev.get("version", "1.0.0")) if prev else "1.0.0"
            note = (head.get("description") or "").split(". ")[0][:220]
            line = f"{key:42} -> {'private' if why_private else 'PUBLIC':7} v{version}"
            if why_private:
                line += f"  ({why_private})"
            if not args.apply:
                print("would publish  " + line)
                continue
            ok, said = publish(user, name, version, public=not why_private, note=note)
            tries = 0
            while not ok and "already exists" in said and tries < 5:
                version = bump(version); tries += 1
                ok, said = publish(user, name, version, public=not why_private, note=note)
            if ok:
                state[key] = {"hash": h, "version": version,
                              "visibility": "private" if why_private else "public",
                              "when": int(time.time())}
                report["published"].append({"skill": key, "version": version,
                                            "visibility": "private" if why_private else "public"})
                print("published      " + line)
            else:
                report["refused"].append({"skill": key, "why": said})
                print("REFUSED        " + line + f"  {said}")

    if args.apply:
        save_state(state)
        os.makedirs(REPORT_DIR, exist_ok=True)
        json.dump(report, open(f"{REPORT_DIR}/last-run.json", "w"), indent=1)
        print(f"\npublished {len(report['published'])}, refused {len(report['refused'])}, "
              f"skipped {len(report['skipped'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
