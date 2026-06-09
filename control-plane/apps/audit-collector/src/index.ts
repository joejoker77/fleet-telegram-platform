// @fleet/audit-collector — append-only, tamper-resistant audit sink (M1.3).
//
// Listens on a unix socket and writes each event as a hash-chained NDJSON record
// to an append-only WORM file in AUDIT_DIR, and indexes it in audit_index (PG).
// Each record's hash covers the previous record's hash, so any insertion,
// deletion, or edit anywhere in the chain is detectable (see verify.ts).
//
// Tenants/containers are given write-only access to the socket (group perms +
// bind-mount); they cannot read or mutate AUDIT_DIR. WORM enforcement (chattr +a
// on AUDIT_DIR) is applied by the host installer (M1.5); the collector only ever
// appends, so it works whether or not the append-only attr is set.

import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { pino } from "pino";
import { eq } from "drizzle-orm";
import {
  auditEvent,
  auditRecord,
  chainHash,
  AUDIT_GENESIS_HASH,
  USAGE_TURN_KIND,
  usageTurnPayload,
  type AuditRecord,
} from "@fleet/shared";
import { getDb, getPool, schema } from "@fleet/db";

const log = pino({ name: "audit-collector" });

const SOCKET = process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock";
const DIR = process.env.AUDIT_DIR ?? "/srv/audit";
// Group that owns the socket. Tenant containers join this group (--group-add) to
// get write-only access to the socket (mode 0660) without any read/mutate access
// to AUDIT_DIR. The installer creates a system group `audit` and passes its gid in
// AUDIT_GID (resolved by name on the host, so the product is portable across
// servers regardless of the assigned number). Absent → socket stays owner-only.
const AUDIT_GID =
  process.env.AUDIT_GID && /^\d+$/.test(process.env.AUDIT_GID)
    ? Number(process.env.AUDIT_GID)
    : null;

// Single-writer model: one process owns the chain head, serialised below.
let prevHash = AUDIT_GENESIS_HASH;
let writeChain: Promise<unknown> = Promise.resolve();

function currentFile(): string {
  // One file per UTC day. ts is supplied per-record; the file is chosen at
  // write time so a long-running collector rolls over at midnight.
  const day = new Date().toISOString().slice(0, 10);
  return path.join(DIR, `audit-${day}.log`);
}

// Recover the chain head from the newest existing record so restarts continue
// the same chain instead of forking a new genesis.
async function recoverHead(): Promise<void> {
  const files = fs
    .readdirSync(DIR)
    .filter((f) => f.startsWith("audit-") && f.endsWith(".log"))
    .sort();
  const last = files.at(-1);
  if (!last) return;
  const full = path.join(DIR, last);
  let lastLine = "";
  await new Promise<void>((resolve) => {
    const rl = readline.createInterface({ input: fs.createReadStream(full) });
    rl.on("line", (l) => {
      if (l.trim()) lastLine = l;
    });
    rl.on("close", resolve);
  });
  if (lastLine) {
    const parsed = auditRecord.safeParse(JSON.parse(lastLine));
    if (parsed.success) {
      prevHash = parsed.data.hash;
      log.info({ recoveredFrom: last, head: prevHash.slice(0, 12) }, "recovered chain head");
    }
  }
}

async function commit(raw: unknown): Promise<AuditRecord> {
  const event = auditEvent.parse(raw);
  const ts = new Date().toISOString();
  const core = {
    ts,
    userId: event.userId,
    kind: event.kind,
    actor: event.actor,
    payload: event.payload,
  };
  const hash = chainHash(prevHash, core);
  const record: AuditRecord = { ...core, prevHash, hash };

  // Append first (the durable WORM record), then index. If indexing fails the
  // record still exists in the WORM file — the file is the source of truth.
  fs.appendFileSync(currentFile(), JSON.stringify(record) + "\n");
  prevHash = hash;

  try {
    await getDb().insert(schema.auditIndex).values({
      userId: event.userId,
      kind: event.kind,
      ref: hash,
    });
  } catch (err) {
    log.error({ err, hash: hash.slice(0, 12) }, "audit_index insert failed (record persisted to WORM)");
  }

  // Usage metering: a usage.turn event also lands in usage_records (tokens only;
  // flat subscription has no $). Resolve the tenant by actor (os_username) when
  // the hook didn't supply a user_id.
  if (event.kind === USAGE_TURN_KIND) {
    try {
      const up = usageTurnPayload.parse(event.payload);
      let userId = event.userId;
      if (!userId) {
        const u = await getDb()
          .select({ id: schema.users.id })
          .from(schema.users)
          .where(eq(schema.users.osUsername, event.actor))
          .limit(1);
        userId = u[0]?.id ?? null;
      }
      if (userId) {
        await getDb().insert(schema.usageRecords).values({
          userId,
          window: ts.slice(0, 10),
          tokens: up.inputTokens + up.outputTokens,
          model: up.model,
        });
      } else {
        log.warn({ actor: event.actor }, "usage.turn: no tenant matched actor; usage_records skipped");
      }
    } catch (err) {
      log.error({ err }, "usage_records insert failed");
    }
  }
  return record;
}

function handleConnection(sock: net.Socket): void {
  const rl = readline.createInterface({ input: sock });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    // Serialise all writes through a single promise chain to keep the hash
    // chain strictly ordered even under concurrent connections.
    writeChain = writeChain.then(async () => {
      try {
        const rec = await commit(JSON.parse(line));
        sock.write(JSON.stringify({ ok: true, hash: rec.hash }) + "\n");
      } catch (err) {
        log.warn({ err }, "rejected audit line");
        sock.write(JSON.stringify({ ok: false, error: (err as Error).message }) + "\n");
      }
    });
  });
  sock.on("error", (err) => log.warn({ err }, "socket error"));
}

async function main(): Promise<void> {
  fs.mkdirSync(DIR, { recursive: true });
  await recoverHead();

  // Remove a stale socket from a previous run before binding.
  try {
    fs.unlinkSync(SOCKET);
  } catch {
    /* not present — fine */
  }
  fs.mkdirSync(path.dirname(SOCKET), { recursive: true });

  const server = net.createServer(handleConnection);
  server.listen(SOCKET, () => {
    // 0o660: owner + the `audit` group can write; tenants join that group
    // (--group-add) via the bind-mounted socket and can only write, never read
    // AUDIT_DIR. chgrp to the audit gid so group-write actually reaches tenants.
    fs.chmodSync(SOCKET, 0o660);
    if (AUDIT_GID != null) {
      try {
        fs.chownSync(SOCKET, process.getuid?.() ?? 0, AUDIT_GID);
      } catch (err) {
        log.warn({ err, AUDIT_GID }, "could not set socket group to audit gid (tenants may be unable to write)");
      }
    }
    log.info({ socket: SOCKET, dir: DIR, auditGid: AUDIT_GID }, "audit-collector listening");
  });

  const shutdown = () => {
    server.close();
    getPool()
      .end()
      .finally(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  log.fatal({ err }, "audit-collector failed to start");
  process.exit(1);
});
