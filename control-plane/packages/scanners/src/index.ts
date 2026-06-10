// @fleet/scanners — the L4/L5/L6 artifact gate (docs 09-security-stack.md).
//
//   scanArtifact() : DETERMINISTIC stage (built-in rules + Cisco YARA when present)
//   → a CRITICAL finding fails fast with NO LLM call; otherwise the artifact +
//   findings go to the Judge Orchestrator (the single LLM-as-judge). Fails CLOSED:
//   any judge error/timeout → verdict "error" → the caller must NOT install.
//
// "plugin" artifacts fan out to all three scanners (caller passes kind per pass).
import fs from "node:fs";
import path from "node:path";
import { contentHash, type AuditEvent } from "@fleet/shared";
import { builtinScan } from "./deterministic.js";
import { ciscoMcpScan, ciscoSkillScan } from "./external.js";
import type { JudgeClient } from "./judge-client.js";
import { maxSeverity, type DeterministicFinding, type ScanInput, type ScanResult } from "./types.js";

export * from "./types.js";
export { httpJudgeClient } from "./judge-client.js";
export type { JudgeClient } from "./judge-client.js";
// Re-exported for boundary-1 callers (e.g. the authoring save flow) that want the
// free deterministic advisory WITHOUT a judge call.
export { builtinScan } from "./deterministic.js";

export const SCAN_RESULT_KIND = "scan.result";

export interface ScanDeps {
  judge: JudgeClient;
  // Best-effort audit emitter (e.g. sendAudit bound to the collector socket).
  audit: (event: AuditEvent) => void;
  defaultRulesetVersion?: string;
}

// Read the artifact text. A file → its contents; a directory (e.g. a skill dir) →
// its text files concatenated (bounded). Inline content always wins when set.
async function resolveContent(input: ScanInput): Promise<string> {
  if (input.content != null) return input.content;
  if (!input.path) throw new Error("scan input has neither content nor path");
  const st = await fs.promises.stat(input.path);
  if (st.isFile()) return fs.promises.readFile(input.path, "utf8");

  const parts: string[] = [];
  let budget = 256 * 1024;
  const walk = async (dir: string) => {
    for (const ent of await fs.promises.readdir(dir, { withFileTypes: true })) {
      if (budget <= 0) return;
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        if (ent.name === "node_modules" || ent.name === ".git") continue;
        await walk(full);
      } else if (/\.(md|js|mjs|ts|json|ya?ml|txt|sh|py)$/i.test(ent.name)) {
        const txt = await fs.promises.readFile(full, "utf8").catch(() => "");
        const slice = txt.slice(0, budget);
        budget -= slice.length;
        parts.push(`# ${full}\n${slice}`);
      }
    }
  };
  await walk(input.path);
  return parts.join("\n\n");
}

function findingsReport(findings: DeterministicFinding[]): string {
  if (!findings.length) return "no deterministic findings";
  return findings.map((f) => `[${f.severity}] ${f.ruleId} (${f.source}): ${f.message}`).join("\n");
}

export async function scanArtifact(deps: ScanDeps, input: ScanInput): Promise<ScanResult> {
  const rulesetVersion = input.rulesetVersion ?? deps.defaultRulesetVersion ?? "r1";
  let content: string;
  try {
    content = await resolveContent(input);
  } catch (err) {
    const result: ScanResult = {
      verdict: "error",
      severity: null,
      decidedBy: "error",
      findings: [],
      reportRef: `content-resolve: ${(err as Error).message}`,
      cacheHit: false,
    };
    emit(deps, input, result);
    return result;
  }

  // ── deterministic stage ──
  const findings = builtinScan(content);
  if (input.path) {
    const ext =
      input.kind === "mcp" ? await ciscoMcpScan(input.path) : input.kind === "skill" ? await ciscoSkillScan(input.path) : null;
    if (ext) findings.push(...ext);
  }

  // A CRITICAL finding is conclusive malware → fail fast, no LLM call.
  if (findings.some((f) => f.severity === "critical")) {
    const result: ScanResult = {
      verdict: "fail",
      severity: "critical",
      decidedBy: "deterministic",
      findings,
      reportRef: findingsReport(findings),
      cacheHit: false,
    };
    emit(deps, input, result);
    return result;
  }

  // ── judge stage (the single LLM-as-judge; fail-closed) ──
  const artifactHash = contentHash(content);
  const contentRef = `inline:${content}\n--- deterministic findings ---\n${findingsReport(findings)}`;
  try {
    const v = await deps.judge({
      artifactHash,
      kind: input.kind,
      contentRef,
      rulesetVersion,
      actor: input.actor,
      userId: input.userId ?? null,
    });
    const result: ScanResult = {
      verdict: v.verdict,
      severity: (v.severity as ScanResult["severity"]) ?? maxSeverity(findings),
      decidedBy: "judge",
      findings,
      reportRef: v.reportRef,
      cacheHit: v.cacheHit,
    };
    emit(deps, input, result);
    return result;
  } catch (err) {
    const result: ScanResult = {
      verdict: "error",
      severity: maxSeverity(findings),
      decidedBy: "error",
      findings,
      reportRef: `judge unreachable: ${(err as Error).message.slice(0, 160)}`,
      cacheHit: false,
    };
    emit(deps, input, result);
    return result;
  }
}

function emit(deps: ScanDeps, input: ScanInput, result: ScanResult): void {
  try {
    deps.audit({
      userId: input.userId ?? null,
      kind: SCAN_RESULT_KIND,
      actor: input.actor,
      payload: {
        scanKind: input.kind,
        verdict: result.verdict,
        severity: result.severity,
        decidedBy: result.decidedBy,
        findingCount: result.findings.length,
        cacheHit: result.cacheHit,
      },
    });
  } catch {
    /* audit is best-effort — never block a gate decision on it */
  }
}
