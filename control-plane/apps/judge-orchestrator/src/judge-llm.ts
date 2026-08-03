// The single LLM-as-judge call (docs 09: single-pass — one assessment per artefact,
// with no iterative refinement). Invoked ONLY on a cache-miss, ONLY from inside
// the rate-limited + circuit-broken worker — never on a schedule, never recursively
// (the judge is told it is the terminal authority and must not request sub-judging;
// the orchestrator also never calls /judge from within a judge run). One request,
// one verdict, hard output-token budget.
import type { JudgeKind, JudgeVerdict } from "@fleet/shared";
import type { Config } from "./config.js";

export interface JudgeOutcome {
  verdict: JudgeVerdict;
  severity: string | null;
  report: string;
}

export interface JudgeLlmInput {
  kind: JudgeKind;
  artifactHash: string;
  contentRef: string;
  content: string;
}

// The judge function signature — injected into the core so it can be stubbed in
// tests and swapped if the provider ever changes. The default impl is judgeWithLlm.
export type JudgeFn = (cfg: Config, input: JudgeLlmInput) => Promise<JudgeOutcome>;

const SYSTEM_PROMPT = [
  "You are the terminal security judge for an AI-agent artifact scanner.",
  "You receive an artifact (an MCP server, skill, plugin, or a .claude change) plus",
  "the deterministic pre-scan report (YARA / AST dataflow findings). Decide whether",
  "installing it is SAFE.",
  "",
  "Rules:",
  "- Single pass. Do NOT ask for more information, do NOT request another judging",
  "  round, do NOT propose sub-tasks. You are the only and final judge.",
  "- Output STRICT JSON only: {\"verdict\":\"pass|fail\",\"severity\":\"low|medium|high|critical|null\",\"reason\":\"<one sentence>\"}.",
  "- Default to fail when uncertain — a wrongly-installed malicious artifact is far",
  "  worse than a false reject the user can appeal.",
].join("\n");

// Calls OpenRouter chat-completions once. Throws on any transport/HTTP/parse
// failure so the worker records a breaker failure and the caller fails-closed.
export const judgeWithLlm: JudgeFn = async (cfg, input): Promise<JudgeOutcome> => {
  if (!cfg.openrouterKey) {
    throw new Error("no OPENROUTER_API_KEY configured — judge cannot run (fail-closed)");
  }

  const userPrompt = [
    `kind: ${input.kind}`,
    `artifact_hash: ${input.artifactHash}`,
    `content_ref: ${input.contentRef}`,
    "--- artifact + deterministic pre-scan report ---",
    input.content,
  ].join("\n");

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.judgeTimeoutMs);
  let res: Response;
  try {
    res = await fetch(`${cfg.openrouterBaseUrl}/chat/completions`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${cfg.openrouterKey}`,
        "x-title": "fleet-judge-orchestrator",
      },
      body: JSON.stringify({
        model: cfg.judgeModel,
        max_tokens: cfg.budgetMaxOutputTokens, // hard single-pass budget ceiling
        temperature: 0,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: userPrompt },
        ],
      }),
    });
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) {
    throw new Error(`judge upstream ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const data = (await res.json()) as {
    choices?: { finish_reason?: string; message?: { content?: string } }[];
  };
  const choice = data.choices?.[0];
  const raw = choice?.message?.content?.trim();
  if (!raw) throw new Error("judge returned empty content");
  // Budget overrun: the model hit max_tokens before finishing → untrustworthy
  // partial JSON. Treat as a failure (fail-closed), not a pass.
  if (choice?.finish_reason === "length") {
    throw new Error("judge hit output-token budget before completing (fail-closed)");
  }

  let parsed: { verdict?: string; severity?: string | null; reason?: string };
  try {
    parsed = JSON.parse(extractJson(raw));
  } catch {
    throw new Error(`judge returned non-JSON verdict: ${raw.slice(0, 160)}`);
  }
  const verdict: JudgeVerdict = parsed.verdict === "pass" ? "pass" : "fail";
  const severity =
    parsed.severity && parsed.severity !== "null" ? String(parsed.severity) : null;
  return { verdict, severity, report: parsed.reason ?? raw.slice(0, 500) };
};

// Tolerate a model that wraps JSON in prose / code fences.
function extractJson(s: string): string {
  const fenced = s.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced?.[1]) return fenced[1].trim();
  const start = s.indexOf("{");
  const end = s.lastIndexOf("}");
  if (start >= 0 && end > start) return s.slice(start, end + 1);
  return s;
}
