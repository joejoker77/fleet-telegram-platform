// @fleet/judge-orchestrator — the single LLM-as-judge entry point for the M4
// artifact scanners (docs 09-security-stack.md). Event-driven ONLY (called by the
// scanners on save/publish/import) — there is no timer, cron, or polling loop
// here, honouring the hard "zero recurring LLM calls" rule. Every request and
// every verdict is written to the tamper-resistant audit chain.
import fs from "node:fs";
import Fastify from "fastify";
import { Redis } from "ioredis";
import {
  judgeRequest,
  type JudgeRequest,
  type JudgeResponse,
  JUDGE_REQUEST_KIND,
  JUDGE_VERDICT_KIND,
} from "@fleet/shared";
import { getPool } from "@fleet/db";
import { loadConfig } from "./config.js";
import { sendAudit } from "./audit.js";
import { CircuitBreaker } from "./breaker.js";
import { VerdictCache } from "./cache.js";
import { judgeWithLlm } from "./judge-llm.js";
import { startJudgeQueue } from "./queue.js";
import type { JudgeResult } from "./core.js";

const cfg = loadConfig();
const app = Fastify({ logger: { name: "judge-orchestrator" } });
const redis = new Redis(cfg.redisUrl, { maxRetriesPerRequest: 3 });
const cache = new VerdictCache(redis, cfg.verdictTtlSeconds);
const breaker = new CircuitBreaker(cfg.breakerThreshold, cfg.breakerCooldownMs);

function auditVerdict(req: JudgeRequest, r: JudgeResult): void {
  void sendAudit(cfg.auditSocket, {
    userId: req.userId,
    kind: JUDGE_VERDICT_KIND,
    actor: req.actor,
    payload: {
      artifactHash: req.artifactHash,
      kind: req.kind,
      rulesetVersion: req.rulesetVersion,
      modelVersion: cfg.modelVersion,
      verdict: r.verdict,
      severity: r.severity,
      cacheHit: r.cacheHit,
    },
  });
}

// The queue owns the authoritative judge run; it emits the verdict audit event
// for jobs it executes (so a coalesced duplicate doesn't double-record).
// Production uses the real LLM judge. A stub (JUDGE_STUB=pass|fail) swaps it for
// a deterministic, zero-cost verdict so the cache_hit/breaker acceptance can run
// without any upstream call. The stub is loud in the logs so it can't be left on.
const judgeFn: typeof judgeWithLlm = cfg.stub
  ? async () => ({ verdict: cfg.stub as "pass" | "fail", severity: null, report: `stub:${cfg.stub}` })
  : judgeWithLlm;
if (cfg.stub) app.log.warn({ stub: cfg.stub }, "JUDGE_STUB active — NOT calling the real LLM judge");

const queue = startJudgeQueue(cfg, { cfg, cache, breaker, judge: judgeFn }, auditVerdict);

// Resolve the artifact + deterministic pre-scan report the scanner staged.
//   inline:<text>  — content carried directly (tests / small payloads)
//   redis:<key>    — content stashed in Redis by the scanner
//   <path>         — a file the orchestrator can read (shared staging dir)
async function resolveContent(contentRef: string): Promise<string> {
  if (contentRef.startsWith("inline:")) return contentRef.slice("inline:".length);
  if (contentRef.startsWith("redis:")) {
    const v = await redis.get(contentRef.slice("redis:".length));
    if (v == null) throw new Error(`content_ref redis key not found: ${contentRef}`);
    return v;
  }
  return fs.promises.readFile(contentRef, "utf8");
}

app.get("/healthz", async () => ({ ok: true, breaker: breaker.state() }));

app.post("/judge", async (req, reply) => {
  const parsed = judgeRequest.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: "invalid judge request", detail: parsed.error.flatten() });
  }
  const jr = parsed.data;

  void sendAudit(cfg.auditSocket, {
    userId: jr.userId,
    kind: JUDGE_REQUEST_KIND,
    actor: jr.actor,
    payload: { artifactHash: jr.artifactHash, kind: jr.kind, rulesetVersion: jr.rulesetVersion },
  });

  // Fast path: a cache hit is the dedup guarantee — instant, no queue, no LLM.
  const cached = await cache.get(jr.artifactHash, jr.rulesetVersion, cfg.modelVersion);
  if (cached) {
    const result: JudgeResult = {
      verdict: cached.verdict,
      severity: cached.severity,
      cacheHit: true,
      reportRef: cached.reportRef,
    };
    auditVerdict(jr, result);
    return reply.send(toResponse(result));
  }

  // Miss → resolve content + enqueue (coalesced by job id) and await the verdict.
  let content: string;
  try {
    content = await resolveContent(jr.contentRef);
  } catch (err) {
    return reply.code(422).send({ error: `could not resolve content_ref: ${(err as Error).message}` });
  }

  try {
    const result = await queue.enqueueAndWait(jr, content);
    return reply.send(toResponse(result));
  } catch (err) {
    // Queue/judge timeout or infra error → fail-closed (verdict=error).
    app.log.error({ err }, "judge job failed");
    const result: JudgeResult = { verdict: "error", severity: null, cacheHit: false, reportRef: "judge-timeout-or-infra" };
    auditVerdict(jr, result);
    return reply.code(503).send(toResponse(result));
  }
});

function toResponse(r: JudgeResult): JudgeResponse {
  return { verdict: r.verdict, severity: r.severity, cacheHit: r.cacheHit, reportRef: r.reportRef };
}

async function main(): Promise<void> {
  await app.listen({ host: cfg.host, port: cfg.port });
}

const shutdown = () => {
  Promise.allSettled([queue.close(), app.close(), redis.quit(), getPool().end()]).finally(() =>
    process.exit(0),
  );
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

main().catch((err) => {
  app.log.fatal({ err }, "judge-orchestrator failed to start");
  process.exit(1);
});
