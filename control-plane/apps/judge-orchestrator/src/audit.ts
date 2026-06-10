// Best-effort audit client (same contract as @fleet/api's): write one NDJSON
// event to the audit-collector unix socket. Never throws, never blocks long —
// a transient audit gap is itself visible as a chain discontinuity, and a
// scanner verdict must not be lost because the sink blinked.
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
