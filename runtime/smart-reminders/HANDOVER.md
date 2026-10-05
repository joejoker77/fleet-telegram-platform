# Smart reminders: service handover and provisioning notes

Built 5 October 2026 on the claude-fleet-monaco host. Owner of the decision: Dmitrii Rudenko. This document is for the developers who maintain the fleet platform and provision new users. It describes the system as deployed at the end of that day, after the changes made during the build (two-step `add`/`result`, two schedule shapes, Slack router with buttons, canonical files under `/opt`).

## What it does

A member of staff asks their Claude assistant (Telegram) for something like "check this again on the 13th" or "every Monday review my deadlines and tell me what changed". The assistant writes a prompt file and asks the smart-reminders service to schedule it. At the set time the service types one line into that person's main Telegram Claude session; the assistant of that day reads the prompt file, does the work with its normal tools and memory, and replies in the person's Telegram chat.

Claude Code is never in charge of the schedule. It can only ask. The service decides, keeps the reminders, fires them, and keeps the audit log.

## Policy

The old fleet rule "zero recurring LLM calls" was replaced on 5 October 2026 by Dmitrii's decision:

- No timer, cron or systemd unit may call a metered LLM API (OpenRouter, OpenAI, Anthropic API) on a schedule. That was the point of the old rule (the $360/day judge incident).
- A scheduled prompt into a Claude Code session is allowed. It runs on the firm's Claude subscription, is visible in the user's own Telegram chat, and is safety-checked at creation.

The wording now in every tenant's `~/.claude/CLAUDE.md` ("Hard rule: no timer may call a metered LLM API") and `~/work/CLAUDE.md` ("Scheduled reports, and the one hard rule") was applied with `rollout.py`. The template that generates these guides for new tenants still carries the old text; update it there as well (see "Provisioning").

## Components

| Piece | Where | Notes |
|---|---|---|
| Service | `/opt/smart-reminders/smart_reminders.py` | Python 3.12, stdlib only, runs as root |
| systemd unit | `/etc/systemd/system/smart-reminders.service` | `Restart=always`, `LoadCredential=openrouter:/etc/credstore/smart-reminders-openrouter.key` |
| Config | `/etc/smart-reminders.json` (mode 600) | approvers, Slack webhook URL + token, model, timings |
| Checker key | `/etc/credstore/smart-reminders-openrouter.key` (root, 600) | OpenRouter key "smart-reminders-checker", $10 limit, minted from the firm's provisioning key |
| State | `/var/lib/smart-reminders/` | `reminders.json`, `pending.json`, `audit.jsonl`, `prompts/<tenant>--<name>.md` |
| Slack interactivity router | n8n self-hosted workflow `qV9Geu2jhjUvEyl2` "Slack Interactivity Router (MS AI bot) [PROD]" | the ONE Request URL for the "Monaco Solicitors AI" Slack app: `https://n8n.monacosolicitors.co.uk/webhook/slack-interactivity-ms-ai-bot`. Parses block_actions / view_submission / shortcuts, picks a route from the action_id prefix (`smart_reminders_*` → smart_reminders) and hands the parsed payload to a sub-workflow with Execute Workflow. New bots add a prefix to `ROUTES` and a branch on the Switch. |
| Smart reminders Slack relay | n8n self-hosted workflow `8kwwcu9nJyqMCbZS` "Smart reminders → Slack DM (approval requests) [PROD]" | DM relay webhook (header token → `chat.postMessage` via the "MS AI bot" credential, Block Kit message with Approve/Decline buttons); sub-workflow entry (Execute Workflow Trigger) that records a button click in workflow static data and replaces the Slack message with the outcome; decisions poll webhook (`/webhook/smart-reminders-decisions-…`, header token, drained by the service every 15 s) |
| Client | canonical `/opt/smart-reminders/tenant/remind`, installed as `~/work/bin/remind` in every tenant home | writes request files, waits for the answer |
| Skill | canonical `/opt/smart-reminders/tenant/SKILL.md`, installed as `~/work/.claude/skills/smart-reminders/SKILL.md` in every tenant home | tells the assistant when and how to use it, how to write the prompt |
| Rollout / patch scripts | `/opt/smart-reminders/rollout.py`, `/opt/smart-reminders/patch_daily_report.py` | idempotent, run as root |
| Docs | `/opt/smart-reminders/HANDOVER.md`, `/opt/smart-reminders/ANNOUNCEMENT.md`, `config.example.json`, unit file copy | the Google Docs are rendered from these |
| Source-tree copy | `/opt/ftp-src/fleet-telegram-platform/runtime/smart-reminders/` | same files placed in the platform source tree on the host. That tree is not a git checkout; copy the directory into the real repository and commit it there. |
| Daily digest | `/usr/local/bin/claude_daily_report.py` (+ repo copy `runtime/install/claude-daily-report.py`) | new "Smart reminders" section: creations per user, 7 days and all time |

## Request flow

1. `remind add` writes `~/work/.claude/remind-requests/<rq-id>.json` in the tenant's home: `{op, name, schedule, prompt_file, title}`. `schedule` has one of two shapes, London time: `{"date": "YYYY-MM-DD", "at": "HH:MM"}` (one-off) or `{"cron": "minute hour day-of-month month weekday"}` (repeating, standard 5-field cron, e.g. `0 9 * * 1`, `0 9 13,26 * *`, `0 9 1 1,4,7,10 *`). The service validates the shape and renders it in words everywhere it is shown. It prints the rq id and returns at once. The prompt is in `~/work/.claude/reminders/<name>.md`. The assistant then runs `remind result <rq-id>`, which polls `~/work/.claude/remind-responses/<rq-id>.json` for up to 5 minutes. The two steps are deliberate: the first command's output (with the rq id) is written to the session log as soon as it returns, which is what lets the service identify the session exactly.
2. The service polls every tenant's request directory every 15 s. A tenant is any `/home/<user>` with `.claude/channels/telegram-*`; its pod is the container `claude-<user>`, its uid is the home's owner.
3. For `add`, the service identifies the calling Claude session by searching the tenant's recent session logs (`~/.claude/projects/*/*.jsonl`, excluding subagents) for the request id (present in the tool result of `remind add`), falling back to the command line `remind add <name>` (written to the log before the command runs), then to the most recently modified session in the last 10 minutes. It waits up to 150 s for the log to catch up. The audit records which method matched (`session_found_by`).
4. It takes the last 10 user messages of that session (channel wrapper stripped, system notices skipped) and sends them with the prompt and schedule to the checker: OpenRouter, model from config (`anthropic/claude-sonnet-5.5`), temperature 0, max 800 output tokens, JSON verdict `allow|refuse` plus reason (the verdict is also read from a truncated or malformed reply). This is the only LLM call and it happens only on a creation event.
5. `allow`: reminder stored, audit `created`, client told "Created".
   `refuse` (or checker error, which fails closed): parked in `pending.json`, audit `pending_approval`, client told it has gone to the tech team, approvers notified by Slack DM (fallback: admin's Telegram via the admin tenant's `tg-send`).
6. An approver either presses Approve/Decline on the Slack message or runs `remind approve <id>` / `remind decline <id>` in their own Claude chat (only tenants listed in `approvers` / Slack ids in `approver_slack_map` may). Button clicks reach the n8n interactivity receiver, which stores the decision; the service polls the decisions endpoint every 15 s and applies it. Either way the service creates or drops the reminder, audits `approval_approved|declined` with `decided_by` and note (`via Slack button` for clicks), and types a line into the requesting user's session so their assistant tells them the outcome (`user_notified` audit).

   **Slack app setting (done by Dmitrii on 5 Oct 2026; redo if the app is ever recreated):** in api.slack.com → the "Monaco Solicitors AI" (MS AI bot) app → Interactivity & Shortcuts → Interactivity on → Request URL `https://n8n.monacosolicitors.co.uk/webhook/slack-interactivity-ms-ai-bot` (the general router, shared by every future bot that uses this app). Verified end to end with a real click the same day. Slack request signing is not verified yet (the router only acts on known action_id prefixes and the reminders sub-workflow only honours approver ids); add signature verification with the app's signing secret in the router when convenient.
7. Firing: every 30 s the service checks due reminders (London time; one-off date, or cron match, walking back over the 6-hour late window to the latest unfired slot after a restart; one fire per slot). It runs `podman exec --user <uid>:<gid> claude-<user> tmux -S /home/<user>/.claude/tmux-<uid>/default send-keys -t claude:0.0 -l "<line>"` then `Enter`. The line names the reminder, the prompt file and the Telegram chat id (from `channels/telegram-*/last_chat.json`). If the assistant is mid-task the line waits in its input box and becomes the next turn. One-off reminders are marked `done` after firing.

## Audit log

`/var/lib/smart-reminders/audit.jsonl`, one JSON object per line. Events: `created`, `pending_approval` (with `approval_id`, `sent_to`), `approver_notified` / `approver_notify_failed` (channel slack|telegram), `approval_approved` / `approval_declined` (with `decided_by`, `note`), `user_notified` / `user_notify_failed`, `fired` / `fire_failed`, `remove`, `decision_rejected`. Each creation record carries tenant, name, schedule, session id, how the session was found, number of messages reviewed, verdict, reason, risk, model, and the first 400 characters of the prompt.

`python3 /opt/smart-reminders/smart_reminders.py --stats` prints per-tenant counts (created in 7 days, all time, active, fired); the daily digest uses it. `--list` and `--pending` dump the stores.

## Operations

```
systemctl status smart-reminders
journalctl -u smart-reminders -n 50
python3 /opt/smart-reminders/smart_reminders.py --list | --pending | --stats
```

Config changes are picked up on the next loop; code changes need `systemctl restart smart-reminders`. To add an approver: in `/etc/smart-reminders.json` add the tenant name to `approvers`, their Slack user id to `approver_slack_ids` and the pair to `approver_slack_map`; and add the same Slack id → tenant pair to the `APPROVERS` constant in the "Record decision" Code node of the relay workflow `8kwwcu9nJyqMCbZS` (it decides whose button clicks count). To rotate the checker key: write the new key to `/etc/credstore/smart-reminders-openrouter.key` (root, 600) and restart. The OpenRouter key has a $10 limit; a check costs well under a cent.

Known limits: the tmux target is `claude:0.0`, the session the pod entrypoint supervises; if the entrypoint changes the session name, update `tmux_target`. If a pod is down when a reminder is due, the fire fails and is audited (`fire_failed`); it is not retried beyond the 6-hour window. Slack request signatures are not verified yet (see step 6). There is no web UI; the stores are JSON files and the `--list / --pending / --stats` commands.

## Session identification across many sessions

A tenant may have the main Telegram session plus up to ~32 Claude App (remote-control) sessions. The service does not assume the request came from the main session: it searches every recent session log of that tenant for the request id (and, failing that, the `remind add <name>` command line), so the context it reviews is the session that actually asked, and the audit says how it was found. Firing and approval outcomes, however, always go to the main Telegram session (that is the one the entrypoint supervises and the user is told to expect the result there).

## Provisioning a new user

Nothing in this system lives in a user's home as a source: the canonical files are root-owned under `/opt/smart-reminders` (and mirrored in the platform repository). When a new tenant is created, add to the provisioning script:

1. Copy `/opt/smart-reminders/tenant/remind` to `/home/<user>/work/bin/remind` (owner the tenant, mode 755).
2. Copy `/opt/smart-reminders/tenant/SKILL.md` to `/home/<user>/work/.claude/skills/smart-reminders/SKILL.md` (owner the tenant, mode 644).
3. Create `/home/<user>/work/.claude/{remind-requests,remind-responses,reminders}` owned by the tenant.
4. Make sure the tenant's `~/.claude/CLAUDE.md` and `~/work/CLAUDE.md` carry the new rule text (the paragraphs are in `rollout.py` as `GLOBAL_NEW` and `PROJECT_NEW`); best done by updating the template they are generated from.

Or simply run `python3 /opt/smart-reminders/rollout.py` as root after the home exists: it is idempotent and does all four steps for every tenant. The service itself needs nothing per tenant; it discovers tenants from `/home`.

## Removing

`systemctl disable --now smart-reminders`; delete `/opt/smart-reminders`, `/etc/smart-reminders.json`, `/etc/credstore/smart-reminders-openrouter.key`, `/var/lib/smart-reminders`; deactivate n8n workflow `8kwwcu9nJyqMCbZS` and remove the smart_reminders branch from the router `qV9Geu2jhjUvEyl2`; disable the OpenRouter key "smart-reminders-checker" in the OpenRouter workspace. Tenant-side files (`remind`, the skill, `~/work/.claude/remind-*`) are harmless without the service: the client reports "no answer from the service" and creates nothing.
