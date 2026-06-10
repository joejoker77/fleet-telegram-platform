// Built-in deterministic detection rules — free, local, no LLM. These run for
// every artifact (and are the whole of L6 AgentShield's fast path: hardcoded
// secrets, hook-injection, prompt-injection, credential/exfil patterns). The
// Cisco YARA scanners (external.ts) add more when installed. A high/critical hit
// here fails the artifact WITHOUT an LLM call; lower/none → the Judge Orchestrator
// adjudicates. Conservative by design: these are signatures of malware, not style.
import type { DeterministicFinding, Severity } from "./types.js";

interface Rule {
  id: string;
  severity: Severity;
  message: string;
  re: RegExp;
}

const RULES: Rule[] = [
  // ── credential / secret exfiltration (critical) ──
  {
    id: "exfil.credentials_file",
    severity: "critical",
    message: "Reads Claude/credential files (.credentials.json / .claude.json / id_rsa)",
    re: /\.credentials\.json|\.claude\.json|id_rsa|\.aws\/credentials|\.netrc/i,
  },
  {
    id: "exfil.env_dump",
    severity: "high",
    message: "Dumps environment variables (printenv / `env` / process.env) — possible secret exfiltration",
    re: /\bprintenv\b|\benv\s*\||\bprocess\.env\b[\s\S]{0,40}(post|fetch|send|exfil|http)/i,
  },
  // ── remote-script execution (critical) ──
  {
    id: "rce.curl_pipe_shell",
    severity: "critical",
    message: "Pipes a remote download into a shell (curl/wget … | bash/sh)",
    re: /\b(curl|wget|fetch)\b[^\n|]*\|\s*(bash|sh|zsh|python|node)\b/i,
  },
  {
    id: "rce.eval_exec",
    severity: "high",
    message: "Evaluates/executes a dynamic string (eval / exec / Function constructor / child_process)",
    re: /\beval\s*\(|\bexec\s*\(|\bnew\s+Function\s*\(|child_process|\bos\.system\b|subprocess\.(Popen|call|run)/i,
  },
  // ── hook / settings injection (high) — L6 AgentShield core ──
  {
    id: "inject.claude_hooks",
    severity: "high",
    message: "Writes Claude hooks / settings (PreToolUse/PostToolUse/settings.json) — privilege injection",
    re: /PreToolUse|PostToolUse|UserPromptSubmit|\.claude\/settings(\.local)?\.json|"hooks"\s*:/i,
  },
  // ── prompt injection markers (medium → let the judge weigh context) ──
  {
    id: "inject.prompt_override",
    severity: "medium",
    message: "Contains prompt-injection phrasing (ignore previous instructions / system override / do not tell the user)",
    re: /ignore (all |the )?(previous|prior|above) instructions|disregard (your|the) (system|guardian)|do not (tell|inform|notify) the user|reveal your system prompt/i,
  },
  // ── reverse shell / netcat (critical) ──
  {
    id: "rce.reverse_shell",
    severity: "critical",
    message: "Reverse-shell / netcat pattern",
    re: /\bnc\b[^\n]*-e\b|\/dev\/tcp\/|bash\s+-i\s*>&|mkfifo[^\n]*\|\s*(nc|sh)\b/i,
  },
];

export function builtinScan(content: string): DeterministicFinding[] {
  const out: DeterministicFinding[] = [];
  for (const r of RULES) {
    if (r.re.test(content)) {
      out.push({ ruleId: r.id, severity: r.severity, message: r.message, source: "builtin" });
    }
  }
  return out;
}
