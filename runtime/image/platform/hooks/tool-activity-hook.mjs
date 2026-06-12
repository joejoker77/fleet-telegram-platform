// Claude Code activity hook (M5.11 live tool stream, M5.12 step semantics).
// Wired on THREE hook events (same command, branches on hook_event_name):
//   PreToolUse   → tool.use  {phase:"start"} — a step began (spinner in UI)
//   PostToolUse  → tool.use  {phase:"end"}   — step finished (ok + duration)
//   SubagentStop → agent.done                — a subagent completed
// `tool_use_id` links start↔end; `agent_id`/`agent_type` (present on every
// hook event fired INSIDE a subagent) let the UI nest those steps under the
// parent Agent row, Cursor-style. NOT an LLM call.
//
// Hard requirements: never blocks or influences the tool (no stdout, exit 0
// always — a PreToolUse hook's stdout can carry a permission decision, so we
// print NOTHING), never throws, fire-and-forget to the collector socket.
//
// Baked read-only into the image; wired via the tenant's ~/.claude/settings.json
// (install/m5.12-live-stream-v2.sh — git HEAD + agentshield rebaseline).
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

// PostToolUse `tool_response` → did the step succeed? Shape varies by tool;
// look for the common failure markers, default to ok.
function respOk(resp) {
  if (resp === null || typeof resp !== "object") return true;
  if (resp.success === false) return false;
  if (resp.is_error === true || resp.isError === true) return false;
  return true;
}

// Build the audit event for one hook invocation, or null to stay silent.
function buildEvent(evt) {
  const name = evt.hook_event_name;
  const sub = {};
  if (typeof evt.agent_id === "string" && evt.agent_id) {
    sub.agentId = evt.agent_id;
    if (typeof evt.agent_type === "string") sub.agentType = evt.agent_type;
  }

  if (name === "SubagentStop") {
    return {
      kind: "agent.done",
      payload: {
        agentId: evt.agent_id ?? null,
        agentType: evt.agent_type ?? null,
        summary: clip(evt.last_assistant_message),
      },
    };
  }

  const tool = evt.tool_name;
  if (!tool) return null;

  if (name === "PostToolUse") {
    const payload = { tool, phase: "end", ...sub };
    if (typeof evt.tool_use_id === "string") payload.tid = evt.tool_use_id;
    if (typeof evt.duration_ms === "number") payload.ms = evt.duration_ms;
    if (!respOk(evt.tool_response)) payload.ok = false;
    return { kind: "tool.use", payload };
  }

  // PreToolUse (and any unknown event that still carries tool_name: degrade
  // to the old single-event stream rather than dropping the step).
  const payload = { tool, summary: summarize(tool, evt.tool_input), phase: "start", ...sub };
  if (typeof evt.tool_use_id === "string") payload.tid = evt.tool_use_id;
  return { kind: "tool.use", payload };
}

function main() {
  let evt = {};
  try {
    evt = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
  } catch {
    /* ignore */
  }
  const built = buildEvent(evt);
  if (!built) return;

  const line =
    JSON.stringify({
      userId: null, // collector resolves tenant by actor (os_username)
      kind: built.kind,
      actor: os.userInfo().username,
      payload: built.payload,
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
