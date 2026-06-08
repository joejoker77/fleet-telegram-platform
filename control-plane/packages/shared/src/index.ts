// Shared zod contracts + types for control-plane services. The api validates
// every request/response against these; the Mini App (M5) imports the inferred
// types. Only the M1 surface (auth + profile) is defined now; later milestones
// add builders/registry/usage/approvals contracts here.

import { z } from "zod";

// ── enum mirrors (kept in sync with @fleet/db schema enums) ──
export const userStatus = z.enum([
  "provisioned",
  "active",
  "idle",
  "suspended",
  "deleted",
]);
export const subTier = z.enum(["base", "extended"]);

// ── POST /auth/session ──
// Body carries the raw Telegram WebApp initData query string; the api verifies
// its HMAC against the bot token (fetched from OneCLI, never a file) before
// trusting any field inside it.
export const authSessionRequest = z.object({
  initData: z.string().min(1),
});
export const authSessionResponse = z.object({
  token: z.string(), // short-lived JWT, also tracked in Redis
  expiresAt: z.string().datetime(),
});

// ── GET /me ──
export const meResponse = z.object({
  telegramUserId: z.number().int(),
  osUsername: z.string(),
  role: z.string().nullable(),
  isAdmin: z.boolean(),
  status: userStatus,
  tier: subTier.nullable(),
});

export type AuthSessionRequest = z.infer<typeof authSessionRequest>;
export type AuthSessionResponse = z.infer<typeof authSessionResponse>;
export type MeResponse = z.infer<typeof meResponse>;

// ── audit record (written to audit-collector over the unix socket) ──
// hash/prev_hash are filled by the collector, not the caller.
export const auditEvent = z.object({
  userId: z.string().uuid().nullable(),
  kind: z.string().min(1), // e.g. "auth.session", "fs.write", "provision.create"
  actor: z.string().min(1), // service or os_username that caused the event
  payload: z.record(z.unknown()).default({}),
});
export type AuditEvent = z.infer<typeof auditEvent>;
