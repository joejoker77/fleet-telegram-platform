// Shared zod contracts + types for control-plane services. The api validates
// every request/response against these; the Mini App (M5) imports the inferred
// types. Only the M1 surface (auth + profile) is defined now; later milestones
// add builders/registry/usage/approvals contracts here.

import { createHash } from "node:crypto";
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

// A committed audit record: the event plus the chain fields the collector adds.
export const auditRecord = auditEvent.extend({
  ts: z.string().datetime(),
  prevHash: z.string(),
  hash: z.string(),
});
export type AuditRecord = z.infer<typeof auditRecord>;

// Genesis link for the very first record in a chain.
export const AUDIT_GENESIS_HASH = "0".repeat(64);

// Deterministic JSON: object keys sorted recursively, so the same logical
// payload always hashes identically regardless of key insertion order.
export function canonicalize(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value as Record<string, unknown>)
        .sort()
        .map((k) => [k, sortKeys((value as Record<string, unknown>)[k])]),
    );
  }
  return value;
}

// ── usage metering (ADR-001: per-tenant token usage from Claude Code + audit) ──
// The container's Stop hook emits an auditEvent with kind = USAGE_TURN_KIND and a
// usageTurnPayload; the audit-collector also records it in usage_records. Tokens
// only (subscription is flat-rate — no $; this is for visibility / fair-use).
export const USAGE_TURN_KIND = "usage.turn";
export const usageTurnPayload = z.object({
  model: z.string().default("unknown"),
  inputTokens: z.number().int().nonnegative().default(0),
  outputTokens: z.number().int().nonnegative().default(0),
  cacheReadTokens: z.number().int().nonnegative().default(0),
  cacheCreationTokens: z.number().int().nonnegative().default(0),
});
export type UsageTurnPayload = z.infer<typeof usageTurnPayload>;

// Chain hash = sha256(prevHash + canonical(core)). The core is the immutable
// content of the record (everything except prevHash/hash). Pure + dependency-free
// (node:crypto) so the collector and any verifier compute identical hashes.
export function chainHash(
  prevHash: string,
  core: { ts: string; userId: string | null; kind: string; actor: string; payload: Record<string, unknown> },
): string {
  return createHash("sha256").update(prevHash).update(canonicalize(core)).digest("hex");
}

// ── Judge Orchestrator (M4 / docs 09-security-stack.md) ──
// The SINGLE LLM-as-judge entry point for the artifact scanners (L4 MCP, L5
// Skill, L6 AgentShield/Promptfoo). It is called ONLY on save/publish/import
// events — never on a schedule (hard rule: zero recurring LLM calls, see
// feedback_no_recurring_llm_calls — the $360/day incident). Content-hash dedup +
// a verdict cache guarantee the same artifact is never judged twice.
export const judgeKind = z.enum(["mcp", "skill", "agentshield", "promptfoo"]);
export type JudgeKind = z.infer<typeof judgeKind>;
export const judgeVerdict = z.enum(["pass", "fail", "error"]);
export type JudgeVerdict = z.infer<typeof judgeVerdict>;

// POST /judge request. `artifactHash` is the sha256 of the canonical artifact
// content (the dedup key, together with rulesetVersion + the judge model
// version). `contentRef` points the judge at the artifact + the scanner's
// deterministic (YARA/AST) pre-report; the judge only adjudicates the ambiguous
// remainder. `userId`/`actor` attribute the verdict in the audit chain.
export const judgeRequest = z.object({
  artifactHash: z.string().regex(/^[a-f0-9]{64}$/, "must be a sha256 hex digest"),
  kind: judgeKind,
  contentRef: z.string().min(1),
  rulesetVersion: z.string().min(1),
  actor: z.string().min(1),
  userId: z.string().uuid().nullable().default(null),
});
export type JudgeRequest = z.infer<typeof judgeRequest>;

export const judgeResponse = z.object({
  verdict: judgeVerdict,
  severity: z.string().nullable(),
  cacheHit: z.boolean(),
  reportRef: z.string().nullable(),
});
export type JudgeResponse = z.infer<typeof judgeResponse>;

// sha256 of an artifact's canonical content — the dedup key callers compute and
// pass as judgeRequest.artifactHash. Same helper both sides → identical hashes.
export function contentHash(content: string): string {
  return createHash("sha256").update(content).digest("hex");
}

// Audit kinds emitted by the judge-orchestrator (every request + every verdict
// lands in the tamper-resistant chain — the "all scanner verdicts → audit"
// requirement of docs 09).
export const JUDGE_REQUEST_KIND = "judge.request";
export const JUDGE_VERDICT_KIND = "judge.verdict";
