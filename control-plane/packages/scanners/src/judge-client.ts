// HTTP client to the Judge Orchestrator (cp-judge). The scanners are the ONLY
// thing that calls /judge — the single LLM-as-judge point. Injected as a function
// so tests can stub it without a running cp-judge.
import { judgeResponse, type JudgeKind, type JudgeResponse } from "@fleet/shared";

export interface JudgeCallInput {
  artifactHash: string;
  kind: JudgeKind;
  contentRef: string;
  rulesetVersion: string;
  actor: string;
  userId: string | null;
}

export type JudgeClient = (input: JudgeCallInput) => Promise<JudgeResponse>;

export function httpJudgeClient(baseUrl: string, timeoutMs = 35_000): JudgeClient {
  return async (input) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(`${baseUrl}/judge`, {
        method: "POST",
        signal: controller.signal,
        headers: { "content-type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) throw new Error(`judge HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
      return judgeResponse.parse(await res.json());
    } finally {
      clearTimeout(timer);
    }
  };
}
