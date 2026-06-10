// Runtime config for @fleet/judge-orchestrator. The LLM judge key is read from a
// mounted secret file (…_FILE) when present, else env — wired by the installer
// as a podman/systemd credential, NEVER committed or put in a plain env file
// (see feedback_no_plaintext_secrets_use_onecli). The key is the $10/week-capped
// OpenRouter judge key (reference_openrouter_llm_judge_key), used ONLY on a
// cache-miss judge call — there is no scheduled/recurring use.
import fs from "node:fs";

function fileOrEnv(envName: string, fallback?: string): string {
  const filePath = process.env[`${envName}_FILE`];
  if (filePath) return fs.readFileSync(filePath, "utf8").trim();
  const v = process.env[envName];
  if (v !== undefined) return v;
  if (fallback !== undefined) return fallback;
  throw new Error(`${envName} is not set`);
}

export interface Config {
  port: number;
  host: string;
  redisUrl: string;
  auditSocket: string;
  // The judge model + a version string that participates in the cache key. Bump
  // modelVersion (or rulesetVersion per request) to invalidate cached verdicts.
  judgeModel: string;
  modelVersion: string;
  openrouterBaseUrl: string;
  openrouterKey: string;
  // Single-pass budget ceiling per judge call (output tokens). Exceed → abort.
  budgetMaxOutputTokens: number;
  // Rate-limit the judge worker (BullMQ limiter): at most `rateMax` jobs per
  // `rateDurationMs`. Protects the capped key + the upstream.
  rateMax: number;
  rateDurationMs: number;
  concurrency: number;
  // Circuit breaker: open after `breakerThreshold` consecutive judge failures;
  // stay open for `breakerCooldownMs`, then half-open (one trial).
  breakerThreshold: number;
  breakerCooldownMs: number;
  // Hot-cache TTL (Redis). The PG judge_verdicts row is the durable tier.
  verdictTtlSeconds: number;
  // Max wall-clock a /judge HTTP caller waits for a queued verdict.
  judgeTimeoutMs: number;
  // Zero-spend stub for acceptance tests/ops: "pass"|"fail" swaps the real LLM
  // leg for a deterministic verdict so the dedup/cache_hit + breaker behaviour can
  // be exercised with NO upstream call. Unset (null) in production.
  stub: "pass" | "fail" | null;
}

export function loadConfig(): Config {
  return {
    port: Number(process.env.PORT ?? 8090),
    host: process.env.HOST ?? "127.0.0.1",
    redisUrl: process.env.REDIS_URL ?? "redis://127.0.0.1:6380",
    auditSocket: process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock",
    judgeModel: process.env.JUDGE_MODEL ?? "anthropic/claude-haiku-4-5",
    modelVersion: process.env.JUDGE_MODEL_VERSION ?? "v1",
    openrouterBaseUrl: process.env.OPENROUTER_BASE_URL ?? "https://openrouter.ai/api/v1",
    // Empty fallback so the service can boot for cache-only / dry-run smoke tests
    // without a key; a real judge call with no key returns verdict=error (fail-closed).
    openrouterKey: fileOrEnv("OPENROUTER_API_KEY", ""),
    budgetMaxOutputTokens: Number(process.env.JUDGE_BUDGET_MAX_OUTPUT_TOKENS ?? 1024),
    rateMax: Number(process.env.JUDGE_RATE_MAX ?? 30),
    rateDurationMs: Number(process.env.JUDGE_RATE_DURATION_MS ?? 60_000),
    concurrency: Number(process.env.JUDGE_CONCURRENCY ?? 4),
    breakerThreshold: Number(process.env.JUDGE_BREAKER_THRESHOLD ?? 5),
    breakerCooldownMs: Number(process.env.JUDGE_BREAKER_COOLDOWN_MS ?? 30_000),
    verdictTtlSeconds: Number(process.env.JUDGE_VERDICT_TTL_SECONDS ?? 86_400),
    judgeTimeoutMs: Number(process.env.JUDGE_TIMEOUT_MS ?? 30_000),
    stub: process.env.JUDGE_STUB === "pass" ? "pass" : process.env.JUDGE_STUB === "fail" ? "fail" : null,
  };
}
