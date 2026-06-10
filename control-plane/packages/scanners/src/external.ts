// Optional adapters for the Cisco scanners (L4 mcp-scanner, L5 skill-scanner) when
// installed on the host. They add YARA / readiness / prompt-defense / behavioral
// findings to the deterministic stage. DEGRADES GRACEFULLY: if a binary is absent
// the adapter returns null and the scan relies on the built-in rules + the Judge
// Orchestrator backstop — no hard dependency on the Cisco tools being present.
//
// Invocations match the validated old-stack usage (see project_security_stack):
//   mcp-scanner --analyzers yara,readiness,prompt_defense --format json config --config-path <PATH>
//   skill-scanner scan-all --recursive --format json --output-json <TMP>
// NOTE: the exact JSON shapes must be confirmed against the live binaries on the
// host (not present in the bot's pod). Until confirmed, unparseable-but-non-empty
// scanner output is surfaced as a single MEDIUM "needs-review" finding so it goes
// to the judge rather than being silently dropped or auto-failing.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { DeterministicFinding, Severity } from "./types.js";

const pexec = promisify(execFile);

function has(bin: string): boolean {
  return ["/usr/local/bin", "/usr/bin", "/bin"].some((d) => {
    try {
      fs.accessSync(path.join(d, bin), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function normSeverity(s: unknown): Severity {
  const v = String(s ?? "").toLowerCase();
  if (v === "critical") return "critical";
  if (v === "high") return "high";
  if (v === "low") return "low";
  return "medium";
}

// Best-effort: collect {severity, rule/threat, message}-shaped objects anywhere in
// the parsed JSON tree (the Cisco tools nest findings differently per analyzer).
function harvestFindings(json: unknown, source: DeterministicFinding["source"]): DeterministicFinding[] {
  const out: DeterministicFinding[] = [];
  const walk = (n: unknown) => {
    if (Array.isArray(n)) return n.forEach(walk);
    if (n && typeof n === "object") {
      const o = n as Record<string, unknown>;
      if ("severity" in o && ("rule_id" in o || "threat" in o || "rule" in o || "message" in o)) {
        out.push({
          ruleId: String(o.rule_id ?? o.rule ?? o.threat ?? "cisco"),
          severity: normSeverity(o.severity),
          message: String(o.message ?? o.threat ?? o.description ?? "cisco finding"),
          source,
        });
      }
      Object.values(o).forEach(walk);
    }
  };
  walk(json);
  return out;
}

async function runJson(
  bin: string,
  args: string[],
  source: DeterministicFinding["source"],
): Promise<DeterministicFinding[] | null> {
  if (!has(bin)) return null;
  try {
    const { stdout } = await pexec(bin, args, { timeout: 60_000, maxBuffer: 8 * 1024 * 1024 });
    const trimmed = stdout.trim();
    if (!trimmed) return [];
    try {
      return harvestFindings(JSON.parse(trimmed), source);
    } catch {
      // non-JSON but non-empty → let the judge decide rather than drop/auto-fail
      return [{ ruleId: `${source}.unparsed`, severity: "medium", message: "scanner output needs review", source }];
    }
  } catch (err) {
    // scanner crashed / non-zero — surface as medium "needs review" (fail-open here,
    // fail-closed happens at the judge stage which still runs)
    return [{ ruleId: `${source}.error`, severity: "medium", message: `scanner error: ${(err as Error).message.slice(0, 120)}`, source }];
  }
}

export async function ciscoMcpScan(configPath: string): Promise<DeterministicFinding[] | null> {
  return runJson(
    "mcp-scanner",
    ["--analyzers", "yara,readiness,prompt_defense", "--format", "json", "config", "--config-path", configPath],
    "cisco-mcp",
  );
}

export async function ciscoSkillScan(dirPath: string): Promise<DeterministicFinding[] | null> {
  const tmp = path.join(os.tmpdir(), `skillscan-${process.pid}-${Date.now()}.json`);
  const res = await runJson(
    "skill-scanner",
    ["scan-all", "--recursive", "--format", "json", "--output-json", tmp, dirPath],
    "cisco-skill",
  );
  // skill-scanner writes findings to --output-json; prefer that file if present.
  try {
    if (fs.existsSync(tmp)) {
      const parsed = JSON.parse(fs.readFileSync(tmp, "utf8"));
      fs.unlinkSync(tmp);
      return harvestFindings(parsed, "cisco-skill");
    }
  } catch {
    /* fall through to stdout-derived result */
  }
  return res;
}
