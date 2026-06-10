# @fleet/judge-orchestrator (M4 / WP3)

The **single LLM-as-judge entry point** for the artifact scanners (L4 MCP, L5
Skill, L6 AgentShield/Promptfoo — WP4/WP5). Implements the Judge Orchestrator
spec in `docs/09-security-stack.md`.

```
POST /judge { artifactHash, kind, contentRef, rulesetVersion, actor, userId }
  -> 200 { verdict: pass|fail|error, severity, cacheHit, reportRef }
GET  /healthz -> { ok, breaker: closed|open|half-open }
```

## How it satisfies the spec

| Spec requirement | Implementation |
|---|---|
| Content-hash dedup | `artifactHash` (sha256) is the cache key; a hit returns instantly with no LLM call |
| Verdict cache (TTL + invalidation) | Redis hot tier (`verdictTtlSeconds`) + Postgres `judge_verdicts` durable tier; key = (hash, rulesetVersion, modelVersion) — bump either to invalidate |
| Single-pass | one `max_tokens`-budgeted call per artifact; no iterative refinement |
| Queue + rate-limit | BullMQ worker with `{ max, duration }` limiter; job-id = dedup key coalesces concurrent duplicates onto ONE run |
| Circuit breaker | opens after N consecutive judge failures → callers get `verdict=error` (scanners **fail-closed**); half-open trial after cooldown |
| No recursion / self-judging | the judge never calls `/judge`; the LLM is prompted that it is terminal |
| Budget ceiling | `budgetMaxOutputTokens`; a `finish_reason=length` is treated as failure (fail-closed) |
| All verdicts audited | every `judge.request` + `judge.verdict` is written to the tamper-resistant audit-collector |
| **Zero recurring LLM calls** | event-driven ONLY — no timer/cron/poll in this service; the LLM is hit solely on a cache-miss `POST /judge` from a scanner |

## Secrets

The judge LLM key (the **$10/week-capped OpenRouter key**, see
`reference_openrouter_llm_judge_key`) is read from `OPENROUTER_API_KEY_FILE`
(a podman/systemd credential), never a committed file or plain env in a unit.
**Open decision for Vitaliy:** keep it as a podman secret (matches cp-api's
bot/jwt secret handling) vs. move it into the OneCLI vault and route cp-judge's
egress through the proxy. Defaulted to podman-secret for now; flagged in the
deploy script.

## Run / verify

- `pnpm --filter @fleet/judge-orchestrator smoke` — self-contained logic proof
  (dedup, cache_hit, breaker, fail-closed) with no LLM/Redis/PG. **11/11 green.**
- `install/m4.1-judge-orchestrator.sh` (root) — pnpm install, migrate
  `judge_verdicts`, bring up `cp-judge`, run the HTTP acceptance with `JUDGE_STUB`
  (zero LLM spend): same artifact twice → 2nd `cacheHit=true`; breaker opens under
  forced failure.
- `install/m4.1-rollback.sh` (root) — remove `cp-judge` + the secret (table left;
  drop manually if desired).
