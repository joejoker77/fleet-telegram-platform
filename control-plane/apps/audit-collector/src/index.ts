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
import {
  auditEvent,
  auditRecord,
  chainHash,
  AUDIT_GENESIS_HASH,
  type AuditRecord,
} from "@fleet/shared";
import { getDb, getPool, schema } from "@fleet/db";

const log = pino({ name: "audit-collector" });

const SOCKET = process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock";
const DIR = process.env.AUDIT_DIR ?? "/srv/audit";

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
    // 0o660: owner (cplane) + group can write; tenants get the group via the
    // bind-mounted socket and can only write, never read AUDIT_DIR.
    fs.chmodSync(SOCKET, 0o660);
    log.info({ socket: SOCKET, dir: DIR }, "audit-collector listening");
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
