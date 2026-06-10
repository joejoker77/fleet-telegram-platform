// Shared types for the L4/L5/L6 artifact scanners (docs 09-security-stack.md).
// A scan is a two-stage gate: (1) DETERMINISTIC detection (free, local — YARA via
// the Cisco scanners when installed, plus our own pattern rules); a conclusive
// high/critical finding fails fast with NO LLM call. (2) Whatever is left is sent
// to the Judge Orchestrator (the single LLM-as-judge). Everything fails CLOSED:
// a judge error / timeout blocks the artifact.
import type { JudgeKind } from "@fleet/shared";

// L4 = mcp, L5 = skill, L6 = agentshield (a .claude/ change). "plugin" fans out
// to all three (docs 09). promptfoo (guardian red-team) is WP5, event-driven.
export type ScanKind = JudgeKind; // "mcp" | "skill" | "agentshield" | "promptfoo"

export type Severity = "low" | "medium" | "high" | "critical";

export interface DeterministicFinding {
  ruleId: string;
  severity: Severity;
  message: string;
  source: "builtin" | "cisco-mcp" | "cisco-skill";
}

export interface ScanInput {
  kind: ScanKind;
  // The artifact: a filesystem path (file or dir) and/or inline content. At least
  // one must be set; when both are present the content is what gets judged.
  path?: string;
  content?: string;
  actor: string;
  userId?: string | null;
  rulesetVersion?: string;
}

export interface ScanResult {
  verdict: "pass" | "fail" | "error";
  severity: Severity | null;
  // Which stage produced the verdict — useful for audit + debugging.
  decidedBy: "deterministic" | "judge" | "error";
  findings: DeterministicFinding[];
  reportRef: string | null;
  cacheHit: boolean;
}

// Severity ranking so callers/tests can compare.
export const SEVERITY_RANK: Record<Severity, number> = { low: 1, medium: 2, high: 3, critical: 4 };
export function maxSeverity(findings: DeterministicFinding[]): Severity | null {
  let top: Severity | null = null;
  for (const f of findings) {
    if (!top || SEVERITY_RANK[f.severity] > SEVERITY_RANK[top]) top = f.severity;
  }
  return top;
}
