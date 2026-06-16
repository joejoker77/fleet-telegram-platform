# A2 design — skill/MCP deploy for pod tenants

Decision (Vitaliy 2026-06-16): **move skill/MCP deploy off the host timers and into the pod
world**, since there's no functional difference for the user. This doc designs how, because
it's the most architecturally involved of the rollout items and crosses into the
`claude-bot-skills` deployment system.

## Current state (host)

- Per-user systemd timers `skill-deploy@<user>.timer` / `mcp-deploy@<user>.timer` fire ~every
  10 min and run `/usr/local/sbin/deploy-skills <user>` / `deploy-mcp <user>`.
- Those host scripts come from the **`joejoker77/claude-bot-skills`** repo (NOT fleet-platform):
  clone/pull `main` via a per-user **SSH deploy key**, rsync `skills/<allowed-for-user>/` →
  `~/.claude/skills/`, and reconcile `~/.claude/settings.json` `mcpServers` from
  `mcp/<allowed>/template.json` + `users.yaml` (`${USER_CONFIG}`) + OneCLI vault (`${SECRET}`).
- Allow-listing + per-bot config live in `users.yaml`.

## Why it needs to change for pods

Verified live: for already-migrated bots (e.g. dmrudenko) the **host timers keep firing** and
write into the pod's **shared `~/.claude` volume**. It "works" by side effect, but:
1. **settings.json fight** — `mcp-deploy` rewrites `settings.json`, which the host
   `agentshield-settings-guard@<user>.path` watches and can revert to its golden → race.
2. **Architecturally muddy** — the host reaches into pod-owned state; after the legacy host
   runtime is decommissioned (Block B) the SSH-key clone + host scripts go away anyway.
3. **No SSH in the pod** — the pod can't reuse the per-user SSH deploy-key clone path.

## Options

### Option A — control-plane-driven deploy *(RECOMMENDED)*
Fold skill/mcp reconciliation into **cp-api**, reusing the M8 machinery almost wholesale.
cp-api already has every dependency:
- **claude-bot-skills read access** — the api.github.com token the egress proxy injects is
  already scoped to `claude-bot-skills` (confirmed during M8: GET on that repo → 200). So
  cp-api can fetch `skills/`, `mcp/`, `users.yaml` at a pinned ref over HTTPS — no SSH key.
- **OneCLI** for `${SECRET}` injection and per-bot binding (already wired, M6).
- **Write-into-tenant-`~/.claude`** — M8's `installFiles` + `chownToTenant` already write
  skills/commands into a tenant's `.claude` with correct ownership.
- **Scanning** — `@fleet/scanners` fail-closed scan already gates artifacts at the M8 boundary.

Mechanism: a cp-api reconcile routine (per-tenant, event- or interval-driven — NOT an LLM call,
complies with the no-recurring-LLM rule) that, for each pod tenant: fetch the allow-listed
skills + mcp templates from claude-bot-skills `main`, resolve `${USER_CONFIG}`/`${SECRET}`,
write skills into `~/.claude/skills/`, reconcile `settings.json` `mcpServers`, then
**rebaseline the settings-guard golden** (see below). One place, all deps present, pod-native.

### Option B — in-container deploy
Run the deploy logic inside each tenant pod (a reconcile step in the entrypoint supervisor loop).
Costs: each pod needs its own git read creds for claude-bot-skills (https + token, replacing the
host SSH key), OneCLI access (have, via proxy), and a copy/mount of `users.yaml`. Duplicates
credentials and logic across N pods; more surface area. Only advantage: fully self-contained per
pod. **Not recommended** given Option A reuses existing control-plane plumbing.

## Settings-guard coordination (both options)

`settings.json` is watched by `agentshield-settings-guard@<user>.path`, which restores from a
golden on unexpected change. A legitimate deploy write must not be reverted. Approach: after a
deploy writes `settings.json`, call `agentshield-settings-rebaseline <user>` (root) so the new
content becomes the golden. The deploy path becomes the single authorized writer of
`mcpServers`; any *other* change still trips the guard. (This mirrors how the tenant settings +
git-HEAD restore model already works.)

## Migration & rollback

- At each bot's cutover (runbook step 5), once the new deploy path is serving that bot, **disable
  the host timers**: `systemctl disable --now skill-deploy@<user>.timer mcp-deploy@<user>.timer`.
- Rollback: re-enable the host timers (`systemctl enable --now …`) — they resume writing the
  shared volume exactly as before. Keep this until the new path is proven per bot.
- Full Block-B teardown removes the host deploy scripts + SSH deploy keys (claude-bot-skills
  side) once all bots are on the new path.

## Recommendation & next step

Go with **Option A** (control-plane-driven, reuses M8). Next step is to scope the cp-api
reconcile routine + the `users.yaml` allow-list parsing + the rebaseline hook, then build behind
a per-tenant flag and validate on the vitaliy pilot before switching any host timer off.

**Open question for Vitaliy:** confirm Option A (control-plane-driven) vs Option B (in each
pod). The rest of the design assumes A.
