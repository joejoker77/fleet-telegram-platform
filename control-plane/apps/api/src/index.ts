// @fleet/api — Mini App backend + public API (Fastify). M1 surface: initData
// auth → POST /auth/session, GET /me. Endpoints from later milestones return 501.
import Fastify from "fastify";
import { Redis } from "ioredis";
import { eq } from "drizzle-orm";
import { authSessionRequest, type MeResponse } from "@fleet/shared";
import { getDb, getPool, schema } from "@fleet/db";
import { loadConfig } from "./config.js";
import { verifyInitData, InitDataError } from "./initdata.js";
import { issueSession, verifySession } from "./auth.js";
import { sendAudit } from "./audit.js";

const config = loadConfig();
const app = Fastify({ logger: { name: "api" } });
const redis = new Redis(config.redisUrl, { maxRetriesPerRequest: 3 });
const db = getDb();

app.get("/healthz", async () => ({ ok: true }));

// POST /auth/session — verify Telegram initData, resolve the tenant, issue a JWT.
app.post("/auth/session", async (req, reply) => {
  const body = authSessionRequest.safeParse(req.body);
  if (!body.success) return reply.code(400).send({ error: "invalid body" });

  let verified;
  try {
    verified = verifyInitData(body.data.initData, config.botToken, config.initDataMaxAgeSeconds);
  } catch (err) {
    if (err instanceof InitDataError) return reply.code(401).send({ error: err.message });
    throw err;
  }

  const rows = await db
    .select({ id: schema.users.id, status: schema.users.status })
    .from(schema.users)
    .where(eq(schema.users.telegramUserId, verified.telegramUserId))
    .limit(1);
  const user = rows[0];
  if (!user) return reply.code(403).send({ error: "no tenant for this Telegram user" });
  if (user.status === "suspended" || user.status === "deleted") {
    return reply.code(403).send({ error: `tenant ${user.status}` });
  }

  const { token, expiresAt } = await issueSession(redis, config.jwtSecret, user.id, config.jwtTtlSeconds);
  await sendAudit(config.auditSocket, {
    userId: user.id,
    kind: "auth.session",
    actor: `tg:${verified.telegramUserId}`,
    payload: { username: verified.user.username ?? null },
  });
  return reply.send({ token, expiresAt: expiresAt.toISOString() });
});

// GET /me — profile for the authenticated tenant.
app.get("/me", async (req, reply) => {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return reply.code(401).send({ error: "missing bearer token" });

  let sub: string;
  try {
    ({ sub } = await verifySession(redis, config.jwtSecret, token));
  } catch {
    return reply.code(401).send({ error: "invalid or expired session" });
  }

  const rows = await db
    .select({
      telegramUserId: schema.users.telegramUserId,
      osUsername: schema.users.osUsername,
      role: schema.users.role,
      isAdmin: schema.users.isAdmin,
      status: schema.users.status,
      tier: schema.subscriptions.tier,
    })
    .from(schema.users)
    .leftJoin(schema.subscriptions, eq(schema.subscriptions.userId, schema.users.id))
    .where(eq(schema.users.id, sub))
    .limit(1);
  const u = rows[0];
  if (!u) return reply.code(404).send({ error: "tenant not found" });

  const me: MeResponse = {
    telegramUserId: u.telegramUserId,
    osUsername: u.osUsername,
    role: u.role,
    isAdmin: u.isAdmin,
    status: u.status,
    tier: u.tier ?? null,
  };
  return reply.send(me);
});

// Endpoints scheduled for later milestones (fs/build/registry/usage/sessions/
// approvals/live → M5/M6/M8). Declared so the surface is explicit and callers
// get a clear 501 rather than a 404.
// GET /usage — per-tenant token usage (from usage_records, fed by the metering
// hook → audit-collector). Tokens only (flat subscription = no $).
app.get("/usage", async (req, reply) => {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return reply.code(401).send({ error: "missing bearer token" });
  let sub: string;
  try {
    ({ sub } = await verifySession(redis, config.jwtSecret, token));
  } catch {
    return reply.code(401).send({ error: "invalid or expired session" });
  }

  const rows = await db
    .select({
      window: schema.usageRecords.window,
      tokens: schema.usageRecords.tokens,
      model: schema.usageRecords.model,
    })
    .from(schema.usageRecords)
    .where(eq(schema.usageRecords.userId, sub));

  let totalTokens = 0;
  const byModel: Record<string, number> = {};
  const byWindow: Record<string, number> = {};
  for (const r of rows) {
    const t = r.tokens ?? 0;
    totalTokens += t;
    if (r.model) byModel[r.model] = (byModel[r.model] ?? 0) + t;
    if (r.window) byWindow[r.window] = (byWindow[r.window] ?? 0) + t;
  }
  return reply.send({ records: rows.length, totalTokens, byModel, byWindow });
});

for (const route of ["/fs/tree", "/fs/file", "/registry/items", "/sessions", "/approvals"] as const) {
  app.get(route, async (_req, reply) =>
    reply.code(501).send({ error: "not implemented in M1", route }),
  );
}

async function main(): Promise<void> {
  await app.listen({ port: config.port, host: config.host });
}

const shutdown = async () => {
  await app.close();
  redis.disconnect();
  await getPool().end();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

main().catch((err) => {
  app.log.fatal({ err }, "api failed to start");
  process.exit(1);
});
