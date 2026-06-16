# Host-surface inventory — the "product out of the box" canon

**This is the canonical reference for productizing fleet-platform.** Principle (Vitaliy
2026-06-16): the repo must become a **product out of the box** — `install.sh` from the repo
installs only a **minimal, justified host-bootstrap**; *everything else* lives in the **pod image**,
the **control-plane** (cp-* containers), or **CI**, or is **eliminated**. No bespoke,
hand-placed host scripts. Today the host surface is heavily sprawled (`/usr/local/sbin` ~40,
`/usr/local/bin` ~40+, plus piles of `.bak`); this doc gives every fleet artifact a verdict.

> A repo install-script existing for something does NOT mean it's "productized" — many milestone
> scripts install **host** units/daemons. The verdict below is by the product lens (where it
> SHOULD live), not by "does a script exist".

## Verdict taxonomy
- **IMAGE** — belongs baked into the pod image (`runtime/image/...`).
- **CTRL-PLANE** — belongs in a control-plane container (cp-api / cp-* services).
- **CI** — belongs at PR-time (no `.github/` in the repo yet — a gap).
- **BOOTSTRAP** — must run on the host; justified; MUST be `install.sh`-managed from the repo.
- **ELIMINATE** — legacy host-runtime, dev scaffolding, deprecated, or `.bak` cruft.
- **EXTERNAL** — separate product/dependency (OneCLI vault, gateways) or third-party tool; out of scope.

## Target host end-state (what `install.sh` should leave on the host)
Only the **BOOTSTRAP** set: `claude-pod@.service` + `claude-pod-run`; the egress lock
(`cl-egress-forwarder` + nftables template + `cl-net`); the control-plane containers
(`cp-postgres`, `cp-redis`, `cp-api`, `cp-audit-collector`, `cp-judge`) + their secrets;
`cp-secretd` socket+daemon; the admin bridge (`host-sudo-broker` + per-admin key). Everything
else is image/control-plane/CI or gone. **No top-level `install.sh` exists yet — building it is
the productization capstone** (consolidate all `m*-*.sh` into it + `uninstall.sh`).

---

## A. ELIMINATE — legacy host-runtime (the `claude-tg@` era; pod replaces). Block-B teardown.
| Host artifact | Replaced by (product) |
|---|---|
| `claude-tg-launcher` (+8 `.bak`) | `runtime/image/platform/entrypoint.sh` (IMAGE) |
| `claude-tg-watchdog` + `.timer`/`.service`; `stabilization/bin/claude-tg-watchdog` | pod entrypoint supervisor loop (IMAGE). (M0 host watchdog is the host-era net; retires with `claude-tg@`.) |
| `claude-tg-crashtail` | pod crash/log handling (IMAGE) |
| `claude-tg@.service`, `claude-telegram.service` (umbrella) | `claude-pod@.service` |
| `claude_session_logger.{py,sh}` (+baks) | pod writes/rotates its own session logs (IMAGE) |
| `claude_creds_sync.sh` (+bak), `claude_creds_watch.sh`/`claude-creds-watch.service` | OneCLI vault (`m2.4-onecli-tenant.sh`) |
| `claude_oauth_refresh.sh` (+bak) | OneCLI/proxy-managed creds (verify pod refresh path) |
| `_tmux_inject`, `_tmux_peek`, `_tmux_peek2` | pod `session-ctl` (IMAGE) |
| `graceful-restart-bot` (old) | `graceful-restart-pod-bot` (A1, done) |
| `claude-ratelimit-watchdog.sh` | **GAP** — no product replacement; rate-limit handling deferred (M9+) |

## B. → CTRL-PLANE — deploy reconciliation (A2). Then ELIMINATE host.
| Host artifact | Target |
|---|---|
| `deploy-mcp` (+`.bak.v21`, `-experimental`), `deploy-skills` | A2: cp-api reconcile (`docs/10`). ELIMINATE host scripts. |
| `skill-deploy@`/`mcp-deploy@` `.service`+`.timer` | A2 reconcile trigger in control-plane. ELIMINATE host timers. |
| per-user SSH deploy keys (claude-bot-skills clone) | cp-api fetches over HTTPS via scoped token. ELIMINATE keys. |
| `fleet-skill-gate`, `mcp-install-gate`, `skill-install-gate` | deploy-time gate DEPRECATED (ADR-004); gating → publish/import boundary (M8, CTRL-PLANE) + CI. ELIMINATE host. |

## C. → IMAGE — settings integrity (the W1 correction).
| Host artifact | Target |
|---|---|
| `agentshield-settings-guard` (+`@.path`/`@.service`), `agentshield-settings-rebaseline`, `agentshield-prestate-commit`, `agentshield-rebaseline`, `agentshield-override`, `agentshield-gate` (+baks, `@.service`/`@.timer`) | **Pod owns settings integrity** via the `~/.claude` git-HEAD (already a git repo), enforced by the entrypoint (IMAGE). cp-api commits AUTHORIZED writes to HEAD. host golden `/var/lib/agentshield/golden/` + the host units ELIMINATE once moved. **This is a workstream (productize settings-guard).** |

## D. → CI (+ CTRL-PLANE) — scanners. (No `.github/` in repo yet = gap.)
| Host artifact | Target |
|---|---|
| `cisco-gate` (+bak), `mcp-scanner`, `mcp-scanner-gate` (+baks, `@.service`/`@.timer`), `skill-scanner`, `skill-scanner-gate` (+baks) | PR-time CI + `control-plane/packages/scanners`. ELIMINATE host gate timers. |
| `plugin-mcp-scan@`/`plugin-mcp-hash-scan` (local integrity timer) | out-of-band integrity → fold into IMAGE/host-bootstrap or ELIMINATE (decide). |
| `rebaseline-cisco.sh` | dev tool → ELIMINATE. |

## E. → CI / DEV-only — promptfoo / redteam (single canary, not per-user).
`run-promptfoo-cycle`, `promptfoo-cycle@.{service,timer}`, `run-redteam-scan`, `compare-promptfoo-runs`,
`count-redteam-progress`, `dump-pf-blob`, `list-pf-tables`, `show-*` (jailbreak/redteam/pf diagnostics),
`security-alerter` → promptfoo is a single-canary CI-ish thing (daria). Diagnostics are DEV/on-demand.
**Target: CI / dev-tooling; ELIMINATE from the host runtime.** `security-alerter` → CTRL-PLANE alert sink.

## F. → CTRL-PLANE — lifecycle (WP6 auto-suspend).
`auto-suspend-monitor` (+`@.service`/`@.timer`), `tenant-resume`, `quarantine-bot` → cp-api should own
suspend/resume/quarantine. Currently host timers. **Target: CTRL-PLANE; ELIMINATE host timers.**
(`quarantine-bot` may be a GAP — verify it exists in the product.)

## G. BOOTSTRAP — justified host components (keep, but `install.sh`-managed from repo).
| Host artifact | Why host |
|---|---|
| `claude-pod-run` + `claude-pod@.service` | launches/hardens the per-tenant pod (must be host systemd) |
| `cl-egress-forwarder.service` + `runtime/nftables/cl-egress.nft.tmpl` + `cl-net` | egress default-deny lock (host network) |
| `cp-secretd` + `@.service`/`.socket` | in-pod MCP token injection over a host socket |
| `host-sudo-broker` (+ `make-admin.sh`/`unmake-admin.sh`) | admin bridge — host gate is the point (audited forced-command) |
| cp-* control-plane containers + secrets (`m1.2`, `m1.5`, `m4.1` judge) | the control plane itself |

## H. IMAGE — already correctly in the product (keep; verify install.sh wires them)
`runtime/image/platform/bin/{composio-connect,composio-exec,composio-session,host-sudo,registry-publish}`;
`shellfirm` + `shellfirm-bot-wrapper` + `policy.yaml`; `block-nested-claude.py`; entrypoint-managed
session/tmux, log-rotation, liveness watchdog, MCP-approval seeding, checkpoints, code-server IDE.

## I. EXTERNAL / out of scope
`onecli` (separate self-hosted vault product), OneCLI/LiteLLM gateways, Caddy/reverse-proxy;
`composio-proxy`/`composio-mcp-bridge`/`composio-tunnel` (+services) → **review: likely superseded by
the OneCLI-injection path (M6); confirm then ELIMINATE if legacy**; third-party tools (`bun`, `cloudflared`,
`docker-compose`, `composer`, `ct2-*`, numpy/torch/pdf/playwright/fastapi/etc.); `drop-file`,
`setup-icloud-rclone`/`enable-icloud-mount` (small user-facing utilities — keep, install.sh-managed).

## J. CRUFT — delete now (no value)
All `*.bak*` under `/usr/local/{bin,sbin}`: `claude-tg-launcher.bak.*` (×8), `deploy-mcp.bak.v21`,
`mcp-set-secret.bak.v21`/`.v22`, `claude_session_logger.sh.bak.*`, `claude_creds_sync.sh.bak*`,
`claude_oauth_refresh.sh.bak.*`, `agentshield-gate.bak-phaseC`, `cisco-gate.bak.*`,
`mcp-scanner-gate.bak-*`, `skill-scanner-gate.bak-*`, `deploy-mcp-experimental`,
`agentshield-gate-experimental`, `__pycache__`.

---

## Productization workstreams this implies (beyond the per-bot migration)
1. **A2** — deploy → control-plane (in progress; `docs/10`).
2. **Settings-integrity → image** (the W1 correction) — pod owns `~/.claude` git-HEAD; retire host agentshield-*.
3. **Scanners → CI** — add `.github/workflows` to fleet-platform (none today).
4. **Lifecycle → control-plane** — auto-suspend/resume/quarantine into cp-api; retire host timers.
5. **`install.sh`/`uninstall.sh` capstone** — consolidate all `m*-*.sh`; the single deliverable.
6. **Block-B legacy teardown** — eliminate the `claude-tg@` host runtime + `.bak` cruft (see `project_fleet_dev_teardown`).

These are tracked together with the dev-teardown list in memory; this doc is the standing map.
