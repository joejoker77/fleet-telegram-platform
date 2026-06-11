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
  stageSecret,
  validateSecretSpec,
  validateStanza,
  type McpGateDeps,
  type McpStanza,
  type SecretMeta,
  type SecretSpec,
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
    const body = (req.body ?? {}) as { name?: unknown; stanza?: unknown; secretSpec?: unknown };
    if (typeof body.name !== "string" || body.stanza === undefined) {
      return reply.code(400).send({ error: "expected { name, stanza, secretSpec? }" });
    }
    const invalid = validateStanza(body.name, body.stanza);
    if (invalid) return reply.code(400).send({ error: invalid });
    // M5.5b: optional secret. Validated BEFORE the scan (cheap, deterministic);
    // the value itself never reaches the scanner, the approval, or any file.
    if (body.secretSpec !== undefined) {
      const badSecret = validateSecretSpec(body.name, body.secretSpec);
      if (badSecret) return reply.code(400).send({ error: badSecret });
    }
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

    // M5.5b: stage the secret in the vault UNBOUND (inert) only after the scan
    // passed. The approval payload carries META only; binding happens on allow.
    let secretMeta: SecretMeta | undefined;
    let secretRotated = false;
    if (body.secretSpec !== undefined) {
      const staged = await stageSecret(deps.gate, {
        userId: ctx.userId,
        osUsername: ctx.osUsername,
        mcpName: name,
        spec: body.secretSpec as SecretSpec,
      });
      if (!staged.ok) return reply.code(502).send({ error: staged.error });
      secretMeta = staged.meta;
      secretRotated = staged.rotated === true;
    }

    // The scan verdict travels INSIDE the approval payload — the human decides
    // looking at what the gate saw, not blindly.
    const approval = await createApproval(deps.approvals, {
      userId: ctx.userId,
      kind: MCP_APPROVAL_KIND,
      title: `${overwrite ? "⚠️ Перезаписать" : "Подключить"} MCP «${name}»${secretMeta ? " 🔑" : ""}`,
      payload: {
        name,
        stanza,
        osUsername: ctx.osUsername,
        overwrite,
        ...(secretMeta ? { secret: secretMeta } : {}),
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
      ...(secretMeta
        ? { secret: { name: secretMeta.name, hostPattern: secretMeta.hostPattern, rotated: secretRotated } }
        : {}),
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
