# ADR-004 — Defense by risk boundary (where security checks belong)

- **Status:** Accepted — 2026-06-10 (Vitaliy, decision "(a)")
- **Supersedes:** the deploy-time judge gating wired into `deploy-mcp` / `deploy-skills`
  (M4 WP4) — removed as redundant. Reaffirms the scanner placement in
  `docs/09-security-stack.md` ("on save/publish/import").

## Context — what the user must be able to do (Vitaliy, 2026-06-10)

1. Pull MCP servers / skills / subagents / code from the internet for their own
   workflows.
2. Author MCP/skills/subagents in the built-in web IDE, and optionally publish to
   their own GitHub/GitLab **and** to the shared fleet repo (cross-user sharing).
3. Share their work with other fleet users.

We must protect **the user, our server, and all other fleet users** from both
careless and deliberately malicious code/prompts/MCPs — without caging the user.

## Decision — place each control at the boundary where its risk lives

**Boundary 1 — inside one tenant** (download / author / run for own use).
Risk: harm to the user themselves + our shared server.
Control = **containment, NOT pre-screening.** The user may pull arbitrary
artifacts (req. 1), so we do not scan-and-block every download (that both cages
the user and would burn LLM-judge calls). Instead the blast radius is bounded to
the user's own container: rootless Podman on a per-tenant uid, egress only via the
audited OneCLI proxy (ADR-002), shellfirm + deny-list on dangerous commands, the
settings-integrity guard (can't disable protections, ADR-003), per-tenant OneCLI
secret isolation, tamper-resistant audit, and auto-suspend on repeated abuse.
**No judge calls here.**

**Boundary 2 — the sharing boundary** (publish to the shared fleet repo → other
users will import it). Risk: harm to other fleet users.
Control = **the judge + scanners belong HERE** — event-driven on publish,
content-hash-cached, plus the CI signature-scanner on the shared repo's PRs. A
`fail` verdict → **inline Telegram approval** ("flagged X: <reason> — publish
anyway?"), decided in chat. Blocking is justified because the artifact leaves the
tenant. (Importing shared content is already vetted at publish + CI; a content-hash
cache hit means no re-judging.)

**Boundary 3 — guardian/model change.** Risk: integrity of the user's own bot.
Control = Promptfoo red-team **on the change event** (WP5), never scheduled.

## Why the deploy-time gate was wrong

`deploy-skills` / `deploy-mcp` deploy content that has **already** passed CI
(PR → signature-scanner → merge). Re-judging it at the deploy reconciler was
redundant, produced false positives (the legit `skill-author-selftest`, which
handles a PAT, was judged `fail/high` and uninstalled), and created a need for
file-based whitelists the Telegram user cannot manage. Removed.

## Anti-runaway (the $360 rule) is strengthened

The judge is **event-only** (publish/import/author), **content-hash deduplicated**
(an artifact is never judged twice), circuit-broken and budget-capped, with **no
timer anywhere that invokes an LLM**. Removing the deploy gate *reduces* judge
calls. (Ref: the 2026-05-22 incident — an LLM-judge looped idle every 15 min for a
day and cost $360.)

## Consequences

- Revert `deploy-skills`→v1 and `deploy-mcp`→v2.3 (`m4-revert-deploy-gates.sh`).
- The judge orchestrator (`cp-judge`) + `@fleet/scanners` stay as a **built,
  proven capability**; their blocking trigger + inline approval are wired at the
  **publish/import/author** boundary in **M5**.
- Containment controls (WP6 auto-suspend, WP7 settings-guard, egress, shellfirm)
  are unchanged — they are boundary-1 and correct.
- M4 is complete at the **capability** level; boundary-2 wiring is M5 scope.
