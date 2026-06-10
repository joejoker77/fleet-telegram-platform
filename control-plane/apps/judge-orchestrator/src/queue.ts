// BullMQ wiring (docs 09: "Очередь (BullMQ) + rate-limit + circuit breaker").
// The queue gives us: (a) job-id coalescing — concurrent identical requests share
// ONE worker run, so two callers can never both trigger an LLM call for the same
// (artifact,ruleset,model); (b) a global rate limiter on the capped judge key;
// (c) bounded concurrency. The breaker lives in the worker (in-process) since it
// guards the single shared upstream.
import { Queue, Worker, QueueEvents, type Job } from "bullmq";
import { Redis } from "ioredis";
import type { JudgeRequest } from "@fleet/shared";
import type { Config } from "./config.js";
import { judgeOne, type JudgeDeps, type JudgeResult } from "./core.js";

export const JUDGE_QUEUE = "judge";

export interface JudgeJobData {
  req: JudgeRequest;
  content: string;
}

// Deterministic job id = the dedup key. BullMQ refuses to add a second job with
// an id that already exists (waiting/active), so duplicates coalesce onto one run.
export function jobIdFor(req: JudgeRequest, modelVersion: string): string {
  return `${req.artifactHash}:${req.rulesetVersion}:${modelVersion}`;
}

// BullMQ requires its own blocking connections (maxRetriesPerRequest=null).
function conn(redisUrl: string): Redis {
  return new Redis(redisUrl, { maxRetriesPerRequest: null });
}

export interface JudgeQueue {
  enqueueAndWait(req: JudgeRequest, content: string): Promise<JudgeResult>;
  close(): Promise<void>;
}

export function startJudgeQueue(
  cfg: Config,
  deps: JudgeDeps,
  onVerdict: (req: JudgeRequest, result: JudgeResult) => void,
): JudgeQueue {
  const queue = new Queue<JudgeJobData, JudgeResult>(JUDGE_QUEUE, { connection: conn(cfg.redisUrl) });
  const events = new QueueEvents(JUDGE_QUEUE, { connection: conn(cfg.redisUrl) });

  const worker = new Worker<JudgeJobData, JudgeResult>(
    JUDGE_QUEUE,
    async (job: Job<JudgeJobData, JudgeResult>) => {
      const result = await judgeOne(deps, job.data.req, job.data.content);
      // Emit the verdict to the audit chain from the single authoritative run.
      onVerdict(job.data.req, result);
      return result;
    },
    {
      connection: conn(cfg.redisUrl),
      concurrency: cfg.concurrency,
      limiter: { max: cfg.rateMax, duration: cfg.rateDurationMs },
    },
  );

  async function enqueueAndWait(req: JudgeRequest, content: string): Promise<JudgeResult> {
    const jobId = jobIdFor(req, cfg.modelVersion);
    const job = await queue.add(
      "judge",
      { req, content },
      { jobId, removeOnComplete: true, removeOnFail: true, attempts: 1 },
    );
    // Wait for THIS job's completion (coalesced duplicates await the same job).
    return (await job.waitUntilFinished(events, cfg.judgeTimeoutMs)) as JudgeResult;
  }

  async function close(): Promise<void> {
    await worker.close();
    await events.close();
    await queue.close();
  }

  return { enqueueAndWait, close };
}
