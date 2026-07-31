// @fleet/dbread-gateway — read-only SQL gateway to the firm's Supabase Postgres.
//
// WHY THIS EXISTS. Tom provisioned a genuine read-only PostgreSQL login
// (claude_readonly: no write grants, default_transaction_read_only=on, BYPASSRLS so it
// can see every row). That is a real, database-enforced control — but it is a Postgres
// credential, not an HTTP API key, and the platform's whole secret model is "the key
// lives in the vault and the egress proxy injects it as an HTTP header; the tenant
// process never sees it". A libpq connection string cannot be injected that way, and
// handing it to the pod would mean the bot itself holds a database password — which a
// prompt-injected agent could exfiltrate (it reads client data, so that risk is real).
//
// So the credential stays HERE, host-side, and tenants get an HTTP endpoint instead.
// Because the underlying role physically cannot write, passing SQL through is safe for
// data integrity even if a tenant is fully compromised; the guards below exist to bound
// blast radius (volume, runtime, verbs), not to be the primary control.
//
// AUTH. A tenant presents `Authorization: Bearer <token>`. We store only the sha256 of
// each token, mapped to its tenant, so the map on disk is not itself a credential. The
// tenant's role is then read from /etc/claude-role/<tenant> and checked against
// role-matrix.json — the SAME single source of truth that drives CLAUDE.md and the vault
// bindings — so a role with no Supabase entitlement is refused here too (fail-closed).
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import Fastify from "fastify";
import pg from "pg";

const HOST = process.env.HOST ?? "127.0.0.1";
const PORT = Number(process.env.PORT ?? 8092);
// Connection parts come from env; ONLY the password comes from a mounted podman secret,
// so the password is never part of a process argument, env var, or log line.
const DB_HOST = process.env.DBREAD_HOST ?? "";
const DB_PORT = Number(process.env.DBREAD_PORT ?? 5432);
const DB_NAME = process.env.DBREAD_DB ?? "";
const DB_USER = process.env.DBREAD_USER ?? "claude_readonly";
const DB_PASSWORD_FILE = process.env.DBREAD_PASSWORD_FILE ?? "";
const TOKENS_FILE = process.env.DBREAD_TOKENS_FILE ?? "/etc/claudeapp/dbread/tokens.json";
const ROLE_MATRIX_FILE = process.env.ROLE_MATRIX_FILE ?? "/etc/claudeapp/dbread/role-matrix.json";
const ROLE_DIR = process.env.CLAUDE_ROLE_DIR ?? "/etc/claude-role";
// Bounds. The role cannot write, so these cap cost/volume rather than enforce safety.
const MAX_ROWS = Number(process.env.DBREAD_MAX_ROWS ?? 1000);
const STATEMENT_TIMEOUT_MS = Number(process.env.DBREAD_STATEMENT_TIMEOUT_MS ?? 15000);
const SERVICE = "supabase"; // the role-matrix service this gateway fronts

const app = Fastify({ logger: { name: "dbread-gateway" } });

if (!DB_HOST || !DB_NAME || !DB_PASSWORD_FILE) {
  app.log.error("DBREAD_HOST, DBREAD_DB and DBREAD_PASSWORD_FILE are required");
  process.exit(1);
}

const password = (await readFile(DB_PASSWORD_FILE, "utf8")).trim();
// DBREAD_SSL=require (default) matches Supabase, which mandates TLS; rejectUnauthorized
// is false because Supabase serves a chain our host store doesn't pin — this is
// `sslmode=require` (encrypt, don't verify), the mode the firm specified. `disable` exists
// so the gateway can be pointed at a plain local Postgres for testing; without it a local
// server rejects the handshake with "the server does not support SSL connections".
const SSL_MODE = process.env.DBREAD_SSL ?? "require";
const pool = new pg.Pool({
  host: DB_HOST,
  port: DB_PORT,
  database: DB_NAME,
  user: DB_USER,
  password,
  ssl: SSL_MODE === "disable" ? false : { rejectUnauthorized: false },
  max: 5,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

// ---- identity ---------------------------------------------------------------
// tokens.json: { "<sha256 of token>": "<tenant os username>" }. Re-read per request so
// granting a new tenant takes effect without restarting the gateway (and so a revoked
// token stops working immediately).
async function tenantForToken(token: string): Promise<string | null> {
  const digest = createHash("sha256").update(token).digest("hex");
  try {
    const map = JSON.parse(await readFile(TOKENS_FILE, "utf8")) as Record<string, string>;
    return map[digest] ?? null;
  } catch {
    return null; // no map / unreadable => nobody is authorised (fail-closed)
  }
}

// Entitlement from role-matrix.json, exactly as CLAUDE.md and the vault bindings compute it.
async function scopeForTenant(tenant: string): Promise<string | null> {
  let role: string;
  try {
    role = (await readFile(`${ROLE_DIR}/${tenant}`, "utf8")).trim();
  } catch {
    return null;
  }
  try {
    const matrix = JSON.parse(await readFile(ROLE_MATRIX_FILE, "utf8"));
    const roles = matrix?.services?.[SERVICE]?.roles ?? {};
    return roles[role] ?? null; // "rw" | "read" | null
  } catch {
    return null;
  }
}

// ---- statement vetting ------------------------------------------------------
// Defence in depth only. The real guarantee is the read-only role + READ ONLY transaction;
// this just rejects obvious non-reads early with a clear message, and refuses stacked
// statements so a single request can't smuggle a second command.
const READ_VERBS = /^(select|with|explain|show|table|values)\b/i;

function vetStatement(sql: string): string | null {
  const trimmed = sql.trim().replace(/;\s*$/, "");
  if (!trimmed) return "empty statement";
  if (!READ_VERBS.test(trimmed)) {
    return "only read statements are allowed (SELECT / WITH / EXPLAIN / SHOW / TABLE / VALUES)";
  }
  if (/;/.test(trimmed)) return "multiple statements are not allowed — send one query per request";
  return null;
}

// ---- routes -----------------------------------------------------------------
app.get("/healthz", async () => ({ ok: true }));

app.post("/query", async (req, reply) => {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!token) return reply.code(401).send({ error: "missing bearer token" });

  const tenant = await tenantForToken(token);
  if (!tenant) return reply.code(401).send({ error: "unknown token" });

  const scope = await scopeForTenant(tenant);
  if (!scope) {
    req.log.warn({ tenant }, "tenant has no Supabase entitlement — refused");
    return reply.code(403).send({ error: "your role has no access to the firm database" });
  }

  const body = (req.body ?? {}) as { sql?: unknown; params?: unknown };
  if (typeof body.sql !== "string") return reply.code(400).send({ error: "body.sql (string) is required" });
  const params = Array.isArray(body.params) ? body.params : [];
  const problem = vetStatement(body.sql);
  if (problem) return reply.code(400).send({ error: problem });

  // Acquire inside its own guard: a connection failure (DB down, wrong password, TLS
  // mismatch) must come back as a controlled message, not Fastify's default 500 with the
  // raw internal error text.
  let client: pg.PoolClient;
  try {
    client = await pool.connect();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    req.log.error({ tenant, message }, "cannot reach the database");
    return reply.code(503).send({ error: `database unavailable: ${message}` });
  }

  try {
    // READ ONLY transaction + statement timeout. Belt and braces on top of a role that
    // already cannot write: if the credential is ever widened by mistake, this still holds.
    await client.query("BEGIN TRANSACTION READ ONLY");
    await client.query(`SET LOCAL statement_timeout = ${STATEMENT_TIMEOUT_MS}`);
    const res = await client.query({ text: body.sql.trim().replace(/;\s*$/, ""), values: params });
    await client.query("COMMIT");
    const rows = res.rows ?? [];
    const truncated = rows.length > MAX_ROWS;
    req.log.info({ tenant, scope, rows: rows.length, truncated }, "query ok");
    return {
      rows: truncated ? rows.slice(0, MAX_ROWS) : rows,
      rowCount: truncated ? MAX_ROWS : rows.length,
      truncated,
      ...(truncated ? { note: `result capped at ${MAX_ROWS} rows — add LIMIT/filters` } : {}),
    };
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    const message = err instanceof Error ? err.message : String(err);
    req.log.warn({ tenant, message }, "query failed");
    // Postgres' own error text is the most useful thing the assistant can act on, and this
    // role is read-only, so echoing it leaks no capability.
    return reply.code(400).send({ error: message });
  } finally {
    client.release();
  }
});

await app.listen({ host: HOST, port: PORT });
