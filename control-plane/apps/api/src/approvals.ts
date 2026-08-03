// M5.4b — platform approvals service (docs/M5.4b-approvals-design.md, v2).
// Questions asked by the CONTROL PLANE (mcp.connect gate, artifact import, …),
// answered from the Mini App over HTTPS. In-session tool approvals are NOT
// handled here — they stay with the telegram plugin's own permission flow.
//
// Lifecycle: create (pending, ttl) → notify (main-bot sendMessage + url-button
// deep link; SEND-ONLY, so no second consumer of the bot token) → answer from
// Mini App (Redis pubsub wakes any waiter) | lazy expiry (evaluated on
// read/wait — no cron). Fail-closed: expired = denied.

import { Redis } from "ioredis";
import type { Redis as RedisClient } from "ioredis";
import { and, desc, eq, lt, sql } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import { sendAudit } from "./audit.js";
import { readTenantBotToken } from "./bot-token.js";

export interface ApprovalsDeps {
  redis: RedisClient;
  redisUrl: string;
  jwtSecret: Uint8Array;
  auditSocket: string;
  botToken: string; // fallback / default outbound bot (pilot tenant)
  tenantHomeRoot: string; // resolve each tenant's own bot token for the notify
  botUsername: string; // fallback t.me/<bot>?startapp=approvals deep link; "" → no fallback button
  // Mini App URL for the web_app notify button (preferred: opens the app
  // directly; the startapp deep link silently fails on clients with stale bot
  // metadata / Main-App config — observed live 2026-06-11). "" → fall back to
  // the botUsername deep link, then to text-only.
  miniappUrl: string;
}

export interface ApprovalRow {
  id: string;
  kind: string;
  title: string;
  payload: unknown;
  status: "pending" | "allowed" | "denied" | "expired";
  answeredVia: string | null;
  ttlSeconds: number;
  createdAt: Date;
  answeredAt: Date | null;
}

const channel = (id: string) => `approval:${id}`;

// Mark overdue pending approvals as expired (fail-closed). Lazy: called from
// list/wait paths instead of a timer. Returns the ids it expired.
export async function expireOverdue(deps: ApprovalsDeps, userId?: string): Promise<string[]> {
  const db = getDb();
  const conds = [
    eq(schema.approvals.status, "pending"),
    lt(
      sql`${schema.approvals.createdAt} + make_interval(secs => ${schema.approvals.ttlSeconds})`,
      sql`now()`,
    ),
  ];
  if (userId) conds.push(eq(schema.approvals.userId, userId));
  const rows = await db
    .update(schema.approvals)
    .set({ status: "expired", answeredVia: "timeout", answeredAt: new Date() })
    .where(and(...conds))
    .returning({ id: schema.approvals.id, userId: schema.approvals.userId, kind: schema.approvals.kind });
  for (const r of rows) {
    deps.redis.publish(channel(r.id), "expired").catch(() => {});
    await sendAudit(deps.auditSocket, {
      userId: r.userId,
      kind: "approval.expired",
      actor: "cp-api",
      payload: { id: r.id, approvalKind: r.kind },
    }).catch(() => {});
  }
  return rows.map((r) => r.id);
}

export async function createApproval(
  deps: ApprovalsDeps,
  args: { userId: string; kind: string; title: string; payload?: unknown; ttlSeconds?: number },
): Promise<ApprovalRow> {
  const db = getDb();
  const ttlSeconds = Math.min(Math.max(args.ttlSeconds ?? 120, 10), 3600);
  const inserted = await db
    .insert(schema.approvals)
    .values({
      userId: args.userId,
      kind: args.kind,
      title: args.title,
      payload: args.payload ?? null,
      ttlSeconds,
    })
    .returning();
  const row = inserted[0];
  if (!row) throw new Error("approval insert returned no row");

  await sendAudit(deps.auditSocket, {
    userId: args.userId,
    kind: "approval.requested",
    actor: "cp-api",
    payload: { id: row.id, approvalKind: args.kind, title: args.title, ttlSeconds },
  }).catch(() => {});

  void notifyTelegram(deps, args.userId, args.title).catch(() => {});
  return toRow(row);
}

// Answer from the Mini App. Idempotence/authz: only the owner, only while
// pending. Returns the updated row or null (not found / not pending / not owner).
export async function answerApproval(
  deps: ApprovalsDeps,
  args: { id: string; userId: string; allow: boolean },
): Promise<ApprovalRow | null> {
  const db = getDb();
  const status = args.allow ? ("allowed" as const) : ("denied" as const);
  const rows = await db
    .update(schema.approvals)
    .set({ status, answeredVia: "miniapp", answeredAt: new Date() })
    .where(
      and(
        eq(schema.approvals.id, args.id),
        eq(schema.approvals.userId, args.userId),
        eq(schema.approvals.status, "pending"),
      ),
    )
    .returning();
  const row = rows[0];
  if (!row) return null;

  deps.redis.publish(channel(args.id), status).catch(() => {});
  await sendAudit(deps.auditSocket, {
    userId: args.userId,
    kind: "approval.answered",
    actor: "cp-api",
    payload: { id: args.id, approvalKind: row.kind, decision: status, via: "miniapp" },
  }).catch(() => {});
  return toRow(row);
}

export async function listApprovals(deps: ApprovalsDeps, userId: string): Promise<ApprovalRow[]> {
  await expireOverdue(deps, userId);
  const db = getDb();
  const rows = await db
    .select()
    .from(schema.approvals)
    .where(eq(schema.approvals.userId, userId))
    .orderBy(desc(schema.approvals.createdAt))
    .limit(50);
  return rows.map(toRow);
}

// Block until the approval is answered or its ttl runs out. Used by gate
// callers inside cp-api (M5.5 first). Wakes on Redis pubsub; falls back to a
// final DB check so a missed publish can't strand the caller past ttl.
export async function waitForAnswer(
  deps: ApprovalsDeps,
  id: string,
  ttlSeconds: number,
): Promise<"allowed" | "denied" | "expired"> {
  // Dedicated connection: subscribe-mode cannot share the command client.
  const sub = new Redis(deps.redisUrl, { maxRetriesPerRequest: 1 });
  try {
    const viaPubsub = await new Promise<string | null>((resolve) => {
      const timer = setTimeout(() => resolve(null), ttlSeconds * 1000 + 1500);
      sub.on("message", (ch, msg) => {
        if (ch === channel(id)) {
          clearTimeout(timer);
          resolve(msg);
        }
      });
      sub.on("error", () => {
        /* keep waiting; final DB check below is the safety net */
      });
      sub.subscribe(channel(id)).catch(() => {
        clearTimeout(timer);
        resolve(null);
      });
    });
    if (viaPubsub === "allowed" || viaPubsub === "denied" || viaPubsub === "expired") {
      return viaPubsub;
    }
  } finally {
    sub.disconnect();
  }

  // Timed out or pubsub failed → settle via DB, expiring if still pending.
  await expireOverdue(deps);
  const db = getDb();
  const rows = await db
    .select({ status: schema.approvals.status })
    .from(schema.approvals)
    .where(eq(schema.approvals.id, id))
    .limit(1);
  const st = rows[0]?.status;
  return st === "allowed" || st === "denied" ? st : "expired";
}

// Best-effort notify via the MAIN bot token. sendMessage is send-only — it does
// not consume getUpdates, so the telegram plugin's polling is untouched. The
// inline button is a URL button (opens the Mini App deep link); url buttons
// produce no callback_query, so there is still no second consumer.
async function notifyTelegram(deps: ApprovalsDeps, userId: string, title: string): Promise<void> {
  const db = getDb();
  const rows = await db
    .select({ tg: schema.users.telegramUserId, os: schema.users.osUsername })
    .from(schema.users)
    .where(eq(schema.users.id, userId))
    .limit(1);
  const chatId = rows[0]?.tg;
  if (!chatId) return;

  // Send via THIS tenant's own bot — a bot can only message users who started
  // it, so the pilot's bot can't notify another tenant (multi-bot). Fall back to
  // the configured token only when the tenant token can't be read.
  const os = rows[0]?.os;
  const botToken = (os && readTenantBotToken(deps.tenantHomeRoot, os)) || deps.botToken;
  if (!botToken) return;

  const body: Record<string, unknown> = {
    chat_id: chatId,
    text: `⚠️ Approval needed: ${title}\n\nOpen the approvals screen to allow or reject it.`,
  };
  if (deps.miniappUrl) {
    // web_app button: allowed in private chats, opens the Mini App directly.
    // ?screen=approvals routes the app (no start_param in this open mode).
    // v=… busts the webview's heuristic cache of index.html (a stale cached
    // copy kept serving an old bundle, 2026-06-11) — belt to the nginx
    // Cache-Control:no-cache suspenders (deploy/nginx-miniapp.conf).
    body.reply_markup = {
      inline_keyboard: [
        [{ text: "Open approvals", web_app: { url: `${deps.miniappUrl}/?screen=approvals&v=2` } }],
      ],
    };
  } else if (deps.botUsername) {
    body.reply_markup = {
      inline_keyboard: [
        [{ text: "Open approvals", url: `https://t.me/${deps.botUsername}?startapp=approvals` }],
      ],
    };
  }
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function toRow(r: typeof schema.approvals.$inferSelect): ApprovalRow {
  return {
    id: r.id,
    kind: r.kind,
    title: r.title,
    payload: r.payload,
    status: r.status,
    answeredVia: r.answeredVia,
    ttlSeconds: r.ttlSeconds,
    createdAt: r.createdAt,
    answeredAt: r.answeredAt,
  };
}
