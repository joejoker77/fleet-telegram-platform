// Claude Code Stop hook (M2.5 metering). On each turn completion Claude Code
// invokes this with a JSON event on stdin that includes `transcript_path`. We
// read the last assistant message's token usage from the transcript and emit a
// usage.turn audit event to the audit-collector unix socket. Best-effort and
// fast: never throws, never blocks the turn for long; NOT an LLM call.
//
// Baked read-only into the image; wired via settings.platform.json hooks.
import fs from "node:fs";
import net from "node:net";
import os from "node:os";

const SOCK = process.env.AUDIT_SOCKET || "/run/audit/collector.sock";

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

// Find the last assistant message with a usage block in the JSONL transcript.
function lastUsage(transcriptPath) {
  try {
    const lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const ln = lines[i].trim();
      if (!ln) continue;
      let o;
      try {
        o = JSON.parse(ln);
      } catch {
        continue;
      }
      const msg = o.message ?? o;
      const u = msg?.usage;
      if (u && (u.input_tokens != null || u.output_tokens != null)) {
        return {
          model: msg.model || "unknown",
          inputTokens: u.input_tokens || 0,
          outputTokens: u.output_tokens || 0,
          cacheReadTokens: u.cache_read_input_tokens || 0,
          cacheCreationTokens: u.cache_creation_input_tokens || 0,
        };
      }
    }
  } catch {
    /* no transcript / unreadable — skip */
  }
  return null;
}

function main() {
  let evt = {};
  try {
    evt = JSON.parse(readStdin() || "{}");
  } catch {
    /* ignore */
  }
  const tp = evt.transcript_path;
  if (!tp) return;
  const usage = lastUsage(tp);
  if (!usage) return;

  const line =
    JSON.stringify({
      userId: null, // collector resolves tenant by actor (os_username)
      kind: "usage.turn",
      actor: os.userInfo().username,
      payload: usage,
    }) + "\n";

  const sock = net.connect(SOCK, () => sock.write(line));
  const done = () => {
    try {
      sock.destroy();
    } catch {
      /* noop */
    }
  };
  sock.on("data", done);
  sock.on("error", done);
  sock.setTimeout(800, done);
}

main();
