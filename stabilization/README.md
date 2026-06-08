# M0 — Stabilization (Phase 0)

Hotfixes for the **live** `claude-tg@<user>` stack. They stop the bleeding before
any architectural migration and are forward-compatible with the target build
(no new tech debt). See design doc `../docs/01-stabilization-hotfixes.md`.

Everything here is **additive** — nothing edits the root-owned base unit or the
launcher. Apply with `sudo ./apply.sh`; it restarts **no bots**.

## What this fixes

| Problem | Symptom | Fix here |
|---|---|---|
| **A** — nested `claude` kills the TG plugin | `claude -p` / `claude mcp list` evicts the parent poll lock; bot goes silent until manual restart | **Prevention:** `nested-claude-guard/` (PreToolUse hook blocks non-isolated `claude`; `claude-sub` is the safe way). **Safety net:** `claude-tg-watchdog` restarts the unit when `bot.pid` is dead. |
| **B** — "random" restarts | bot restarts with no clear cause | **Memory caps** (`20-resources.conf`) stop OOM; **crash-tail** (`30-crashtail.conf` + script) records exit code + log tail so every restart is explainable; journald already persistent. |

## Files

```
systemd/claude-tg@.service.d/20-resources.conf   MemoryHigh/Max, OOMPolicy, CPU/IO weight
systemd/claude-tg@.service.d/30-crashtail.conf   ExecStopPost -> crashtail
systemd/claude-tg-watchdog.service|.timer        poller-liveness watchdog (~20s)
bin/claude-tg-watchdog                            restart unit if bot.pid dead while active
bin/claude-tg-crashtail                           capture exit code + session tail on stop
nested-claude-guard/block-nested-claude.py        PreToolUse hook (blocks non-isolated claude)
nested-claude-guard/claude-sub + empty-mcp.json   safe nested-claude wrapper
nested-claude-guard/settings-hook-snippet.json    the hook stanza to merge (operator-applied)
nested-claude-guard/test_guard.py                 19-case self-test (all pass)
apply.sh / verify.sh                              idempotent install / exit-criteria check
```

## How to apply (operator, as root)

```bash
cd stabilization
sudo ./apply.sh          # installs drop-ins, scripts, enables watchdog timer; restarts NO bots
./verify.sh              # checks the M0 exit criteria
```

Drop-ins (memory caps, crash-tail) take effect on each bot's **next restart**.
To apply now without waiting, restart bots one at a time during idle:
`graceful-restart-bot <user>`.

### Manual step (AgentShield-protected — operator only)

`.hooks.PreToolUse` is a JSON path **inside** each bot's
`/home/<user>/.claude/settings.json` — not a separate file. Use the idempotent
merger (run as root); it appends the guard to the existing `Bash` matcher
(alongside shellfirm), backs up first, and is safe to re-run:

```bash
cd nested-claude-guard
./wire-guard.py --dry-run /home/vitaliy/.claude/settings.json   # preview
./wire-guard.py /home/vitaliy/.claude/settings.json             # one bot (pilot)
./wire-guard.py /home/*/.claude/settings.json                   # all bots
```

`settings-hook-snippet.json` is just the stanza for reference if you prefer to
merge by hand. The guard script is installed at
`/usr/local/share/claude-guard/block-nested-claude.py` by `apply.sh`.

If AgentShield rolls the edit back, re-baseline/approve it via the security-stack
tooling before relying on the guard.

## Exit criteria (from doc 01)

- [ ] `claude -p` / nested `claude` cannot touch the channel (guard wired) **and** watchdog restarts a dead poller within ~30s on any other failure.
- [ ] Restarts are rare and **explainable** (crash-tail records code/cause per restart).
- [ ] Memory is capped; no OOM deaths of the box.
- [ ] Secrets flagged for rotation (handled in the secrets phase, `../docs/04-…`).

## Notes / carry-forward
- `claude-tg-watchdog` is the same supervisor the target runtime keeps for
  `claude-pod@` (doc 08) — built once here, reused.
- During a future per-user **cutover**, the watchdog must not fight the
  stop→start window; add a cutover guard (skip flag) when M3 lands.
- Memory caps are starting values for a 12 GB / 8-bot box; they become
  per-tenant `platform.yaml` values in the target build.
