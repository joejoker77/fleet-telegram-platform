// Self-contained smoke test for the judge core — proves the M4 acceptance
// criteria WITHOUT a real LLM call, Redis, or Postgres (in-memory cache + a fake
// judge that counts calls). Run: pnpm --filter @fleet/judge-orchestrator smoke
//
// Asserts (docs 09, acceptance criteria):
//   1. dedup/cache_hit — same artifact twice → 2nd is cache_hit, judge called ONCE.
//   2. distinct artifacts are judged independently.
//   3. circuit breaker opens after N consecutive judge failures → fail-closed
//      (verdict=error) with NO further judge calls while open.
//   4. a judge throw (e.g. budget overrun / upstream error) → verdict=error
//      (fail-closed), never a silent pass.
import { CircuitBreaker } from "./breaker.js";
import type { VerdictCacheLike, CachedVerdict } from "./cache.js";
import { judgeOne, type JudgeDeps } from "./core.js";
import type { JudgeFn } from "./judge-llm.js";
import type { Config } from "./config.js";
import type { JudgeRequest } from "@fleet/shared";

class MemCache implements VerdictCacheLike {
  private m = new Map<string, CachedVerdict>();
  private k(h: string, r: string, mv: string) {
    return `${h}:${r}:${mv}`;
  }
  async get(h: string, r: string, mv: string): Promise<CachedVerdict | null> {
    return this.m.get(this.k(h, r, mv)) ?? null;
  }
  async set(h: string, _kind: unknown, r: string, mv: string, v: CachedVerdict): Promise<void> {
    if (v.verdict === "error") return;
    this.m.set(this.k(h, r, mv), v);
  }
}

const cfg = { modelVersion: "test-mv" } as Config;
let pass = 0;
let fail = 0;
function ok(cond: boolean, msg: string) {
  if (cond) {
    pass++;
    console.log(`  ✓ ${msg}`);
  } else {
    fail++;
    console.error(`  ✗ ${msg}`);
  }
}

function req(hash: string): JudgeRequest {
  return {
    artifactHash: hash,
    kind: "skill",
    contentRef: "inline:x",
    rulesetVersion: "r1",
    actor: "smoke",
    userId: null,
  };
}

async function main() {
  // ── 1 + 2: dedup / cache_hit ──
  {
    let calls = 0;
    const judge: JudgeFn = async () => {
      calls++;
      return { verdict: "pass", severity: null, report: "ok" };
    };
    const deps: JudgeDeps = { cfg, cache: new MemCache(), breaker: new CircuitBreaker(5, 1000), judge };
    const h = "a".repeat(64);
    const r1 = await judgeOne(deps, req(h), "content");
    const r2 = await judgeOne(deps, req(h), "content");
    ok(r1.cacheHit === false && r1.verdict === "pass", "first call is a miss (judged)");
    ok(r2.cacheHit === true && r2.verdict === "pass", "second identical call is a cache_hit");
    ok(calls === 1, "judge LLM called exactly ONCE for the duplicate (dedup holds)");

    const r3 = await judgeOne(deps, req("b".repeat(64)), "other");
    ok(r3.cacheHit === false && calls === 2, "a distinct artifact is judged independently");
  }

  // ── 3: circuit breaker opens, fail-closed, no calls while open ──
  {
    let calls = 0;
    const judge: JudgeFn = async () => {
      calls++;
      throw new Error("simulated judge degradation");
    };
    const breaker = new CircuitBreaker(3, 10_000);
    const deps: JudgeDeps = { cfg, cache: new MemCache(), breaker, judge };
    // 3 distinct artifacts each fail → breaker should open on the 3rd.
    for (let i = 0; i < 3; i++) {
      const r = await judgeOne(deps, req(String(i).padStart(64, "0")), "c");
      ok(r.verdict === "error" && !r.cacheHit, `failing judge #${i + 1} → verdict=error (fail-closed)`);
    }
    ok(breaker.state() === "open", "breaker is OPEN after threshold consecutive failures");
    const callsBefore = calls;
    const r = await judgeOne(deps, req("f".repeat(64)), "c");
    ok(r.verdict === "error" && r.reportRef === "circuit-open", "request while open → error, short-circuited");
    ok(calls === callsBefore, "NO judge call made while breaker is open");
  }

  // ── 4: judge throw → fail-closed (already covered above; explicit single-shot) ──
  {
    const judge: JudgeFn = async () => {
      throw new Error("budget overrun");
    };
    const deps: JudgeDeps = { cfg, cache: new MemCache(), breaker: new CircuitBreaker(5, 1000), judge };
    const r = await judgeOne(deps, req("e".repeat(64)), "c");
    ok(r.verdict === "error", "a judge exception never yields a silent pass");
  }

  console.log(`\njudge-orchestrator smoke: ${pass} passed, ${fail} failed`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error("smoke crashed:", err);
  process.exit(1);
});
