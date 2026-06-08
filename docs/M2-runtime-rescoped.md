# M2 — User runtime (Podman) + secrets gateway — RE-SCOPED per ADR-001

Source: `upgrade/08-runtime-and-gateways.md`, adjusted by
[ADR-001](./ADR-001-model-access.md): **LiteLLM is dropped from the model path;
Claude Code talks directly to Anthropic on its own subscription.** Blocking
Spike S1 is resolved (NO-GO) so M2 is no longer gated on it.

M2 builds and validates the containerized per-tenant runtime + secrets/egress
perimeter **on a throwaway test tenant** — it does not touch the live
`claude-tg@vitaliy` bot (that cutover is M3). Pilot = vitaliy only.

## Steps

### M2.1 — User runtime container image (`runtime/image/Containerfile`)
Ubuntu 24.04 + official Claude Code CLI + Bun + tmux + code-server + locked
platform hooks + shellfirm. **No `ANTHROPIC_BASE_URL`** (first-party direct to
`api.anthropic.com`). `entrypoint.sh` brings up the tmux `claude` session with
the official Telegram plugin (unpatched), code-server, and audit logging.

### M2.2 — Per-user systemd template unit (`claude-pod@.service`)
Rootless Podman: `--userns=keep-id`, `--cap-drop=ALL`,
`--security-opt=no-new-privileges`, read-only rootfs + tmpfs, mounts
(`~/.claude`, `~/work`, audit socket), dedicated netns. cgroup limits
(Mem/CPU/IO), `OOMPolicy=continue`, `Restart=always`. Idle → `podman pause`.
The M0 watchdog (watches plugin `bot.pid`) carries over.

### M2.3 — Network egress (`runtime/nftables/`, default-deny + allowlist)
Per-container netns, egress `policy drop`. **Allow:** `api.anthropic.com`
(model — direct first-party), OneCLI `:10255` (secrets), Composio/Exa
whitelist, controlled DNS. (Changed from ADR-001: anthropic direct, no LiteLLM
hop.) New egress hosts only via OneCLI binding / pipeline, never manual user
firewall edits.

### M2.4 — OneCLI secrets gateway integration (`gateways/onecli/`)
Per-tenant scoped access token (`Proxy-Authorization`) + bindings
(placeholder → secret, host+path+method), default-deny on unknown host.
Platform secrets (bot tokens, Composio/Exa) separated from user secrets. Key
use → audit. (Unchanged by the model decision — this is the secrets path.)

### M2.5 — Usage metering (re-scoped per ADR-001)
A metering collector fed from **Claude Code's own per-session/turn usage +
audit events** (event-driven hook — **no recurring LLM calls**), written to
`usage_records` (window/tokens/model), surfaced at `/usage`. Replaces the
LiteLLM-sourced usage in the original plan.

### M2.6 — Provisioner integration
On tenant create: OS account → netns + nftables → scaffold `.claude/` (locked
layer) → scoped OneCLI token + bindings → Postgres (`containers`,
`secret_bindings`) → enable `claude-pod@<user>`. (Dropped: the LiteLLM
virtual-key step.)

### M2.7 — Acceptance gate (re-scoped)
- Image builds; container starts rootless with cgroup limits.
- Egress verified: raw internet blocked; the container reaches **only** the
  audited OneCLI proxy (no strict host whitelist — see
  [ADR-002](./ADR-002-egress-policy.md)).
- OneCLI swaps placeholders by host/path; an "env dump" yields only FAKE values.
- Per-user usage recorded from Claude Code data (not a gateway).
- All on a **test** tenant; live `claude-tg@*` untouched.

## Build/run reality (carried from M1)
The bot can't run rootful podman or write system paths (ProtectSystem=strict),
so M2 follows the same loop: bot authors idempotent `install/m2-*.sh` +
**paired `*-rollback.sh`** (rollback-first rule), operator runs them as root,
bot verifies what it can over TCP / via `podman exec` helper scripts.
