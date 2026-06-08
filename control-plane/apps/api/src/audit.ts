// Best-effort audit client: write one NDJSON event to the audit-collector unix
// socket. Never throws and never blocks the caller for long — auth must not fail
// because the audit sink is briefly unavailable (the collector is the durable
// record of record; transient gaps are themselves visible as chain continuity).
import net from "node:net";
import type { AuditEvent } from "@fleet/shared";

export function sendAudit(socketPath: string, event: AuditEvent): Promise<void> {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      resolve();
    };
    const sock = net.connect(socketPath, () => {
      sock.write(JSON.stringify(event) + "\n");
    });
    sock.on("data", () => {
      sock.end();
      finish();
    });
    sock.on("error", finish);
    sock.setTimeout(500, () => {
      sock.destroy();
      finish();
    });
  });
}
