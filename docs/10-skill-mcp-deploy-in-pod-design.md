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

Go with **Option A** (control-plane-driven, reuses M8). ✅ CONFIRMED by Vitaliy 2026-06-16.

---

## Implementation spec (reconciler fully reverse-engineered 2026-06-16)

Read both canonical reconcilers (`deploy/deploy-skills`, `control-plane/install/deploy-mcp.v2.4`).
The cp-api reconcile must reproduce, **per pod tenant**:

### Skills (from `deploy-skills`)
1. Source: claude-bot-skills `skills/` at `main`. (Host uses an SSH-key git clone into
   `~/.claude/skills-repo`; cp-api instead **fetches over HTTPS via the scoped proxy token** —
   no SSH, no per-pod clone.)
2. Allow-list: every dir under `skills/`, minus those whose `users.yaml > skills.<slug>.users`
   list excludes the tenant. (No entry ⇒ allowed for everyone.)
3. Apply: `rsync -a --delete` each allowed skill → `~/.claude/skills/<slug>/` (chown tenant);
   **remove** any skill dir present but no longer allowed / no longer in the repo.

### MCP (from `deploy-mcp.v2.4`)
1. Source: `mcp/<slug>/template.json` + `users.yaml` `mcp:` section.
2. Allow-list: same rule via `mcp.<slug>.users`.
3. Per slug: take `mcp_stanza` (or whole template if flat). Resolve placeholders:
   - `${USER_CONFIG:key}` ← `users.yaml > mcp.<slug>.user_config.<user>.<key>`. **Missing ⇒ skip the MCP.**
   - `${SECRET:name}` ← **literal marker `${ONECLI:name}`** (NEVER the real value). Also verify
     the secret is BOUND to the tenant's OneCLI agent; **not bound ⇒ skip the MCP**. Binding check:
     agent UUID for identifier `<user>-bot` → its bound secret IDs → cross-ref `onecli secrets list`
     → strip the `<user>-<slug>-` prefix mcp-set-secret prepends → bare name must match template.
4. Managed-set merge into `settings.json` `mcpServers`: track managed slugs in state
   (host: `/var/lib/mcp-deploy/<user>.managed.json`); remove previously-managed slugs no longer
   resolved; add/update resolved ones; **leave non-managed entries (e.g. shellfirm) untouched**.
   Atomic write, chown tenant, 0600. On change → graceful restart (now `graceful-restart-pod-bot`).
5. The deploy-time judge/scanner GATE is **deprecated (ADR-004)** — deploy reconciles CI-vetted
   content; do NOT re-scan here.

### Integration wrinkles to solve (NEW work — flagged)
- **W1 — settings.json vs settings-guard (the real one):** `~/.claude` is a git repo; the host
  `agentshield-settings-guard@<user>.path` restores `settings.json` from git HEAD + alerts on any
  unexpected change. cp-api is a *container* — it can write the shared volume but **cannot** run
  the host-side `agentshield-settings-rebaseline` / commit-to-HEAD. So a cp-api write would be
  reverted. Resolution: a tiny **host-side apply hook** (same pattern as `cp-secretd`: cp-api
  sends the staged settings change over a local socket; the host helper commits it to `~/.claude`
  HEAD + rebaselines the guard). This keeps secrets/host-trust on the host and lets cp-api drive.
- **W2 — OneCLI agent/secret queries from cp-api:** the binding check needs
  `onecli agents list` / `agents secrets --id` / `secrets list`. Confirm cp-api's OneCLI client
  can run these (M6 wired secret *binding*; need *read* of agent secret sets too).
- **W3 — reconcile trigger:** a periodic per-tenant reconcile (interval or DB-event). NOT an LLM
  call → complies with the no-recurring-LLM rule (the host already runs these on 10-min timers).

### Phased build plan (rollback-first, pilot-validated)
1. cp-api reconcile **core** (fetch + allow-list + resolve) with a **dry-run** that logs the
   computed skills set + mcpServers diff for a tenant — no writes. Validate on vitaliy vs the
   current host-deployed state (must match byte-for-byte intent).
2. Add the apply path + **W1 host apply-hook**; write skills; write settings.json via the hook;
   confirm the settings-guard does NOT revert. Validate on vitaliy.
3. Wire the reconcile trigger; run cp-api path and host timer in parallel on vitaliy, diff.
4. Per bot at cutover: disable host `skill-deploy@`/`mcp-deploy@` timers (runbook step). Rollback
   = re-enable host timers.

**Open question for Vitaliy:** W1 approach — a small host apply-hook (recommended, mirrors
cp-secretd; keeps the settings-guard intact) is the cleanest. Confirm before I build phase 2.
