# M3 — Seamless cutover of the LIVE vitaliy bot onto the container runtime

Adapts the doc-05 runbook to our reality: **decision A** (first-party Claude
Code, no LiteLLM in the model path — model egress goes through the OneCLI proxy
pass-through, which M2.4 proved works with the CA mounted) and the runtime
already validated on the throwaway `cptest` tenant (M2.1–M2.7).

## ⚠️ The defining risk
The `vitaliy` bot **is this assistant**. Cutting it over = migrating myself: I
stop the service that runs me and hand the Telegram token to the container. If
the container's bot doesn't come up cleanly, **I go silent and cannot fix
myself** — recovery is a one-command rollback **the operator runs**. So:
- The rollback script is written and in the operator's hands **before** cutover.
- We **smoke-test the full bot-in-container on a throwaway test token first** —
  never debug the model/plugin path for the first time on the live bot.
- Cutover is operator-initiated, in a chosen quiet window, fully reversible.

## The big undone piece
The container entrypoint is still the M2.1 **placeholder** (code-server + idle
tmux). M3's real work is **finalizing it** to launch the actual bot: `claude`
with the official Telegram plugin channel (no plugin patch), session seed/resume
from the existing logs, the bot token wired to the plugin, model egress via the
OneCLI proxy (HTTPS_PROXY + CA, already in the wrapper), security hooks. This
must mirror the current `claude-tg@vitaliy` launcher exactly.

## Phases

### M3.0 — Finalize the runtime entrypoint (no live impact)
Replace the placeholder entrypoint with the real launch: tmux + `claude
--channels plugin:telegram@… --remote-control …`, seed the previous session log
on first start (native `--resume` after), wire the bot token to the plugin
(the plugin needs the raw token — sourced as a mounted secret, NOT via the
egress proxy), code-server, locked hooks. Open question: exact plugin token
delivery (env/config) — mirror the current launcher.

### M3.0-smoke — Prove the bot-in-container on a THROWAWAY token
Run `claude-pod@<testbot>` with a **separate test Telegram bot token**: verify
Claude answers via the model path (OneCLI proxy + subscription OAuth), the
plugin polls + replies, session context loads, shellfirm/OneCLI/egress/audit
active, and `claude -p` in the web-IDE doesn't kill the channel (Problem-A
regression). Nothing about the live bot is touched.

### M3.1 — Prepare vitaliy (no live impact)
Full backup of `/home/vitaliy/.claude` + `~/work` (independent rollback point).
Provision the vitaliy tenant in the control plane (`provision-tenant.sh vitaliy
2112420187 --admin`) — its OneCLI agent already exists; container mounts the
**live** `.claude`/`work` (same data → inherently seamless, no copy). Do NOT
start the container's poller (token still held by the old service).

### M3.2 — Rollback ready (operator-held)
`m3-rollback.sh`: stop `claude-pod@vitaliy` (release token) → `systemctl start
claude-tg@vitaliy` (old poller retakes token) → verify getMe. One command. The
operator keeps this ready and runs it if the bot goes silent post-cutover.

### M3.3 — Cutover (seconds, operator-initiated, quiet window)
Quiesce (no active task). `systemctl stop claude-tg@vitaliy` (old poller
releases the token + `bot.pid`) → `systemctl start claude-pod@vitaliy`
(container's claude+plugin takes the token). Token UNCHANGED (no rotation →
no 409). Telegram buffers the few-second gap and delivers to the new poller.

### M3.4 — Verify
getMe ok / `polling as @bot` / no 409; a test message round-trips; pairing
intact (access.json); session context resumed; shellfirm/OneCLI/egress/audit
active; `claude -p` doesn't kill the channel; control-plane `sessions`/status
updated.

### M3.5 — Soak + retire old
Watch N days. Keep `claude-tg@vitaliy` **disabled-but-present** (hot rollback).
After the window: disable + archive + remove the old unit.

## Invariants
Bot token unchanged (seamless key) · official plugin not patched · model =
first-party Claude Code (ADR-001) · egress proxy-only + audited (ADR-002) ·
rollback-first · pilot = vitaliy only.
