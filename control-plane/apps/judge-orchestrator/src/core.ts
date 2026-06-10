// The judging decision, independent of transport (HTTP) and queue (BullMQ) so it
// can be unit/smoke-tested directly. Order of operations enforces the spec:
//   1. cache lookup (content-hash dedup) — a hit is FREE, no LLM call.
//   2. circuit breaker gate — if open, fail-closed (verdict=error) with NO call.
//   3. single-pass LLM judge — one call, budgeted; persist verdict to cache.
// Recursion is structurally impossible here: judgeOne never calls /judge and the
// LLM is instructed it is terminal (see judge-llm.ts SYSTEM_PROMPT).
import type { JudgeRequest } from "@fleet/shared";
import type { CircuitBreaker } from "./breaker.js";
import type { VerdictCacheLike } from "./cache.js";
import type { JudgeFn } from "./judge-llm.js";
import type { Config } from "./config.js";

export interface JudgeDeps {
  cfg: Config;
  cache: VerdictCacheLike;
  breaker: CircuitBreaker;
  // Injected so tests can stub the LLM leg; default wired to judgeWithLlm.
  judge: JudgeFn;
}

export interface JudgeResult {
  verdict: "pass" | "fail" | "error";
  severity: string | null;
  cacheHit: boolean;
  reportRef: string | null;
}

export async function judgeOne(
  deps: JudgeDeps,
  req: JudgeRequest,
  content: string,
): Promise<JudgeResult> {
  const { cfg, cache, breaker, judge } = deps;
  const mv = cfg.modelVersion;

  const cached = await cache.get(req.artifactHash, req.rulesetVersion, mv);
  if (cached) {
    return { verdict: cached.verdict, severity: cached.severity, cacheHit: true, reportRef: cached.reportRef };
  }

  // Cache miss → an actual judge call is needed. Gate on the breaker first.
  if (!breaker.canRequest()) {
    return { verdict: "error", severity: null, cacheHit: false, reportRef: "circuit-open" };
  }

  try {
    const outcome = await judge(cfg, {
      kind: req.kind,
      artifactHash: req.artifactHash,
      contentRef: req.contentRef,
      content,
    });
    breaker.recordSuccess();
    await cache.set(req.artifactHash, req.kind, req.rulesetVersion, mv, {
      verdict: outcome.verdict,
      severity: outcome.severity,
      reportRef: outcome.report,
    });
    return { verdict: outcome.verdict, severity: outcome.severity, cacheHit: false, reportRef: outcome.report };
  } catch (err) {
    breaker.recordFailure();
    return {
      verdict: "error",
      severity: null,
      cacheHit: false,
      reportRef: (err as Error).message.slice(0, 200),
    };
  }
}
