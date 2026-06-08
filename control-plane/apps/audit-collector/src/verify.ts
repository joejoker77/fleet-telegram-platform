// Audit chain verifier. Recomputes the hash chain across all WORM files in
// AUDIT_DIR (chronological) and reports the first break — a tampered, inserted,
// reordered, or deleted record. Read-only.
//
// Run: AUDIT_DIR=/srv/audit pnpm --filter @fleet/audit-collector exec tsx src/verify.ts
// Exits 0 if the chain is intact, 1 otherwise.

import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { auditRecord, chainHash, AUDIT_GENESIS_HASH } from "@fleet/shared";

const DIR = process.env.AUDIT_DIR ?? "/srv/audit";

async function main(): Promise<void> {
  const files = fs.existsSync(DIR)
    ? fs
        .readdirSync(DIR)
        .filter((f) => f.startsWith("audit-") && f.endsWith(".log"))
        .sort()
    : [];

  if (files.length === 0) {
    console.log(`no audit files in ${DIR} — empty chain is trivially valid`);
    return;
  }

  let prev = AUDIT_GENESIS_HASH;
  let count = 0;

  for (const file of files) {
    const full = path.join(DIR, file);
    const rl = readline.createInterface({ input: fs.createReadStream(full) });
    let lineNo = 0;
    for await (const line of rl) {
      lineNo++;
      if (!line.trim()) continue;
      count++;

      const parsed = auditRecord.safeParse(JSON.parse(line));
      if (!parsed.success) fail(file, lineNo, "record does not match schema");
      const rec = parsed.data;

      if (rec.prevHash !== prev) {
        fail(file, lineNo, `broken link: prevHash=${rec.prevHash.slice(0, 12)} expected ${prev.slice(0, 12)}`);
      }
      const recomputed = chainHash(rec.prevHash, {
        ts: rec.ts,
        userId: rec.userId,
        kind: rec.kind,
        actor: rec.actor,
        payload: rec.payload,
      });
      if (recomputed !== rec.hash) {
        fail(file, lineNo, `content tampered: stored hash ${rec.hash.slice(0, 12)} != recomputed ${recomputed.slice(0, 12)}`);
      }
      prev = rec.hash;
    }
  }

  console.log(`chain OK: ${count} record(s) across ${files.length} file(s), head=${prev.slice(0, 12)}`);
}

function fail(file: string, line: number, why: string): never {
  console.error(`CHAIN BROKEN at ${file}:${line} — ${why}`);
  process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
