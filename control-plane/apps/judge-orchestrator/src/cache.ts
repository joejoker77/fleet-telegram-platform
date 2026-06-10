// Two-tier verdict cache backing the dedup guarantee (docs 09: "контент-хеш
// дедупликация", "кэш вердиктов с TTL и инвалидацией по версии правил/модели").
// Key = (artifactHash, rulesetVersion, modelVersion). Redis is the hot tier
// (TTL); Postgres judge_verdicts is the durable tier (survives a Redis flush).
// A hit at EITHER tier means NO LLM call — this is what keeps the judge from
// re-scoring unchanged content (the failure mode behind the $360 incident).
import type { Redis } from "ioredis";
import { and, eq } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import type { JudgeKind, JudgeVerdict } from "@fleet/shared";

export interface CachedVerdict {
  verdict: JudgeVerdict;
  severity: string | null;
  reportRef: string | null;
}

// The cache surface the core depends on — lets tests inject an in-memory fake
// without Redis/Postgres.
export interface VerdictCacheLike {
  get(artifactHash: string, rulesetVersion: string, modelVersion: string): Promise<CachedVerdict | null>;
  set(
    artifactHash: string,
    kind: JudgeKind,
    rulesetVersion: string,
    modelVersion: string,
    v: CachedVerdict,
  ): Promise<void>;
}

function redisKey(artifactHash: string, rulesetVersion: string, modelVersion: string): string {
  return `judge:${artifactHash}:${rulesetVersion}:${modelVersion}`;
}

export class VerdictCache implements VerdictCacheLike {
  constructor(
    private readonly redis: Redis,
    private readonly ttlSeconds: number,
  ) {}

  async get(
    artifactHash: string,
    rulesetVersion: string,
    modelVersion: string,
  ): Promise<CachedVerdict | null> {
    const rk = redisKey(artifactHash, rulesetVersion, modelVersion);
    const hot = await this.redis.get(rk);
    if (hot) {
      try {
        return JSON.parse(hot) as CachedVerdict;
      } catch {
        /* corrupt entry — fall through to durable tier */
      }
    }
    const rows = await getDb()
      .select({
        verdict: schema.judgeVerdicts.verdict,
        severity: schema.judgeVerdicts.severity,
        reportRef: schema.judgeVerdicts.reportRef,
      })
      .from(schema.judgeVerdicts)
      .where(
        and(
          eq(schema.judgeVerdicts.artifactHash, artifactHash),
          eq(schema.judgeVerdicts.rulesetVersion, rulesetVersion),
          eq(schema.judgeVerdicts.modelVersion, modelVersion),
        ),
      )
      .limit(1);
    const row = rows[0];
    if (!row) return null;
    const v: CachedVerdict = { verdict: row.verdict, severity: row.severity, reportRef: row.reportRef };
    // re-warm the hot tier
    await this.redis.set(rk, JSON.stringify(v), "EX", this.ttlSeconds);
    return v;
  }

  // Persist a fresh verdict to both tiers. The PG upsert is keyed by the unique
  // (artifact_hash, ruleset_version, model_version) index. `error` verdicts are
  // NOT persisted to PG (transient — should be retried), only the hot tier is
  // skipped too so a recovered judge can re-decide.
  async set(
    artifactHash: string,
    kind: JudgeKind,
    rulesetVersion: string,
    modelVersion: string,
    v: CachedVerdict,
  ): Promise<void> {
    if (v.verdict === "error") return;
    const rk = redisKey(artifactHash, rulesetVersion, modelVersion);
    await this.redis.set(rk, JSON.stringify(v), "EX", this.ttlSeconds);
    await getDb()
      .insert(schema.judgeVerdicts)
      .values({
        artifactHash,
        kind,
        rulesetVersion,
        modelVersion,
        verdict: v.verdict,
        severity: v.severity,
        reportRef: v.reportRef,
      })
      .onConflictDoNothing({
        target: [
          schema.judgeVerdicts.artifactHash,
          schema.judgeVerdicts.rulesetVersion,
          schema.judgeVerdicts.modelVersion,
        ],
      });
  }
}
