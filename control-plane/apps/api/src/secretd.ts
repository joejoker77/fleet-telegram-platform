// M5.5b — client for the cp-secretd privileged helper (host-side, socket-
// activated; runtime/secretd/cp-secretd.py). One JSON line in, one out.
// The helper — not this client — enforces the hard invariants (name
// convention, vitaliy-bot-only binds, no value echo); treat this as transport.
import net from "node:net";

export interface SecretdResponse {
  ok: boolean;
  error?: string;
  exists?: boolean;
  bound?: boolean;
  staged?: string;
  rotated?: boolean;
  deleted?: boolean;
}

export function callSecretd(
  socketPath: string,
  request: Record<string, unknown>,
  timeoutMs = 75_000, // stage = several onecli calls; instance TimeoutStartSec=90
): Promise<SecretdResponse> {
  return new Promise((resolve) => {
    let buf = "";
    let done = false;
    const finish = (resp: SecretdResponse) => {
      if (done) return;
      done = true;
      resolve(resp);
    };
    const sock = net.connect(socketPath, () => {
      sock.write(JSON.stringify(request) + "\n");
      // half-close: the helper reads one line; FIN guarantees EOF semantics
      sock.end();
    });
    sock.setTimeout(timeoutMs, () => {
      sock.destroy();
      finish({ ok: false, error: "cp-secretd: таймаут" });
    });
    sock.on("data", (c) => {
      buf += c.toString();
    });
    sock.on("close", () => {
      try {
        finish(JSON.parse(buf) as SecretdResponse);
      } catch {
        finish({ ok: false, error: "cp-secretd: пустой/некорректный ответ" });
      }
    });
    sock.on("error", (e: NodeJS.ErrnoException) => {
      const hint =
        e.code === "ENOENT" || e.code === "ECONNREFUSED"
          ? "cp-secretd недоступен (установлен ли m5.5b-secretd.sh на хосте?)"
          : `cp-secretd: ${e.code ?? e.message}`;
      finish({ ok: false, error: hint });
    });
  });
}
