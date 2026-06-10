// M4.1 HTTP acceptance for the Judge Orchestrator — proves the headline spec
// criterion at the API level with ZERO LLM spend (run against a JUDGE_STUB=pass
// instance): the same artifact judged twice → the 2nd call is a cache_hit, so the
// judge runs at most once per (artifact, ruleset, model). Breaker + fail-closed
// are covered by `pnpm --filter @fleet/judge-orchestrator smoke` (unit level).
import { randomBytes } from "node:crypto";

const BASE = process.env.JUDGE_URL ?? "http://127.0.0.1:8091";
const hash = randomBytes(32).toString("hex"); // unique per run → clean dedup test

async function judge() {
  const res = await fetch(`${BASE}/judge`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      artifactHash: hash,
      kind: "skill",
      contentRef: "inline:m4.1 acceptance artifact",
      rulesetVersion: "r1",
      actor: "m4-accept",
      userId: null,
    }),
  });
  if (!res.ok) throw new Error(`POST /judge -> ${res.status}: ${await res.text()}`);
  return res.json();
}

const fails = [];
const check = (cond, msg) => (cond ? console.log(`  ✓ ${msg}`) : (fails.push(msg), console.error(`  ✗ ${msg}`)));

const r1 = await judge();
const r2 = await judge();
check(r1.cacheHit === false, "first judge of a fresh artifact is a miss (cacheHit=false)");
check(["pass", "fail"].includes(r1.verdict), `first verdict is pass/fail (got ${r1.verdict})`);
check(r2.cacheHit === true, "second identical judge is a cache_hit (cacheHit=true)");
check(r2.verdict === r1.verdict, "cached verdict matches the original");

console.log(`\nM4.1 judge acceptance: ${fails.length ? `FAILED (${fails.length})` : "OK"}`);
process.exit(fails.length ? 1 : 0);
