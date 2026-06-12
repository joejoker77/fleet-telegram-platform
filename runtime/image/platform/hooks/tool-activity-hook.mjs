// Claude Code PreToolUse hook (M5.11 live tool stream). Fires before EVERY
// tool call and emits a compact `tool.use` audit event so LiveActivity shows
// the bot's steps in real time: subagent launches, shell commands, file edits,
// skills, MCP calls. Subagents run in the same harness, so their tool calls
// stream too. NOT an LLM call.
//
// Hard requirements: never blocks or influences the tool (no stdout, exit 0
// always — a PreToolUse hook's stdout can carry a permission decision, so we
// print NOTHING), never throws, fire-and-forget to the collector socket.
//
// Baked read-only into the image; wired via the tenant's ~/.claude/settings.json
// (install/m5.11-live-tool-stream.sh — git HEAD + agentshield rebaseline).
import fs from "node:fs";
import net from "node:net";
import os from "node:os";

const SOCK = process.env.AUDIT_SOCKET || "/run/audit/collector.sock";
const CUT = 200; // keep the payload a glanceable one-liner

function clip(s) {
  if (typeof s !== "string") return "";
  const one = s.replace(/\s+/g, " ").trim();
  return one.length > CUT ? one.slice(0, CUT) + "…" : one;
}

// One human line per tool: what is it about to do.
function summarize(tool, inp) {
  if (!inp || typeof inp !== "object") return "";
  switch (tool) {
    case "Bash":
      return clip(inp.command);
    case "Task":
    case "Agent":
      return clip(`${inp.subagent_type ?? "agent"} — ${inp.description ?? inp.prompt ?? ""}`);
    case "Skill":
      return clip(`${inp.skill ?? ""} ${inp.args ?? ""}`);
    case "Read":
    case "Write":
    case "Edit":
      return clip(inp.file_path);
    case "NotebookEdit":
      return clip(inp.notebook_path);
    case "Grep":
    case "Glob":
      return clip(inp.pattern);
    case "WebFetch":
      return clip(inp.url);
    case "WebSearch":
      return clip(inp.query);
    default: {
      // MCP tools etc.: the first non-empty string field is usually the gist.
      for (const v of Object.values(inp)) if (typeof v === "string" && v.trim()) return clip(v);
      return "";
    }
  }
}

function main() {
  let evt = {};
  try {
    evt = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
  } catch {
    /* ignore */
  }
  const tool = evt.tool_name;
  if (!tool) return;

  const line =
    JSON.stringify({
      userId: null, // collector resolves tenant by actor (os_username)
      kind: "tool.use",
      actor: os.userInfo().username,
      payload: { tool, summary: summarize(tool, evt.tool_input) },
    }) + "\n";

  // Fire-and-forget: write and leave — unlike the metering Stop hook we never
  // wait for the collector's ack (this path is on the latency of every tool).
  const sock = net.connect(SOCK, () => sock.end(line));
  const done = () => {
    try {
      sock.destroy();
    } catch {
      /* noop */
    }
  };
  sock.on("error", done);
  sock.on("close", done);
  sock.setTimeout(500, done);
}

main();
