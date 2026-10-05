#!/usr/bin/python3
"""Roll smart reminders out to tenants on this host (run as root):
    python3 /opt/smart-reminders/rollout.py              every tenant
    python3 /opt/smart-reminders/rollout.py alice bob    only these

Naming tenants is what provisioning uses: add-user.sh runs it for the one person it has just
created, so adding somebody does not rewrite thirty-three other people's files to no purpose.
With no names it does the whole host, which is what a rollout is.

For each tenant (a home with ~/.claude/channels/telegram-*):
  * install the `remind` client into ~/work/bin (tenant-owned, 755)
  * install the skill into ~/work/.claude/skills/smart-reminders/SKILL.md
  * rewrite the old "zero recurring LLM calls" rule in ~/.claude/CLAUDE.md and the
    "a timer may never call an AI model" paragraph in ~/work/CLAUDE.md to the
    policy decided on 5 Oct 2026 (no timer may call a METERED LLM API; a scheduled
    prompt into a Claude session is allowed)
Idempotent: safe to re-run. Prints one line per tenant.
"""
import glob, os, re, shutil, sys

SRC = "/opt/smart-reminders/tenant"          # canonical copies, root-owned
CLIENT = f"{SRC}/remind"
SKILL = f"{SRC}/SKILL.md"

GLOBAL_OLD_HEAD = "## Hard rule: zero recurring LLM calls"
GLOBAL_NEW = """## Hard rule: no timer may call a metered LLM API

No timer, cron or systemd unit anywhere may call a metered LLM API (OpenRouter, OpenAI, the
Anthropic API or any other pay-per-token endpoint) on a schedule. Those calls happen only on
CI-on-PR (event-triggered) or when the user triggers them; an unattended loop once burned
$360 in a day, which is why the rule exists.

A scheduled prompt into a Claude Code session is different and is allowed (decided by Dmitrii
Rudenko, CEO, 5 Oct 2026): it runs on the firm's Claude subscription, is visible in the user's
Telegram chat, and lets the assistant pick up a follow-up with full context. The tool for it is
`~/work/bin/remind` (skill `smart-reminders`); every new reminder passes an automatic safety
check and, if flagged, tech-team approval. `report-schedule` remains for fixed, no-model
reports. Still refuse anything that would poll a metered API from a timer, however it is
dressed up.

"""
PROJECT_OLD = """**A timer may run a program. A timer may never call an AI model.** That is a firm
rule with no exceptions. So a scheduled report is a fixed query whose output goes
through unchanged. If the user asks for something that "keeps an eye on things" or
"reviews my matters every morning with AI", say no and offer the fixed report
instead. Do not build it, and do not put a Claude call in a cron job or a loop."""
PROJECT_NEW = """**A timer may run a program, and it may hand a prompt to this Claude session.** It may
never call a metered LLM API (OpenRouter, OpenAI, Anthropic API) directly: that is the
firm rule, and it exists because an unattended loop once burned $360 in a day. So there
are two kinds of scheduled job. `report-schedule` runs a fixed query and posts its output
unchanged. `remind` (skill `smart-reminders`) stores a prompt and, at the set time, the
smart-reminders service types it into the main Telegram session so the assistant does the
follow-up with full context, on the firm's Claude subscription; every new reminder passes
an automatic safety check and, if flagged, tech-team approval. Use `remind` for "check this
again on the 13th" or "every Monday review X"; use `report-schedule` when the user only
wants the numbers."""


def tenants():
    out = {}
    for d in glob.glob("/home/*/.claude/channels/telegram-*"):
        name = d.split("/")[2]
        st = os.stat(f"/home/{name}")
        out[name] = (f"/home/{name}", st.st_uid, st.st_gid)
    return out


def put(src, dst, uid, gid, mode):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.chown(os.path.dirname(dst), uid, gid)
    shutil.copyfile(src, dst)
    os.chmod(dst, mode)
    os.chown(dst, uid, gid)


def fix_global(path):
    try:
        s = open(path).read()
    except OSError:
        return "no-global-guide"
    if GLOBAL_OLD_HEAD not in s:
        return "global-ok" if "metered LLM API" in s else "global-no-rule"
    i = s.index(GLOBAL_OLD_HEAD)
    j = s.find("\n## ", i + 10)
    s = s[:i] + GLOBAL_NEW + (s[j + 1:] if j != -1 else "")
    open(path, "w").write(s)
    return "global-fixed"


def fix_project(path):
    try:
        s = open(path).read()
    except OSError:
        return "no-project-guide"
    if PROJECT_OLD in s:
        open(path, "w").write(s.replace(PROJECT_OLD, PROJECT_NEW))
        return "project-fixed"
    return "project-ok" if "smart-reminders" in s else "project-no-rule"


def main():
    wanted = set(sys.argv[1:])
    found = tenants()
    if wanted:
        missing = wanted - set(found)
        for name in sorted(missing):
            # Said out loud rather than skipped silently: a provisioning step that reports success
            # for a tenant it never saw is how a new person ends up without the tool.
            print(f"{name:<22} NOT A TENANT (no ~/.claude/channels/telegram-*)")
        found = {k: v for k, v in found.items() if k in wanted}
        if not found:
            raise SystemExit(1)
    for name, (home, uid, gid) in sorted(found.items()):
        notes = []
        if os.path.isdir(f"{home}/work"):
            put(CLIENT, f"{home}/work/bin/remind", uid, gid, 0o755)
            put(SKILL, f"{home}/work/.claude/skills/smart-reminders/SKILL.md", uid, gid, 0o644)
            for d in ("remind-requests", "remind-responses", "reminders"):
                p = f"{home}/work/.claude/{d}"
                os.makedirs(p, exist_ok=True)
                os.chown(p, uid, gid)
            notes.append("client+skill")
            notes.append(fix_project(f"{home}/work/CLAUDE.md"))
        else:
            notes.append("no-work-dir")
        notes.append(fix_global(f"{home}/.claude/CLAUDE.md"))
        print(f"{name:<22} {' '.join(notes)}")


if __name__ == "__main__":
    main()
