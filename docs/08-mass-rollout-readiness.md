# Mass-rollout readiness & post-migration teardown

Status: analysis 2026-06-16 (vitaliy bot). Pilot (vitaliy + dmrudenko) is live on the
pod runtime; this doc covers migrating the **remaining 6 host bots** and cleaning up
afterwards. Findings below were cross-checked against the live host and repo (an
automated audit also flagged a missing `runtime/nftables/cl-egress.nft.tmpl` and a
missing pod `host-sudo` client — **both false; the files exist** — so those are NOT gaps).

## Roster (verified live via systemd, 2026-06-16)

| Runtime | Bots |
|---|---|
| Pod (`claude-pod@`) — new | vitaliy, dmrudenko, cptest (test tenant) |
| Host (`claude-tg@`) — legacy | **artemii, boris, daria, leonid, team, viveanne** (6 to migrate) |

Migration tooling already in repo and correct: `runtime/install/migrate-prep.sh`,
`migrate-cutover.sh` (line 106 **disables** `claude-tg@<user>` — closes the
2026-06-11 dual-runtime incident), `migrate-rollback.sh` (one-command revert).

---

## BLOCK A — finish / include in the build BEFORE mass rollout

### A1. graceful-restart → pod-aware  *(user-flagged)* — ✅ DONE 2026-06-16 (commit 52e65da)
**Shipped + verified live.** `runtime/install/graceful-restart-pod-bot` (+ `-install.sh`),
installed at `/usr/local/sbin/`. Admin-only (root via host-sudo). Waits 5 min idle (hard cap
60 min), idle read via `podman exec … tmux capture-pane`, **wall-clock** accounting (fixed a
tick-rate bug — podman exec latency broke the 10Hz assumption). e2e proven on cptest (5s
threshold → restart at +5s, rc=0). list/status/cancel. Original spec below.

`/usr/local/sbin/graceful-restart-bot` (host, **not in repo**, dated May 18) is fully
host-specific: it targets `claude-tg@<user>` and detects "busy" by reading the tenant's
**host-side tmux pane** (`sudo -u <user> tmux capture-pane -t claude`). For pod tenants
the unit is `claude-pod@` and tmux runs *inside* the container — so it neither finds the
unit nor sees activity.
- **DECISION (Vitaliy):** build an **admin-only** command `graceful-restart-pod-bot <user>`:
  - available to admins only (gated by the host-sudo broker — ordinary bots don't have it);
  - restarts the pod of **any** specified user on demand;
  - waits for **5 min of continuous inactivity** (idle read from the target's in-container
    tmux via `podman exec claude-<user> tmux capture-pane -p -S -60 -t claude`, same
    spinner-glyph logic as the old script) + a hard cap (~60 min) so it never blocks forever;
  - then `systemctl restart claude-pod@<user>`.
  Port the old mechanism to pod + bind to the admin tier. Bring the helper **into the repo**.

### A2. skill-deploy / mcp-deploy model for pod tenants  *(CONFIRMED real)*
Host timers `skill-deploy@<user>.timer` / `mcp-deploy@<user>.timer` still run for
already-migrated bots (verified: dmrudenko's fire every ~10 min) and rsync into the
pod's shared `~/.claude` volume. It "works" by shared-volume side effect, but:
- `mcp-deploy` reconciles `settings.json`, which the pod's `agentshield-settings-guard@<user>.path`
  watches and can revert to golden → host write vs pod guard can fight.
- **DECISION (Vitaliy):** **move skill/mcp deploy into the pod** (no functional difference for
  the user). Caveat to design around: `settings.json` is watched by the host
  `agentshield-settings-guard@<user>.path` — pod-side deploy writes to settings.json must be
  reconciled with the guard (rebaseline the golden after a legit deploy) or the guard reverts
  them. Then disable the host `skill-deploy@`/`mcp-deploy@` timers for migrated bots.

### A3. Sequenced migration runbook for the 6 bots  *(missing)*
Tooling exists but there's no ordered operator runbook.
- **Action:** write `docs/09-mass-migration-runbook.md`: order (Vitaliy: order doesn't matter),
  per-bot steps (prep → cutover → verify → soak), rollback + incident response (bot goes silent),
  and a soak gap between bots.
- **viveanne per-bot prep (iCloud):** her iCloud is a host-side rclone **FUSE mount** in her
  home. A container gets its own mount namespace, so the host mount does NOT appear inside her
  pod automatically → after migration her bot loses iCloud unless we explicitly propagate the
  mount into the pod (bind with rshared propagation) or re-establish the rclone mount in the
  pod context. Add this as an extra prep step for viveanne only; the other 5 need nothing special.

### A4. Post-cutover integration smoke  *(gap)*
`migrate-cutover.sh` verifies the channel is up but does **not** verify the migrated bot's
integrations (Composio / Exa / n8n / per-tenant OneCLI bindings). A missing binding fails
silently — the user sees nothing in Telegram.
- **Action:** add a per-bot post-cutover smoke (composio-session returns an MCP URL; an Exa
  search returns 200; vault bindings present) to the cutover or the runbook.

### A5. Pre-rollout validation check  *(nice-to-have)*
- **Action:** a `pre-mass-rollout-validate.sh`: cp-postgres / cp-api / cp-audit-collector /
  cp-judge up; image `claude-user:latest` current (watchdog + log-rotation baked, verified live);
  `cl-net` present; OneCLI responding; all 6 source bots healthy on the old runtime.

### A6. Minor / already-handled
- **Log rotation:** already FIXED (entrypoint rotates `session_current.txt` on every boot,
  commit `bdd4ed8`, verified live). Only caveat: it grows unbounded *between* restarts — minor,
  pods restart often; optional in-pod periodic rotation later.
- **m1.6-accept.sh** hardcodes `claude-tg@vitaliy` — it's an M1 dev acceptance script
  (teardown item), not used in mass rollout; fix only if reused.
- **make-admin.sh idempotency** (nftables/shellfirm double-run) — admin tier is opt-in per
  bot (only vitaliy + dmrudenko today; Phase-2 Telegram HITL not built), NOT part of the
  6-bot baseline. Defer with the admin-tier work.

---

## BLOCK B — clean up / delete AFTER all bots are on the pod

Extends the running teardown list in memory `project_fleet_dev_teardown`. Two layers:

### B1. Decommission the legacy host runtime (once all 6 migrated + soaked)
- Per bot: `systemctl disable --now claude-tg@<user>` (cutover already does this).
- Remove legacy launcher infra (root-owned, off-limits to this bot — operator does it):
  `claude-tg-launcher`, `run_telegram_bot.sh`, `launch_telegram_bots.sh`,
  `claude-tg@.service` template.
- Remove the M0 host watchdog: `claude-tg-watchdog.service` + `stabilization/bin/claude-tg-watchdog`
  (pods self-supervise via the entrypoint loop — no external host watchdog needed).
- Review `claude-telegram.service` (the "all instances" umbrella) — likely retire.
- Resolve A2: if deploy moves into the pod, disable host `skill-deploy@`/`mcp-deploy@` timers;
  if keeping the shared-volume model, keep them (documented decision).

### B2. Remove dev scaffolding (the build-only artifacts) — from `project_fleet_dev_teardown`
- **Consolidate** every `install/m*-*.sh` bring-up + paired `*-rollback.sh` into a productized
  `install.sh` / `uninstall.sh` (the repo + installer become the source of truth).
- Root grant for the vitaliy bot: `/etc/sudoers.d/90-vitaliy-fleet` (delete) + re-add
  `Bash(sudo *)` to settings.json deny.
- Dev PAT: `git-pat-vault-rollback.sh` + revoke the GitHub PAT + revert repo origin to ssh.
- Backups/images: `~/m0-wd-backups/`, `~/m4.3-backups/`, `pre-m0wd-*` / `m4.3-prev` image tags.
- Test tenants: **cptest** (`deprovision-tenant cptest`) and any `m3smoke` leftovers;
  `m3-cutover.sh` (vitaliy proof-of-concept, superseded by `migrate-cutover.sh`) → delete/archive.
- Control-plane hand-made instances (cp-postgres/redis/api/audit/judge, secrets, `/srv/audit`)
  stay for the pilot; recreated by `install.sh` at full decommission.

### B3. Source-of-truth check
At teardown, every item above must be reproducible by `install.sh`; the hand-made instance on
this box is the throwaway. Keep `project_fleet_dev_teardown` current as items land.

---

## Decisions — RESOLVED 2026-06-16 (Vitaliy)
1. **graceful-restart** (A1): build it — admin-only `graceful-restart-pod-bot <user>`, restarts
   any user's pod, waits 5 min idle, hard cap, then restart. ✅ decided.
2. **skill/mcp deploy** (A2): move deploy **into the pod**; reconcile with host settings-guard;
   then disable host timers for migrated bots. ✅ decided.
3. **Migration order** (A3): doesn't matter; viveanne needs iCloud-mount prep. ✅ decided.
4. Build now vs stage: proposed building A1 now + designing A2 + writing the runbook —
   awaiting Vitaliy's "го".
