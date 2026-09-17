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
//
// M6.5 — tell the ASSISTANT, not just the chat. The notify above reaches the
// user; the session never learns anything, so the user had to repeat "I
// connected it" before the bot would use the new account. We now also leave a
// one-line notice for the pod supervisor to hand to the session (same
// request-file contract as session-routes: cp-api writes, the pod executes).
// Writing into a session is worth more than a chat note, so it is gated on a
// single-use nonce minted by `composio-connect` inside the tenant's own home:
// no nonce, no session write — the pre-M6.5 behaviour, unchanged.
import fs from "node:fs";
import path from "node:path";
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
const ALIAS_RE = /^[a-z0-9_-]{1,64}$/i; // multi-account label ("work"/"personal")
// hex only — this lands in a path, so the shape is also the traversal guard
const NONCE_RE = /^[a-f0-9]{32}$/;
// How long a link may sit unfinished. Sign-in can involve a password manager,
// 2FA and an account chooser, so this is generous; the helper prunes on the
// same clock.
const PENDING_TTL_MS = 30 * 60 * 1000;

interface PendingLink {
  nonce?: unknown;
  toolkit?: unknown;
  uid?: unknown;
  created?: unknown;
}

// Consume the pending-link file the pod helper wrote for this nonce. Returns
// true exactly once per nonce: the file is removed whether or not it matched,
// so a leaked nonce cannot be replayed.
function consumePendingNonce(home: string, nonce: string, uid: string, toolkit: string): boolean {
  if (!NONCE_RE.test(nonce)) return false;
  const file = path.join(home, ".claude", "run", "composio-pending", `${nonce}.json`);
  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return false; // no such pending link — forged, already used, or expired
  }
  try {
    fs.unlinkSync(file);
  } catch {
    /* already gone — the match below still decides */
  }
  let p: PendingLink;
  try {
    p = JSON.parse(raw) as PendingLink;
  } catch {
    return false;
  }
  const created = Number(p.created) * 1000;
  if (!Number.isFinite(created) || Date.now() - created > PENDING_TTL_MS) return false;
  return String(p.uid) === uid && String(p.toolkit) === toolkit;
}

// Leave the notice for the pod supervisor (sole executor, same contract as
// session-routes). Owned by the tenant, written atomically.
function writeSessionNotice(home: string, text: string): void {
  const runDir = path.join(home, ".claude", "run");
  const { uid, gid } = fs.statSync(home);
  if (!fs.existsSync(runDir)) {
    fs.mkdirSync(runDir, { recursive: true });
    try {
      fs.chownSync(runDir, uid, gid);
    } catch {
      /* api not root in dev */
    }
  }
  const file = path.join(runDir, "session-inject.json");
  const tmp = `${file}.cp-tmp`;
  fs.writeFileSync(
    tmp,
    `${JSON.stringify({ text, created: Math.floor(Date.now() / 1000) })}\n`,
    { mode: 0o644 },
  );
  try {
    fs.chownSync(tmp, uid, gid);
  } catch {
    /* api not root in dev */
  }
  fs.renameSync(tmp, file);
}

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
    const nonce = typeof q.nonce === "string" ? q.nonce : "";
    const aliasRaw = typeof q.alias === "string" ? q.alias : "";
    const alias = ALIAS_RE.test(aliasRaw) ? aliasRaw : "";

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
      // M6.5: hand the news to the session too, but only for a real return from
      // a link this tenant asked for. The chat notice above already went out, so
      // the line tells the assistant NOT to send a second confirmation.
      let told = false;
      if (okFlow && osUsername && nonce) {
        const home = path.join(deps.tenantHomeRoot, osUsername);
        try {
          if (consumePendingNonce(home, nonce, uid, toolkit)) {
            const which = alias ? ` (account "${alias}")` : "";
            writeSessionNotice(
              home,
              `[SYSTEM] Integration callback: the user has finished signing in to ${nice}${which} — ` +
                `it is connected and ready to use now. The chat has ALREADY been told, so do not send ` +
                `another confirmation; just remember it is connected and carry on.`,
            );
            told = true;
          }
        } catch (err) {
          req.log.warn({ err, osUsername }, "composio callback: could not leave a session notice");
        }
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
            sessionNotified: told,
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
