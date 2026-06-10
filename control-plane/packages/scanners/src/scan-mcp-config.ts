// Gate every mcpServers entry in a settings.json through the scanner gate (L4).
// Used to wire MCP installs: deploy-mcp (or the mcp-installer flow) calls this on
// the candidate settings.json BEFORE applying it — any fail/error blocks the apply.
//
//   tsx packages/scanners/src/scan-mcp-config.ts <settings.json> [actor]
//   exit: 0 = all MCP stanzas pass · 2 = at least one blocked · 3 = judge error
//
// Each stanza is scanned as its own artifact (command/args/url/env/headers) so a
// malicious server config (curl|bash command, exfil URL, secret in env) is caught
// by the deterministic stage, and anything subtler goes to the judge.
import fs from "node:fs";
import net from "node:net";
import { scanArtifact, httpJudgeClient, type ScanResult } from "./index.js";
import type { AuditEvent } from "@fleet/shared";

const [, , settingsPath, actorArg] = process.argv;
if (!settingsPath) {
  console.error("usage: scan-mcp-config <settings.json> [actor]");
  process.exit(64);
}
const actor = actorArg ?? "mcp-gate";
const JUDGE_URL = process.env.JUDGE_URL ?? "http://127.0.0.1:8090";
const AUDIT_SOCKET = process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock";

function socketAudit(event: AuditEvent): void {
  try {
    const sock = net.connect(AUDIT_SOCKET, () => sock.write(JSON.stringify(event) + "\n"));
    sock.on("data", () => sock.end());
    sock.on("error", () => {});
    sock.setTimeout(500, () => sock.destroy());
  } catch {
    /* fine */
  }
}
const deps = { judge: httpJudgeClient(JUDGE_URL), audit: socketAudit };

const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8")) as {
  mcpServers?: Record<string, unknown>;
};
const servers = settings.mcpServers ?? {};
const names = Object.keys(servers);
if (names.length === 0) {
  console.log("no mcpServers in settings — nothing to gate");
  process.exit(0);
}

let worst: ScanResult["verdict"] = "pass";
const blocked: string[] = [];
for (const name of names) {
  const stanza = JSON.stringify({ [name]: servers[name] }, null, 2);
  const r = await scanArtifact(deps, { kind: "mcp", content: stanza, actor });
  console.log(`  ${name}: ${r.verdict}${r.severity ? ` (${r.severity})` : ""} by=${r.decidedBy}`);
  if (r.verdict !== "pass") {
    blocked.push(`${name} → ${r.verdict}: ${String(r.reportRef).slice(0, 140)}`);
    if (r.verdict === "error" || worst === "pass") worst = r.verdict;
  }
}

if (blocked.length) {
  console.error(`\n${blocked.length} MCP stanza(s) BLOCKED:`);
  blocked.forEach((b) => console.error(`  ✗ ${b}`));
}
console.log(`\nmcp-config gate: ${blocked.length ? "BLOCK" : "OK"} (${names.length} scanned)`);
process.exit(worst === "pass" ? 0 : worst === "error" ? 3 : 2);
