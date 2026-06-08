# ADR-001 — Model access: first-party Claude Code per tenant (no LiteLLM in the model path)

- **Status:** Accepted — 2026-06-08
- **Supersedes:** invariant #4 in `upgrade/06-build-overview.md`; the LiteLLM
  gateway + blocking Spike S1 sections in `upgrade/08-runtime-and-gateways.md`;
  the `ANTHROPIC_BASE_URL=…litellm…` line in the user Containerfile.
- **Scope:** vitaliy pilot (per the fleet-platform pilot rule).

## Context

The original plan's invariant #4 was "model access = Anthropic subscription
seat-per-user **behind LiteLLM**", routed via `ANTHROPIC_BASE_URL` →
LiteLLM → Anthropic, with LiteLLM providing per-user metering, virtual keys,
budgets and limit-throttling. This was explicitly flagged as a load-bearing,
**unproven** assumption gated by blocking Spike **S1**.

S1.0 reconnaissance (2026-06-08) found:

- On **2026-04-04** Anthropic **blocked Pro/Max subscription quotas from being
  used through third-party harnesses/proxies**; OAuth auth is restricted to
  first-party clients (Claude Code CLI, claude.ai, Desktop, Cowork, Cursor).
  Enforced by request fingerprinting; rolled out to all third-party harnesses
  within weeks (so fully in force by now).
- Anthropic's legal policy explicitly forbids third-party developers from
  "routing requests through Free/Pro/Max plan credentials on behalf of their
  users"; products must use **API key** auth. Evasion proxies exist but are
  ToS-violating, cat-and-mouse, and **account-ban risk** — unacceptable for a
  production fleet.
- Confirmed by the operator (Dmitrii): the ban risk is specifically about
  (1) reselling/routing Claude as a third-party service, and (2) **sharing one
  subscription across multiple people**. Our model is neither — see Decision.

No server test was run: attempting to route a subscription token through a
proxy could itself flag/ban the account. Recon was conclusive → **S1 = NO-GO**
for subscription-behind-LiteLLM.

## Decision

**Option A — per-tenant first-party Claude Code, with NO LiteLLM (or any proxy)
in the model path.**

Our model is **1 human = 1 bot = 1 linux user = 1 Claude subscription**, used
only by that person. Each tenant runs the **official Claude Code CLI** on their
own subscription and is reached over Telegram (an official Anthropic channel).
We are not a third-party harness, we do not resell/route Claude, and we never
share one subscription across people — so the April-2026 restriction and the
ban patterns do not apply to us. Inserting LiteLLM in front of the subscription
is the **one thing that would** turn us into the prohibited third-party router,
so it is explicitly excluded.

## Consequences

- **LiteLLM is removed from the mandatory model path.** The user Containerfile
  does **not** set `ANTHROPIC_BASE_URL`; Claude Code talks directly to
  `api.anthropic.com` with its own subscription OAuth.
- **Per-user metering** is derived from Claude Code's own usage data + our
  append-only audit (event-driven hook, e.g. PostToolUse/Stop — **no recurring
  LLM calls**), written to `usage_records` / surfaced at `/usage`. Per-user
  attribution is free because each tenant is already a separate subscription
  account; centralized virtual-keys are unnecessary.
- **Network egress** (nftables, default-deny) allows **`api.anthropic.com`
  directly** for the model, instead of routing to a LiteLLM IP. OneCLI (secrets)
  + Composio/Exa whitelist + controlled DNS remain as before.
- **No gateway-enforced dollar budgets / custom rate caps.** The ceiling is
  Anthropic's own subscription rate limits (5-hour window + weekly caps),
  enforced upstream. If a tenant ever needs hard custom budgets, that is the
  **optional Option B** below — not the baseline.
- Everything else in the security perimeter stands: rootless-Podman runtime,
  hardening, OneCLI secrets gateway, nftables egress default-deny, audit,
  shellfirm/AgentShield/scanners.

### Option B (held in reserve, not built in M2)

For any tenant that genuinely needs hard budgets / virtual-keys / multi-provider
routing, use **Anthropic API keys behind LiteLLM** — LiteLLM's sanctioned,
native use case (ToS-clean), accepting metered $/token economics. This is an
opt-in upgrade, not the fleet baseline.
