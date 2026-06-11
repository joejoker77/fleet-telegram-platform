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
import { registerFsRoutes } from "./fs-routes.js";
import { registerLiveRoutes } from "./live-routes.js";
import { registerApprovalRoutes } from "./approval-routes.js";
import { registerMcpRoutes } from "./mcp-routes.js";
import { applyMcpConnect, MCP_APPROVAL_KIND, type McpStanza } from "./mcp-gate.js";
import websocket from "@fastify/websocket";

const config = loadConfig();
const app = Fastify({ logger: { name: "api" } });
const redis = new Redis(config.redisUrl, { maxRetriesPerRequest: 3 });
const db = getDb();

await app.register(websocket);

app.get("/healthz", async () => ({ ok: true }));

// M5.1 authoring file API (boundary-1 — own .claude sandbox, audited, no judge).
registerFsRoutes(app, {
  redis,
  jwtSecret: config.jwtSecret,
  auditSocket: config.auditSocket,
  homeRoot: config.tenantHomeRoot,
});

// M5.4 LiveActivity: ws /live streams the tenant's audit events (Redis pub/sub
// fed by audit-collector).
registerLiveRoutes(app, { redis, redisUrl: config.redisUrl, jwtSecret: config.jwtSecret });

// M5.4b platform approvals: queue + answer from the Mini App; notify via main
// bot sendMessage (send-only, no second getUpdates consumer).
const approvalsDeps = {
  redis,
  redisUrl: config.redisUrl,
  jwtSecret: config.jwtSecret,
  auditSocket: config.auditSocket,
  botToken: config.botToken,
  botUsername: config.botUsername,
  miniappUrl: config.miniappUrl,
};
const mcpGateDeps = {
  homeRoot: config.tenantHomeRoot,
  judgeUrl: config.judgeUrl,
  auditSocket: config.auditSocket,
};
registerApprovalRoutes(app, approvalsDeps, {
  // M5.5: an allowed mcp.connect approval is applied synchronously in the
  // answer handler. The payload was authored by POST /mcp/connect; apply
  // re-validates it before touching tenant files.
  [MCP_APPROVAL_KIND]: async (row) => {
    const p = (row.payload ?? {}) as { name?: string; stanza?: McpStanza; osUsername?: string };
    if (typeof p.name !== "string" || typeof p.osUsername !== "string" || p.stanza === undefined) {
      return { ok: false, error: "malformed approval payload" };
    }
    // userId is enforced by answerApproval's owner check; resolve it from the DB row.
    const owner = await db
      .select({ id: schema.users.id })
      .from(schema.users)
      .where(eq(schema.users.osUsername, p.osUsername))
      .limit(1);
    if (!owner[0]) return { ok: false, error: "tenant not found" };
    return applyMcpConnect(mcpGateDeps, {
      userId: owner[0].id,
      osUsername: p.osUsername,
      name: p.name,
      stanza: p.stanza,
    });
  },
});

// M5.5 gated MCP connect: list / connect (validate → scan → approval) / disconnect.
registerMcpRoutes(app, {
  redis,
  jwtSecret: config.jwtSecret,
  gate: mcpGateDeps,
  approvals: approvalsDeps,
});

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

// Still-stubbed surface (later M5/M5.5 increments). /fs/*, /approvals, /live
// are implemented above.
for (const route of ["/registry/items", "/sessions"] as const) {
  app.get(route, async (_req, reply) =>
    reply.code(501).send({ error: "not implemented yet", route }),
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
