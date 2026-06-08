// M2.5 test helper: emit a synthetic usage.turn event to the audit-collector
// socket (simulates what the container Stop hook sends). Run inside cp-api/
// cp-audit-collector (which mount the socket). ACTOR must match a users row.
import net from "node:net";
const SOCK = process.env.AUDIT_SOCKET || "/run/audit/collector.sock";
const line =
  JSON.stringify({
    userId: null,
    kind: "usage.turn",
    actor: process.env.ACTOR || "vitaliy",
    payload: { model: "claude-test-model", inputTokens: 1000, outputTokens: 500 },
  }) + "\n";
const s = net.connect(SOCK, () => s.write(line));
s.on("data", (d) => {
  console.log("collector ack:", d.toString().trim());
  s.destroy();
});
s.on("error", (e) => {
  console.log("socket error:", e.message);
  process.exit(1);
});
s.setTimeout(1500, () => s.destroy());
