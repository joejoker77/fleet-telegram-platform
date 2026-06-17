// @fleet/api — Mini App backend + public API (Fastify). M1 surface: initData
// auth → POST /auth/session, GET /me. Endpoints from later milestones return 501.
import Fastify from "fastify";
import { Redis } from "ioredis";
import { and, eq, gte } from "drizzle-orm";
import { authSessionRequest, type MeResponse } from "@fleet/shared";
import { getDb, getPool, schema } from "@fleet/db";
import { loadConfig } from "./config.js";
import { verifyInitData, InitDataError } from "./initdata.js";
import { peekInitDataUserId, readTenantBotToken } from "./bot-token.js";
import { issueSession, verifySession } from "./auth.js";
import { sendAudit } from "./audit.js";
import { registerFsRoutes } from "./fs-routes.js";
import { registerLiveRoutes } from "./live-routes.js";
import { registerApprovalRoutes } from "./approval-routes.js";
import { registerMcpRoutes } from "./mcp-routes.js";
import { registerIdeRoutes } from "./ide-routes.js";
import { registerSessionRoutes } from "./session-routes.js";
import { registerIntegrationRoutes } from "./integration-routes.js";
import { registerDeployRoutes } from "./deploy-routes.js";
import {
  registerRegistryRoutes,
  makePublishApply,
  makeImportApply,
  REGISTRY_PUBLISH_KIND,
  REGISTRY_IMPORT_KIND,
  type RegistryDeps,
} from "./registry-routes.js";
import {
  applyMcpConnect,
  deleteStagedSecret,
  MCP_APPROVAL_KIND,
  type McpStanza,
  type SecretMeta,
} from "./mcp-gate.js";
import websocket from "@fastify/websocket";

const config = loadConfig();
const app = Fastify({ logger: { name: "api" } });
const redis = new Redis(config.redisUrl, { maxRetriesPerRequest: 3 });
const db = getDb();

await app.register(websocket);

// JSON parser that ALSO retains the raw bytes (req.rawBody) so the GitHub push
// webhook can recompute X-Hub-Signature-256 over the exact payload. Semantically
// identical to Fastify's default JSON parser (buffer → utf8 → JSON.parse); empty
// body → undefined (handlers already tolerate `req.body ?? {}`).
app.addContentTypeParser("application/json", { parseAs: "buffer" }, (req, body, done) => {
  const buf = body as Buffer;
  req.rawBody = buf;
  if (buf.length === 0) return done(null, undefined);
  try {
    done(null, JSON.parse(buf.toString("utf8")));
  } catch (err) {
    (err as Error & { statusCode?: number }).statusCode = 400;
    done(err as Error, undefined);
  }
});

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
  tenantHomeRoot: config.tenantHomeRoot,
  botUsername: config.botUsername,
  miniappUrl: config.miniappUrl,
};
const mcpGateDeps = {
  homeRoot: config.tenantHomeRoot,
  judgeUrl: config.judgeUrl,
  auditSocket: config.auditSocket,
  secretdSocket: config.secretdSocket,
};
// M8.1 marketplace: cp-api owns scan+approval+DB; the pod executes the GitHub
// publish (it holds the PAT). Built before registerApprovalRoutes so the
// publish/import approval-apply handlers can close over it.
const registryDeps: RegistryDeps = {
  redis,
  jwtSecret: config.jwtSecret,
  homeRoot: config.tenantHomeRoot,
  judgeUrl: config.judgeUrl,
  auditSocket: config.auditSocket,
  approvals: approvalsDeps,
  repo: config.registryRepo,
};
const publishApply = makePublishApply(registryDeps);
const importApply = makeImportApply(registryDeps);

type McpApprovalPayload = { name?: string; stanza?: McpStanza; osUsername?: string; secret?: SecretMeta };
registerApprovalRoutes(app, approvalsDeps, {
  // M8.1: a non-admin's allowed publish dispatches the pod git-write + records
  // the version; an allowed import re-fetches the pinned files and installs them.
  [REGISTRY_PUBLISH_KIND]: { apply: publishApply },
  [REGISTRY_IMPORT_KIND]: { apply: importApply },
  // M5.5: an allowed mcp.connect approval is applied synchronously in the
  // answer handler. The payload was authored by POST /mcp/connect; apply
  // re-validates it before touching tenant files. M5.5b: a staged secret is
  // bound on allow (inside applyMcpConnect) and deleted on deny (onReject).
  [MCP_APPROVAL_KIND]: {
    apply: async (row) => {
      const p = (row.payload ?? {}) as McpApprovalPayload;
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
        ...(p.secret ? { secret: p.secret } : {}),
      });
    },
    onReject: async (row) => {
      const p = (row.payload ?? {}) as McpApprovalPayload;
      // onlyIfUnbound: a parallel same-name approval may already have bound it.
      if (p.secret?.name) await deleteStagedSecret(mcpGateDeps, null, p.secret.name, { onlyIfUnbound: true });
    },
  },
});

// M5.5 gated MCP connect: list / connect (validate → scan → approval) / disconnect.
registerMcpRoutes(app, {
  redis,
  jwtSecret: config.jwtSecret,
  gate: mcpGateDeps,
  approvals: approvalsDeps,
});

// M5.6 web-IDE: ticket → cookie auth for the nginx auth_request vhost
// (ide.ai-assistant.gg). cp-api only authenticates; it never sees the socket.
registerIdeRoutes(app, {
  redis,
  jwtSecret: config.jwtSecret,
  auditSocket: config.auditSocket,
  ideUrl: config.ideUrl,
});

// M5.7 named sessions/projects: list / create / switch. cp-api writes the
// switch request into the tenant home; the pod supervisor is the executor.
registerSessionRoutes(app, {
  redis,
  jwtSecret: config.jwtSecret,
  auditSocket: config.auditSocket,
  homeRoot: config.tenantHomeRoot,
});

// A2 deploy reconcile: admin-only HTTP trigger (manual/CI) for the control-plane
// skills+mcp reconcile that replaces the host skill-deploy@/mcp-deploy@ timers.
registerDeployRoutes(app, {
  redis,
  jwtSecret: config.jwtSecret,
  githubWebhookSecret: config.githubWebhookSecret,
});

// M6.2 Composio integrations: public OAuth-callback landing + notify + audit.
registerIntegrationRoutes(app, {
  auditSocket: config.auditSocket,
  botToken: config.botToken,
  tenantHomeRoot: config.tenantHomeRoot,
});

// M8.1 artifact marketplace: catalog / publish (scan → admin-now|approval) /
// import (re-scan → approval → install) / unpublish.
registerRegistryRoutes(app, registryDeps);

// POST /auth/session — verify Telegram initData, resolve the tenant, issue a JWT.
app.post("/auth/session", async (req, reply) => {
  const body = authSessionRequest.safeParse(req.body);
  if (!body.success) return reply.code(400).send({ error: "invalid body" });

  // Multi-bot: verify initData against the token of the bot it was opened from.
  // Peek the (untrusted) user id → resolve the tenant → read THAT bot's token;
  // the HMAC still gates auth, so picking the candidate by claimed id is safe.
  // Falls back to the configured token (pilot/single-bot) when none is found.
  const peekedId = peekInitDataUserId(body.data.initData);
  let botToken = config.botToken;
  if (peekedId !== null) {
    const cand = await db
      .select({ os: schema.users.osUsername })
      .from(schema.users)
      .where(eq(schema.users.telegramUserId, peekedId))
      .limit(1);
    const os = cand[0]?.os;
    const tenantToken = os ? readTenantBotToken(config.tenantHomeRoot, os) : null;
    if (tenantToken) botToken = tenantToken;
  }

  let verified;
  try {
    verified = verifyInitData(body.data.initData, botToken, config.initDataMaxAgeSeconds);
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

// GET /usage/summary?days=30 — M5.13 UsageDashboard. Daily series with split
// counters (in/out/cache; cache dominates real volume so it is never folded
// into in+out), per-model totals and the last-5h window (the Max-subscription
// fair-use window). Rows written before migration 0002 have no split — their
// in+out total is surfaced per-day as `legacy`. Dates are UTC. Tokens only:
// the subscription is flat-rate, there is no $ to show.
app.get("/usage/summary", async (req, reply) => {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return reply.code(401).send({ error: "missing bearer token" });
  let sub: string;
  try {
    ({ sub } = await verifySession(redis, config.jwtSecret, token));
  } catch {
    return reply.code(401).send({ error: "invalid or expired session" });
  }

  const q = (req.query ?? {}) as { days?: string };
  const days = Math.min(90, Math.max(1, Number(q.days) || 30));
  const cutoff = new Date(Date.now() - days * 24 * 3600 * 1000);
  const fiveHoursAgo = new Date(Date.now() - 5 * 3600 * 1000);

  const rows = await db
    .select({
      ts: schema.usageRecords.ts,
      window: schema.usageRecords.window,
      tokens: schema.usageRecords.tokens,
      model: schema.usageRecords.model,
      inputTokens: schema.usageRecords.inputTokens,
      outputTokens: schema.usageRecords.outputTokens,
      cacheReadTokens: schema.usageRecords.cacheReadTokens,
      cacheCreationTokens: schema.usageRecords.cacheCreationTokens,
    })
    .from(schema.usageRecords)
    .where(and(eq(schema.usageRecords.userId, sub), gte(schema.usageRecords.ts, cutoff)));

  type Day = {
    date: string;
    in: number;
    out: number;
    cacheRead: number;
    cacheWrite: number;
    legacy: number;
    turns: number;
  };
  const byDay = new Map<string, Day>();
  // Zero-fill the whole range so the chart has no gaps (UTC dates).
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(Date.now() - i * 24 * 3600 * 1000).toISOString().slice(0, 10);
    byDay.set(d, { date: d, in: 0, out: 0, cacheRead: 0, cacheWrite: 0, legacy: 0, turns: 0 });
  }
  const byModel: Record<string, { tokens: number; turns: number }> = {};
  const last5h = { in: 0, out: 0, cacheRead: 0, cacheWrite: 0, turns: 0 };

  for (const r of rows) {
    const date = r.window ?? r.ts.toISOString().slice(0, 10);
    const day = byDay.get(date);
    const split = r.inputTokens != null || r.outputTokens != null;
    if (day) {
      day.turns += 1;
      if (split) {
        day.in += r.inputTokens ?? 0;
        day.out += r.outputTokens ?? 0;
        day.cacheRead += r.cacheReadTokens ?? 0;
        day.cacheWrite += r.cacheCreationTokens ?? 0;
      } else {
        day.legacy += r.tokens ?? 0;
      }
    }
    const m = r.model ?? "unknown";
    byModel[m] = byModel[m] ?? { tokens: 0, turns: 0 };
    byModel[m].tokens += r.tokens ?? 0;
    byModel[m].turns += 1;
    if (r.ts >= fiveHoursAgo) {
      last5h.turns += 1;
      last5h.in += r.inputTokens ?? 0;
      last5h.out += r.outputTokens ?? 0;
      last5h.cacheRead += r.cacheReadTokens ?? 0;
      last5h.cacheWrite += r.cacheCreationTokens ?? 0;
    }
  }

  return reply.send({ days: [...byDay.values()], byModel, last5h });
});

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
