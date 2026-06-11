// Fleet platform — control plane metadata schema (M1, doc 07-control-plane.md).
// This is the source of truth for the Postgres schema; drizzle-kit derives
// idempotent migrations from it. Keep 1:1 with the DDL in doc 07 unless a
// change is recorded there first.

import {
  pgTable,
  pgEnum,
  uuid,
  text,
  boolean,
  timestamp,
  bigint,
  integer,
  numeric,
  jsonb,
  bigserial,
  primaryKey,
  uniqueIndex,
  type AnyPgColumn,
} from "drizzle-orm/pg-core";

// ───────────────────────── enums ─────────────────────────
export const userStatus = pgEnum("user_status", [
  "provisioned",
  "active",
  "idle",
  "suspended",
  "deleted",
]);
export const subTier = pgEnum("sub_tier", ["base", "extended"]);
export const artifactType = pgEnum("artifact_type", [
  "skill",
  "subagent",
  "command",
  "mcp",
  "workflow",
  "plugin",
]);
export const scannerKind = pgEnum("scanner_kind", [
  "mcp",
  "skill",
  "agentshield",
  "promptfoo",
]);
export const verdictKind = pgEnum("verdict_kind", ["pass", "fail", "error"]);
export const approvalStatus = pgEnum("approval_status", [
  "pending",
  "allowed",
  "denied",
  "expired",
]);

// ───────────────────────── tables ─────────────────────────
export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  telegramUserId: bigint("telegram_user_id", { mode: "number" }).notNull().unique(),
  osUsername: text("os_username").notNull().unique(),
  role: text("role"),
  isAdmin: boolean("is_admin").notNull().default(false),
  status: userStatus("status").notNull().default("provisioned"),
  approvedBy: uuid("approved_by").references((): AnyPgColumn => users.id),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const subscriptions = pgTable("subscriptions", {
  userId: uuid("user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  tier: subTier("tier").notNull(),
  status: text("status").notNull(), // active/expired/...
  validUntil: timestamp("valid_until", { withTimezone: true }),
  anthropicSeat: text("anthropic_seat"), // ref to Team member/seat (one per user)
});

export const containers = pgTable("containers", {
  userId: uuid("user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  containerId: text("container_id"),
  state: text("state").notNull(), // running/paused/stopped
  cpuWeight: integer("cpu_weight"),
  cpuQuota: integer("cpu_quota"),
  memHigh: bigint("mem_high", { mode: "number" }),
  memMax: bigint("mem_max", { mode: "number" }),
  lastActiveAt: timestamp("last_active_at", { withTimezone: true }),
});

export const sessions = pgTable("sessions", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").references(() => users.id, { onDelete: "cascade" }),
  sessionName: text("session_name").notNull(),
  claudeSessionId: text("claude_session_id"),
  state: text("state").notNull(), // active/idle/closed
  startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
  lastMessageAt: timestamp("last_message_at", { withTimezone: true }),
});

export const artifacts = pgTable("artifacts", {
  id: uuid("id").primaryKey().defaultRandom(),
  ownerUserId: uuid("owner_user_id").references(() => users.id),
  type: artifactType("type").notNull(),
  name: text("name").notNull(),
  visibility: text("visibility").notNull().default("private"), // public/private/selective
});

export const artifactVersions = pgTable("artifact_versions", {
  id: uuid("id").primaryKey().defaultRandom(),
  artifactId: uuid("artifact_id").references(() => artifacts.id, { onDelete: "cascade" }),
  version: text("version").notNull(),
  gitRef: text("git_ref"),
  provenance: jsonb("provenance"),
  publishedAt: timestamp("published_at", { withTimezone: true }),
});

export const scanResults = pgTable("scan_results", {
  id: uuid("id").primaryKey().defaultRandom(),
  artifactVersionId: uuid("artifact_version_id").references(() => artifactVersions.id, {
    onDelete: "cascade",
  }),
  scanner: scannerKind("scanner").notNull(),
  verdict: verdictKind("verdict").notNull(),
  severity: text("severity"),
  reportRef: text("report_ref"),
  judgeCacheHit: boolean("judge_cache_hit"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const installs = pgTable(
  "installs",
  {
    userId: uuid("user_id").references(() => users.id, { onDelete: "cascade" }),
    artifactVersionId: uuid("artifact_version_id").references(() => artifactVersions.id),
    installedAt: timestamp("installed_at", { withTimezone: true }).notNull().defaultNow(),
    pinnedVersion: text("pinned_version"),
  },
  (t) => [primaryKey({ columns: [t.userId, t.artifactVersionId] })],
);

export const usageRecords = pgTable("usage_records", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  userId: uuid("user_id").references(() => users.id, { onDelete: "cascade" }),
  window: text("window"),
  tokens: bigint("tokens", { mode: "number" }),
  compute: numeric("compute"),
  model: text("model"),
  ts: timestamp("ts", { withTimezone: true }).notNull().defaultNow(),
});

export const secretBindings = pgTable("secret_bindings", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").references(() => users.id, { onDelete: "cascade" }),
  placeholder: text("placeholder").notNull(),
  host: text("host").notNull(),
  path: text("path"),
  injection: jsonb("injection"), // metadata only; real values live in onecli vault
});

// Durable verdict cache for the Judge Orchestrator (M4). The dedup key is
// (artifact_hash, ruleset_version, model_version): the same artifact under the
// same ruleset + judge model is NEVER re-judged — a cache hit returns instantly
// with no LLM call. Survives a Redis flush (Redis is the hot tier in front of
// this). scan_results links an artifact_version to its scan; this table is the
// content-addressed judge cache that backs the dedup guarantee.
export const judgeVerdicts = pgTable(
  "judge_verdicts",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    artifactHash: text("artifact_hash").notNull(),
    kind: scannerKind("kind").notNull(),
    rulesetVersion: text("ruleset_version").notNull(),
    modelVersion: text("model_version").notNull(),
    verdict: verdictKind("verdict").notNull(),
    severity: text("severity"),
    reportRef: text("report_ref"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex("judge_verdicts_key").on(t.artifactHash, t.rulesetVersion, t.modelVersion)],
);

// M5.4b platform approvals — questions asked by the CONTROL PLANE (not by a
// Claude Code session; in-session tool approvals stay with the telegram plugin).
// First client: M5.5 MCP-connect gate. Answered from the Mini App over HTTPS;
// expiry is lazy (evaluated on read/wait) — no cron. See docs/M5.4b-approvals-design.md.
export const approvals = pgTable("approvals", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  kind: text("kind").notNull(), // mcp.connect | artifact.import | test | …
  title: text("title").notNull(),
  payload: jsonb("payload"),
  status: approvalStatus("status").notNull().default("pending"),
  answeredVia: text("answered_via"), // miniapp | timeout
  ttlSeconds: integer("ttl_seconds").notNull().default(120),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  answeredAt: timestamp("answered_at", { withTimezone: true }),
});

// Only an index of audit records; the records themselves live in the WORM store.
export const auditIndex = pgTable("audit_index", {
  id: bigserial("id", { mode: "number" }).primaryKey(),
  userId: uuid("user_id"),
  kind: text("kind"),
  ref: text("ref"),
  ts: timestamp("ts", { withTimezone: true }).notNull().defaultNow(),
});
