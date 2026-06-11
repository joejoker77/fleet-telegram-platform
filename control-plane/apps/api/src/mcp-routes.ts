// M5.5 — HTTP surface for the gated MCP connect (docs/M5.5-mcp-gate-design.md).
//   GET  /mcp/list        — servers in <home>/work/.mcp.json + enabled flags
//   POST /mcp/connect     — { name, stanza } → validate → scan (fail-closed) →
//                           pass: create approval (M5.4b) and return its id;
//                           the APPLY happens in the approval-answer handler.
//   POST /mcp/disconnect  — { name } → remove from both files (no approval:
//                           capability removal is the safe direction)
import type { FastifyInstance } from "fastify";
import type { Redis } from "ioredis";
import { requireAuth, AuthError } from "./authz.js";
import { createApproval, type ApprovalsDeps } from "./approvals.js";
import {
  MCP_APPROVAL_KIND,
  MCP_TTL_SECONDS,
  disconnectMcp,
  listMcp,
  mcpNameExists,
  scanMcpStanza,
  validateStanza,
  type McpGateDeps,
  type McpStanza,
} from "./mcp-gate.js";
import { sendAudit } from "./audit.js";

export interface McpRoutesDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  gate: McpGateDeps;
  approvals: ApprovalsDeps;
}

export function registerMcpRoutes(app: FastifyInstance, deps: McpRoutesDeps): void {
  const auth = (req: Parameters<typeof requireAuth>[0]) =>
    requireAuth(req, deps.redis, deps.jwtSecret);

  app.get("/mcp/list", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    return reply.send({ servers: listMcp(deps.gate, ctx.osUsername) });
  });

  app.post("/mcp/connect", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const body = (req.body ?? {}) as { name?: unknown; stanza?: unknown };
    if (typeof body.name !== "string" || body.stanza === undefined) {
      return reply.code(400).send({ error: "expected { name, stanza }" });
    }
    const invalid = validateStanza(body.name, body.stanza);
    if (invalid) return reply.code(400).send({ error: invalid });
    const name = body.name;
    const stanza = body.stanza as McpStanza;
    const overwrite = mcpNameExists(deps.gate, ctx.osUsername, name);

    // L4 gate: deterministic + judge, fails closed (error verdict also blocks).
    const scan = await scanMcpStanza(deps.gate, {
      name,
      stanza,
      actor: `miniapp:${ctx.osUsername}`,
      userId: ctx.userId,
    });
    if (scan.verdict !== "pass") {
      await sendAudit(deps.gate.auditSocket, {
        userId: ctx.userId,
        kind: "mcp.connect.blocked",
        actor: `miniapp:${ctx.osUsername}`,
        payload: { name, verdict: scan.verdict, severity: scan.severity, decidedBy: scan.decidedBy },
      }).catch(() => {});
      return reply.code(422).send({
        error: scan.verdict === "error" ? "сканер недоступен — отказ (fail-closed)" : "станса не прошла сканер",
        verdict: scan.verdict,
        severity: scan.severity,
        decidedBy: scan.decidedBy,
        findings: scan.findings,
        reportRef: scan.reportRef,
      });
    }

    // The scan verdict travels INSIDE the approval payload — the human decides
    // looking at what the gate saw, not blindly.
    const approval = await createApproval(deps.approvals, {
      userId: ctx.userId,
      kind: MCP_APPROVAL_KIND,
      title: `${overwrite ? "⚠️ Перезаписать" : "Подключить"} MCP «${name}»`,
      payload: {
        name,
        stanza,
        osUsername: ctx.osUsername,
        overwrite,
        scan: {
          verdict: scan.verdict,
          severity: scan.severity,
          decidedBy: scan.decidedBy,
          findings: scan.findings,
          reportRef: scan.reportRef,
        },
      },
      ttlSeconds: MCP_TTL_SECONDS,
    });

    return reply.send({
      approvalId: approval.id,
      ttlSeconds: approval.ttlSeconds,
      overwrite,
      verdict: scan.verdict,
      severity: scan.severity,
      findings: scan.findings,
    });
  });

  app.post("/mcp/disconnect", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const { name } = (req.body ?? {}) as { name?: unknown };
    if (typeof name !== "string" || !name) return reply.code(400).send({ error: "expected { name }" });
    const res = await disconnectMcp(deps.gate, { userId: ctx.userId, osUsername: ctx.osUsername, name });
    if (!res.ok) return reply.code(404).send({ error: res.error ?? "disconnect failed" });
    return reply.send(res);
  });
}
