// M5.4b — HTTP surface for platform approvals (docs/M5.4b-approvals-design.md).
//   GET  /approvals                  — own queue + history (lazy-expires first)
//   POST /approvals/:id/answer       — { decision: "allow" | "deny" } from the Mini App
//   POST /approvals/test             — admin-only: create + wait, for acceptance runs
// createApproval/waitForAnswer are exported from approvals.ts for in-process
// gate callers (M5.5 MCP-connect is the first); POST /approvals is deliberately
// NOT public — tenants don't create approvals for themselves.

import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import { requireAuth, AuthError } from "./authz.js";
import {
  answerApproval,
  createApproval,
  listApprovals,
  waitForAnswer,
  type ApprovalsDeps,
} from "./approvals.js";

export function registerApprovalRoutes(app: FastifyInstance, deps: ApprovalsDeps): void {
  const auth = (req: Parameters<typeof requireAuth>[0]) =>
    requireAuth(req, deps.redis, deps.jwtSecret);

  app.get("/approvals", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const approvals = await listApprovals(deps, ctx.userId);
    return reply.send({ approvals });
  });

  app.post("/approvals/:id/answer", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const { id } = req.params as { id: string };
    const { decision } = (req.body ?? {}) as { decision?: string };
    if (decision !== "allow" && decision !== "deny") {
      return reply.code(400).send({ error: 'expected { decision: "allow" | "deny" }' });
    }
    const row = await answerApproval(deps, { id, userId: ctx.userId, allow: decision === "allow" });
    if (!row) return reply.code(404).send({ error: "approval not found or no longer pending" });
    return reply.send({ ok: true, approval: row });
  });

  // Acceptance/test hook (admin only): create a synthetic approval and block
  // until it is answered or expires — exercises the full pipeline (notify →
  // Mini App answer → pubsub wakeup) without needing M5.5 yet.
  app.post("/approvals/test", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const adminRows = await getDb()
      .select({ isAdmin: schema.users.isAdmin })
      .from(schema.users)
      .where(eq(schema.users.id, ctx.userId))
      .limit(1);
    if (!adminRows[0]?.isAdmin) return reply.code(403).send({ error: "admin only" });

    const body = (req.body ?? {}) as { title?: string; ttlSeconds?: number };
    const ttlSeconds = Math.min(Math.max(body.ttlSeconds ?? 60, 10), 300);
    const approval = await createApproval(deps, {
      userId: ctx.userId,
      kind: "test",
      title: body.title ?? "Тестовый аппрув (m5.4b acceptance)",
      payload: { source: "POST /approvals/test" },
      ttlSeconds,
    });
    const outcome = await waitForAnswer(deps, approval.id, ttlSeconds);
    return reply.send({ id: approval.id, outcome });
  });
}
