# Mass-migration runbook — host bots → pod runtime

Operator playbook to migrate the remaining host bots (`claude-tg@<user>`) to the pod
runtime (`claude-pod@<user>`) one at a time, safely and reversibly. Companion to the
readiness analysis in `08-mass-rollout-readiness.md`.

**Scope (2026-06-16):** migrate **artemii, boris, daria, leonid, team** (5).
**viveanne is DEFERRED** — her iCloud is a host FUSE mount that won't appear inside her
pod without extra prep; wait for Vitaliy's iCloud instructions before touching her.

**iCloud prerequisite (decided 2026-06-17, `docs/12`):** the pod runtime does NOT yet propagate
`~/icloud` into the container, so migrating an iCloud user loses their Mac-file access (already
happened to dmrudenko). **Before migrating any user who has/wants iCloud**, the `claude-pod-run`
`:rslave` propagation fix MUST be in place; provisioning is an admin-only skill. For the 5 here,
check per-bot (step 1) — none currently has an active iCloud mount (only dmrudenko + viveanne do),
so this gates viveanne specifically, but verify each.

**Golden rules**
- Run every command **from the operator's own terminal / the admin (vitaliy) session via
  host-sudo — NEVER from inside the target bot's own session.** `migrate-cutover.sh` has a
  self-destruct guard, but don't rely on it.
- One bot at a time. Soak each before starting the next.
- `migrate-prep.sh` has **no live impact** (never stops the running bot). The live cut
  happens only in `migrate-cutover.sh` step 1.
- Rollback is always one command: `migrate-rollback.sh <user>`. The cutover also
  **auto-rolls-back** if verification fails.

`RT=/home/vitaliy/work/fleet-platform/runtime`

---

## Phase 0 — once, before the first bot (pre-rollout validation)

Confirm the shared infra is ready (the A5 "pre-mass-rollout-validate" checklist):
- Control-plane containers up: `cp-postgres`, `cp-redis`, `cp-api`, `cp-audit-collector`, `cp-judge`.
- Runtime image current: `podman image exists localhost/claude-user:latest` **and** it has the
  liveness-watchdog + log-rotation baked in (already true on the pilot; rebuild via
  `m2.1-build-image.sh` if in doubt).
- `podman network exists cl-net`.
- OneCLI responding.
- All 5 target bots currently healthy on the host (each has a live
  `/home/<user>/.claude/channels/telegram-<user>/bot.pid`).

Pick a **canary**: migrate ONE low-traffic bot first, soak it longer (a few hours / overnight),
then proceed with the rest. Order otherwise doesn't matter (Vitaliy: order unimportant).

---

## Phase 1 — per-bot procedure

For each `<user>` (with its `<telegram_id>`):

### 1. Pre-checks
- Bot healthy on host: `systemctl is-active claude-tg@<user>` = active; `bot.pid` alive.
- Know its `<telegram_id>` (from the bot registry or `users` table).
- **iCloud?** Does the user have an active mount (`systemctl is-active rclone-<user>-mount` or
  `rclone-icloud-mount@<user>`)? If YES, the `claude-pod-run` `:rslave` propagation fix (`docs/12`)
  must be deployed first, or they lose Mac-file access at cutover. If NO, nothing extra.

### 2. Prep (safe, no live impact, idempotent)
```
host-sudo bash $RT/install/migrate-prep.sh <user> <telegram_id>
```
Does: timestamped backup of `~/.claude` + `~/work` (rollback point, path saved to
`~/work/.migrate-backup-path`); ensures the control-plane tenant row; installs the pod unit +
wrapper (does NOT start the pod); writes `/etc/cl-egress/<user>.token` by **reusing** the live
bot's OneCLI token (no regenerate → no rotation race). The running bot is untouched.

### 3. Dry-run cutover (read-only pre-flight)
```
host-sudo bash $RT/install/migrate-cutover.sh <user> --dry-run
```
Must print **"pre-flight all green"** (image, cl-net, token, live .env, workspace trusted,
control-plane row, pod unit). Fix any `MISS` before proceeding.
⚠️ Use the `--dry-run` **flag**, not `DRYRUN=1 sudo …` — sudo strips the env var and it runs
for real.

### 4. Real cutover (this ends the live host session for a few seconds)
```
host-sudo bash $RT/install/migrate-cutover.sh <user>
```
Flow: stop host poller (releases token + shared OAuth) → start pod (same creds, single
instance → no 409) → verify ≤90s (container running, `polling as @`, no 409) → finalize
(**enable pod, disable host** — kills the reboot dual-runtime race) → on any failure it
**auto-rolls-back**. Watch for `✅ CUTOVER VERIFIED`.

### 5. Verify round-trip + integrations  *(A4 — do NOT skip)*
- **Send the bot a Telegram message** — confirm it answers (channel round-trip).
- **Integrations smoke** (a missing binding fails silently — user sees nothing):
  - Composio: `composio-session --user-id <chat_id>` returns an MCP URL (or a known tool call 200s).
  - Exa: a quick search returns results.
  - n8n / any service the bot uses.
- (Once A2 lands) **disable the now-redundant host deploy timers** for this bot:
  `systemctl disable --now skill-deploy@<user>.timer mcp-deploy@<user>.timer`.

### 5b. iCloud (only if the user has it)
If step 1 flagged an iCloud mount: confirm the user sees their files **inside the pod** (the host
mount is propagated via the `:rslave` bind). If absent, the propagation fix isn't deployed —
stop and fix it before declaring the migration done. (dmrudenko needs this applied retroactively.)

### 6. Soak
Leave it running and watch (`journalctl -u claude-pod@<user> -f`, and that it answers). Canary:
hours/overnight. Subsequent bots: shorter, but confirm a real user interaction before the next.

### 7. If it goes silent → rollback
```
host-sudo bash $RT/install/migrate-rollback.sh <user>
```
Stops the pod (releases token/OAuth), re-enables + starts `claude-tg@<user>`, verifies bot.pid +
getMe. Idempotent. Then diagnose from `~/work/migrate-cutover-diag.txt` + plugin logs before retry.

---

## Phase 2 — after ALL targets are migrated and soaked

Proceed to **Block B** in `08-mass-rollout-readiness.md` (decommission the legacy host runtime
+ remove dev scaffolding). Key items: disable/remove `claude-tg@` units + launchers +
`claude-tg-watchdog`; resolve the skill/mcp-deploy model (A2); consolidate `m*-*.sh` into a
productized `install.sh`/`uninstall.sh`; remove dev-only grants/PATs/test tenants.

---

## Quick reference

| Step | Command | Live impact |
|---|---|---|
| Prep | `migrate-prep.sh <user> <tg_id>` | none |
| Dry-run | `migrate-cutover.sh <user> --dry-run` | none |
| Cutover | `migrate-cutover.sh <user>` | ~seconds of downtime |
| Graceful restart (admin) | `graceful-restart-pod-bot <user>` | waits for idle |
| Rollback | `migrate-rollback.sh <user>` | ~seconds of downtime |

All `host-sudo`-prefixed when run from the admin bot session.
