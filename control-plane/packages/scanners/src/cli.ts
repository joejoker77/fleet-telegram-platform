// fleet-scan — the reusable gate any install/authoring path calls. Scans one
// artifact and exits: 0 = pass, 2 = fail (block the install), 3 = error
// (fail-closed → also block). Prints the ScanResult as JSON on stdout.
//
//   tsx packages/scanners/src/cli.ts <mcp|skill|agentshield|plugin> <path> [actor]
//   env: JUDGE_URL (default http://127.0.0.1:8090), AUDIT_SOCKET (best-effort)
//
// "plugin" fans out to all three scanners; the worst verdict wins.
import net from "node:net";
import { scanArtifact, httpJudgeClient, type ScanKind, type ScanResult } from "./index.js";
import type { AuditEvent } from "@fleet/shared";

const [, , kindArg, target, actorArg] = process.argv;
if (!kindArg || !target) {
  console.error("usage: fleet-scan <mcp|skill|agentshield|plugin> <path> [actor]");
  process.exit(64);
}
const actor = actorArg ?? "fleet-scan";
const JUDGE_URL = process.env.JUDGE_URL ?? "http://127.0.0.1:8090";
const AUDIT_SOCKET = process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock";

// Best-effort audit (never throws / blocks; skipped if the socket is absent).
function socketAudit(event: AuditEvent): void {
  try {
    const sock = net.connect(AUDIT_SOCKET, () => {
      sock.write(JSON.stringify(event) + "\n");
    });
    sock.on("data", () => sock.end());
    sock.on("error", () => {});
    sock.setTimeout(500, () => sock.destroy());
  } catch {
    /* no audit socket here — fine */
  }
}

const deps = { judge: httpJudgeClient(JUDGE_URL), audit: socketAudit };

const KINDS: ScanKind[] = kindArg === "plugin" ? ["mcp", "skill", "agentshield"] : [kindArg as ScanKind];

function worst(results: ScanResult[]): ScanResult {
  // error > fail > pass
  const rank = (v: string) => (v === "error" ? 3 : v === "fail" ? 2 : 1);
  return results.reduce((a, b) => (rank(b.verdict) > rank(a.verdict) ? b : a));
}

const results: ScanResult[] = [];
for (const kind of KINDS) {
  results.push(await scanArtifact(deps, { kind, path: target, actor }));
}
const result = worst(results);
console.log(JSON.stringify(result, null, 2));
process.exit(result.verdict === "pass" ? 0 : result.verdict === "fail" ? 2 : 3);
