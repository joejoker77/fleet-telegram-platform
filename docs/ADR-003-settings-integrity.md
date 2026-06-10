# ADR-003 — Tenant settings integrity ("can't disable the platform hooks/deny-list") via git-HEAD + AgentShield restore, not a locked managed layer

- **Status:** Accepted (decision) — 2026-06-09 (Vitaliy chose option (a)).
  **Implemented 2026-06-09 as a real-time guard (`m4.3-settings-guard.sh`) —
  pending operator apply + tamper-test PASS.** The first tamper test exposed that
  the existing `agentshield-gate@<user>` (15-min timer) only auto-reverts on NEW
  high/critical SCANNER findings; a *removed* deny rule / disabled hook is not a
  finding, so it was never restored. The guard below fills that gap.
- **Supersedes:** the "locked managed-settings layer" approach to M4 acceptance
  criterion #2 in `docs/09-security-stack.md` ("Слоистый settings.json — locked
  слой… Пользователь не может отключить").
- **Scope:** vitaliy pilot.

## Context

M4 criterion #2 requires that a tenant **cannot disable the platform security
controls** — the `PreToolUse` hooks (shellfirm wrapper, the `block-nested-claude`
guard) and the `permissions.deny` list (`rm -rf *`, `sudo *`, `ssh *`,
`chmod 777 *`, `*> /dev/*`, WebFetch/WebSearch) — by editing their own
`~/.claude/settings.json`.

The original design put these in a **managed (locked) `settings.json`** baked
read-only into the image, layered over the user file so the user couldn't turn
them off. That mechanism is **verified dead on Claude Code 2.1.169**: managed
hooks do not fire, and a stray `_comment` voids the whole managed file. (See
`feedback_managed_settings_not_enforced_2_1_169`.) So criterion #2 needs a
different enforcement.

## Decision

**Option (a) — heal-from-HEAD.** The platform security hooks + deny-list live in
the tenant's own `~/.claude/settings.json`, which is a **git repository**. A
**root-side** process — `agentshield-gate@<user>`, running outside the container
where the tenant uid cannot touch it — watches the directory. On any change that
diverges from `HEAD` it:

1. snapshots a pre-state commit (`agentshield-prestate-commit`), then
2. **restores `settings.json` from `HEAD`** (`git restore`), and
3. raises an alert.

The tenant can *write* the file momentarily, but the change cannot be made
**durable** — a process it does not control reverts it within seconds and flags
it. Durable, legitimate changes go through commit-to-`HEAD` + `agentshield-rebaseline`
(root). This is the model the other 7 fleet bots already run.

## Mechanism (as built — M4.3)

The 15-min `agentshield-gate` stays (it scans `~/.claude` for malicious *content*
and auto-reverts on new high/critical findings). On top of it, a **real-time
integrity guard** enforces the security subset:

- `agentshield-settings-guard@<user>.path` — a root-owned systemd path unit
  (`PathChanged=/home/<user>/.claude/settings.json`) fires within ~1s of any write.
- `agentshield-settings-guard <user>` compares the live file's **protected keys
  (`permissions` + `hooks`)** to a **root-owned golden**
  (`/var/lib/agentshield/golden/<user>.settings.json`, which the tenant cannot
  read/modify) and, on drift, restores just those keys — leaving `mcpServers`,
  `enabledMcpjsonServers`, `model`, etc. untouched so `deploy-mcp` and Claude
  Code's own writes are preserved. Logs + alerts via `security-alerter`.
- **Root-owned golden, not git HEAD:** the tenant owns `~/.claude` and could
  `git commit` its own tamper to HEAD, defeating a HEAD-based restore. The golden
  is root-only, so the tenant can neither change the source of truth nor disable
  the guard (root-owned units).
- **Authorized edits** use the existing `/etc/agentshield/operator-override.flag`
  (fresh <1h → guard skips) followed by `agentshield-settings-rebaseline <user>`.

Acceptance: `m4.3-tamper-test.sh` (remove `Bash(sudo *)` as the tenant → guard
restores it within seconds + alert).

## Rejected — Option (b): root-owned read-only mount

Mount the security settings from a root-owned file the tenant uid literally
cannot write (OS rejects the write — no window at all). Stronger, but:

1. more work to build/operate;
2. it **breaks the bot's own legitimate writes** to `settings.json` (Claude Code
   writes e.g. `enabledMcpjsonServers`; M5 self-service authoring will change
   settings) — a fully RO file would break normal operation;
3. to avoid (2) you must split "locked security bits" from "user-editable bits"
   — which is exactly the managed-layer split that is **broken on 2.1.169**. So
   (b) re-introduces the broken mechanism.

## Consequences

- Enforcement is **detect-and-revert + alert**, not physical impossibility —
  consistent with the defense-stack philosophy of bounded blast radius +
  detection (`feedback_trust_the_defense_stack`). The revert window is seconds
  and is alerted.
- Depends on `agentshield-gate@<user>` being live (it is, host-side; the
  pre-state commits in `~/.claude` git log are the evidence it fires).
- **Durable security-settings changes** require commit-to-`HEAD` +
  `agentshield-rebaseline` as root — already the documented flow
  (`feedback_managed_settings_not_enforced_2_1_169`).
- **Acceptance:** the tamper test `control-plane/install/m4.3-tamper-test.sh` —
  remove a deny entry as the tenant, confirm the gate restores it from `HEAD`
  within the window and alerts. (The managed layer is removed from the product
  image; the `block-nested-claude` guard already lives in the tenant Bash matcher
  in `HEAD`.)
