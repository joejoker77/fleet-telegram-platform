// M6.2 — Composio OAuth callback (docs/M6.2-composio.md, 11-integrations.md).
//   GET /integrations/composio/callback — landing for the browser redirect
//   after the user finishes hosted auth (Connect Link). PUBLIC (no JWT): the
//   user arrives in a plain browser/webview, not the Mini App.
//
// Why public is safe here: the endpoint changes no state. Composio bound the
// connected account to user_id server-side at link-creation time (the pod
// helper `composio-connect` passes user_id + this callback_url). All this
// route does is (a) render a "done, go back to Telegram" page, (b) notify the
// chat via main-bot sendMessage (send-only, same pattern as approvals), and
// (c) emit an audit event. A forged hit can at worst send the user a bogus
// "connected" note — bounded by a per-uid rate limit below.
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import { sendAudit } from "./audit.js";
import { readTenantBotToken } from "./bot-token.js";

export interface IntegrationRoutesDeps {
  auditSocket: string;
  botToken: string; // fallback / default outbound bot (pilot tenant)
  tenantHomeRoot: string; // resolve each tenant's own bot token for the notify
}

const UID_RE = /^\d{1,20}$/; // telegram chat_id we embedded in callback_url
const TOOLKIT_RE = /^[a-z0-9_-]{1,64}$/i; // composio toolkit slug
const CA_ID_RE = /^[\w-]{1,128}$/; // connected_account_id (ca_…)

// Per-uid sliding-window limit on notifications — the only externally
// observable side effect of this public route. In-memory is fine: cp-api is a
// single process, and losing the window on restart only re-arms 5 notifies.
const NOTIFY_LIMIT = 5;
const NOTIFY_WINDOW_MS = 60 * 60 * 1000;
const notifyLog = new Map<string, number[]>();
function allowNotify(uid: string): boolean {
  const now = Date.now();
  const recent = (notifyLog.get(uid) ?? []).filter((t) => now - t < NOTIFY_WINDOW_MS);
  if (recent.length >= NOTIFY_LIMIT) {
    notifyLog.set(uid, recent);
    return false;
  }
  recent.push(now);
  notifyLog.set(uid, recent);
  return true;
}

// UX rule (11-integrations.md): the user never sees "Composio"/"OAuth"/"MCP".
const page = (title: string, line: string) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
  body{font-family:system-ui,sans-serif;background:#101418;color:#e8edf2;
       display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
  .card{max-width:22rem;text-align:center;padding:2rem}
  .big{font-size:3rem;margin-bottom:1rem}
  p{color:#9fb0bf;line-height:1.5}
</style></head>
<body><div class="card"><div class="big">${title}</div><p>${line}</p></div></body></html>`;

export function registerIntegrationRoutes(app: FastifyInstance, deps: IntegrationRoutesDeps): void {
  app.get("/integrations/composio/callback", async (req, reply) => {
    const q = (req.query ?? {}) as Record<string, unknown>;
    const uid = typeof q.uid === "string" ? q.uid : "";
    const toolkit = typeof q.toolkit === "string" ? q.toolkit.toLowerCase() : "";
    // Composio appends these to our callback_url after hosted auth:
    const status = q.status === "success" ? "success" : "failed";
    const caId = typeof q.connected_account_id === "string" ? q.connected_account_id : "";

    if (!UID_RE.test(uid) || !TOOLKIT_RE.test(toolkit)) {
      return reply.code(400).send({ error: "bad callback params" });
    }

    const nice = toolkit.charAt(0).toUpperCase() + toolkit.slice(1);
    const okFlow = status === "success";

    // Fire-and-forget: the user's browser should never wait on Telegram/audit.
    void (async () => {
      // Resolve the tenant first: we need its os_username to send the notify via
      // THAT tenant's own bot (multi-bot — a bot can only message users who
      // started it, so the pilot's bot can't notify another tenant).
      let userId: string | undefined;
      let osUsername: string | undefined;
      try {
        // telegram_user_id is bigint in PG; out-of-safe-range uids (only
        // possible on forged hits) simply find no tenant.
        const tgId = Number(uid);
        const db = getDb();
        const rows = Number.isSafeInteger(tgId)
          ? await db
              .select({ id: schema.users.id, os: schema.users.osUsername })
              .from(schema.users)
              .where(eq(schema.users.telegramUserId, tgId))
              .limit(1)
          : [];
        userId = rows[0]?.id;
        osUsername = rows[0]?.os;
      } catch {
        /* audit is best-effort on this public route */
      }

      const botToken = (osUsername && readTenantBotToken(deps.tenantHomeRoot, osUsername)) || deps.botToken;
      if (botToken && allowNotify(uid)) {
        const text = okFlow
          ? `✅ ${nice} is connected — go back to the chat and use it.`
          : `⚠️ Could not connect ${nice}. Go back to the chat and ask for a new link.`;
        await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ chat_id: uid, text }),
        }).catch(() => {});
      }
      if (userId) {
        await sendAudit(deps.auditSocket, {
          userId,
          kind: okFlow ? "integration.connected" : "integration.connect_failed",
          actor: "cp-api",
          payload: {
            provider: "composio",
            toolkit,
            connectedAccountId: CA_ID_RE.test(caId) ? caId : null,
          },
        }).catch(() => {});
      }
    })();

    reply.header("cache-control", "no-store");
    return reply.type("text/html; charset=utf-8").send(
      okFlow
        ? page("✅", `${nice} is connected. You can close this tab and return to Telegram.`)
        : page("⚠️", `${nice} was not connected. Close this tab and ask for a new link in the chat.`),
    );
  });
}
