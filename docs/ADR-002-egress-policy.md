# ADR-002 — Egress policy: proxy-only + audited, NOT a host whitelist

- **Status:** Accepted — 2026-06-08 (Vitaliy)
- **Supersedes:** the "external APIs only via OneCLI/**whitelist**" wording in
  the M2 acceptance criteria of `upgrade/08-runtime-and-gateways.md`.

## Decision

A tenant container's egress is restricted to **"only via the audited OneCLI
proxy"** — direct internet is blocked (nftables default-deny + UFW), and all
outbound traffic flows through the single OneCLI chokepoint. There is **no
strict per-host allowlist.** OneCLI is default-allow pass-through; specific
bad hosts can be blocked with `rules --action block` if ever needed.

## Rationale

- A strict per-host whitelist would **cage the user's bot** — Claude
  legitimately fetches arbitrary sites the user asks it to read/use (Exa
  results, docs, APIs, etc.). Enumerating an allowlist is impractical and
  hostile to the agent's purpose. (Vitaliy, 2026-06-08: "строгий whitelist
  хостов не нужен в принципе… это ограничение свободы действий для бота.")
- It also isn't expressible in OneCLI's model anyway: its rules only do
  `block`/`rate_limit` (no `allow` action).

## What IS enforced (the real guarantee)

1. **No direct internet** from the tenant container — nftables (`inet
   cl_egress`, default-deny) + the UFW allow only to the proxy port. The
   container can reach *nothing* except the OneCLI proxy.
2. **Single audited chokepoint** — all egress goes through OneCLI, which
   injects per-host secrets and can block specific hosts.
3. **Per-tenant isolation** — selective secret mode; an agent sees only its
   own secrets.

## Follow-up

Confirm OneCLI logs/audits **pass-through** egress (hosts with no configured
secret), so the "audited" property fully holds. Tracked, non-blocking for M2.
