# Managed settings layer — REMOVED (2026-06-09)

The `/etc/claude-code/managed-settings.json` "locked platform layer" introduced in
M4 #3 has been **removed**. This file is now a tombstone documenting why.

## What M4 #3 tried to do

Bake a read-only, highest-precedence `managed-settings.json` into the image at
`/etc/claude-code/` holding the security hooks (shellfirm + block-nested-claude),
the deny list, and the metering Stop hook — so security could not be weakened by the
tenant's writable `~/.claude/settings.json` — and then *de-dup* that security config
out of the tenant file.

## Why it was removed (verified in-pod on Claude Code 2.1.169)

1. **Managed-layer HOOKS do not fire.** A managed-only `block-nested-claude` hook
   never blocked a probe (`false && claude doctor`) even though the hook script itself
   returns exit 2 on that exact payload, and the file was valid/clean/read-only. So
   the locked layer could not enforce its most important control (the nested-claude
   guard).
2. **The managed deny added zero coverage.** Its deny list was a strict *subset* of
   the tenant deny (the tenant even adds `Bash(sudo *)`). The one theoretical edge —
   an immutable deny with no tamper-window — is unproven on this version and marginal,
   because the tenant model already covers it (see below).
3. **It was a foot-gun.** 2.1.169's managed validator is stricter than the normal
   settings parser: a single unrecognized key (we hit this with a top-level
   `_comment`) **silently voids the entire managed file** — no error, no enforcement.
4. **It was a snowflake.** Only the vitaliy pilot had it; the other 7 bots run the
   tenant model below.
5. **Its de-dup step was actively harmful.** Emptying the tenant deny + dropping the
   tenant Bash hooks makes `agentshield-gate` flag a "No deny list configured"
   regression and restore `settings.json` from git HEAD — pointless churn + alerts.

## The model we actually rely on (and that works)

Security lives in the tenant `~/.claude/settings.json`:

- **`~/.claude` is a git repo; HEAD is the source of truth.**
- `agentshield-prestate-commit` (a PreToolUse hook on Write/Edit) commits `~/.claude`
  before each change → audit trail + restore point.
- `agentshield-gate@<user>` (15-min timer + on restart) scans posture vs
  `/var/lib/agentshield/baselines/<user>.json`; on a high/critical regression it does
  `git restore settings.json from HEAD` and alerts the operator via Telegram.
- Hooks in the tenant layer **do** fire (shellfirm, the install-gates, telegram hooks
  all work), including `block-nested-claude` once it is wired into the tenant Bash
  matcher (M4.3 follow-up, 2026-06-09).

To durably change tenant security config: edit `settings.json`, **commit it to
`~/.claude` HEAD**, then `agentshield-rebaseline <user>` (root). A bare edit is
reverted to HEAD on the next gate run.

See memory `feedback_managed_settings_not_enforced_2_1_169` for the full incident.
