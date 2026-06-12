// M5.4 LiveActivity → M5.12 Cursor-style step stream.
//
// Raw audit events (ws /live) are folded into TURN CARDS rendered top-down in
// chronological order: every tool call is one human-readable step row; steps
// fired inside a subagent (payload.agentId set — Claude Code adds agent_id to
// every hook event inside a Task/Agent run) nest under the parent Agent row,
// collapsed once the subagent finishes. `phase:"start"/"end"` pairs matched by
// `tid` (tool_use_id) drive spinner → ✓/duration. A usage.turn event closes
// the card with a compact footer (model · tokens · cache). Raw JSON of any
// step stays one tap away. Best-effort by design — missed events are still in
// the WORM audit file; this screen never claims completeness.

import { useEffect, useMemo, useRef, useState } from "react";

import { liveWsUrl, type LiveEvent } from "../api";

const MAX_EVENTS = 500; // keep memory bounded on long-lived screens

type ConnState = "connecting" | "open" | "closed";

// ── fold raw events into turns/steps ──────────────────────────────────────

interface Step {
  key: string; // stable render key (tid or ts-index)
  tool: string;
  summary: string;
  ts: string;
  status: "running" | "done" | "failed" | "instant"; // instant = no end event expected (legacy hook)
  ms?: number;
  agentId?: string; // set on child steps
  children?: Step[]; // set on Agent/Task steps
  agentType?: string; // resolved subagent type (Agent rows)
  agentResult?: string; // subagent's final message clip (agent.done)
  raw: unknown;
}

interface Turn {
  key: string;
  steps: Step[];
  usage?: Record<string, unknown>; // usage.turn payload → footer
}

function payloadOf(ev: LiveEvent): Record<string, unknown> | null {
  return ev.payload !== null && typeof ev.payload === "object" ? (ev.payload as Record<string, unknown>) : null;
}

function fold(events: LiveEvent[]): Turn[] {
  const turns: Turn[] = [];
  let cur: Turn | null = null;
  const open = (ts: string): Turn => {
    if (!cur) {
      cur = { key: `t${turns.length}-${ts}`, steps: [] };
      turns.push(cur);
    }
    return cur;
  };
  // tid → step, for matching phase:"end"; agentId → host Agent step, for nesting.
  const byTid = new Map<string, Step>();
  const agentHosts = new Map<string, Step>();

  events.forEach((ev, i) => {
    const p = payloadOf(ev);

    if (ev.kind === "usage.turn") {
      open(ev.ts).usage = p ?? {};
      cur = null; // next event starts a fresh card
      return;
    }

    if (ev.kind === "agent.done" && p) {
      const host = typeof p.agentId === "string" ? agentHosts.get(p.agentId) : undefined;
      if (host) {
        if (host.status === "running") host.status = "done";
        if (typeof p.summary === "string") host.agentResult = p.summary;
      }
      return;
    }

    if (ev.kind !== "tool.use" || !p) {
      // auth.*, fs.*, live.hello, … — plain rows in the current card.
      open(ev.ts).steps.push({
        key: `${ev.ts}-${i}`,
        tool: ev.kind,
        summary: typeof p?.path === "string" ? p.path : "",
        ts: ev.ts,
        status: "instant",
        raw: ev.payload,
      });
      return;
    }

    const tool = typeof p.tool === "string" ? p.tool : "?";
    const tid = typeof p.tid === "string" ? p.tid : null;
    const agentId = typeof p.agentId === "string" ? p.agentId : null;

    if (p.phase === "end") {
      const step = tid ? byTid.get(tid) : undefined;
      if (step) {
        step.status = p.ok === false ? "failed" : "done";
        if (typeof p.ms === "number") step.ms = p.ms;
      }
      return;
    }

    // phase:"start" (or legacy event without phase — render as instant).
    const step: Step = {
      key: tid ?? `${ev.ts}-${i}`,
      tool,
      summary: typeof p.summary === "string" ? p.summary : "",
      ts: ev.ts,
      status: p.phase === "start" && tid ? "running" : "instant",
      raw: ev.payload,
    };
    if (tid) byTid.set(tid, step);

    if (agentId) {
      // Child step: nest under its subagent's Agent row. First child of an
      // unseen agentId claims the most recent unclaimed running Agent step
      // (sequential workflows always match; parallel agents are approximate).
      step.agentId = agentId;
      let host = agentHosts.get(agentId);
      if (!host) {
        const t = open(ev.ts);
        for (let s = t.steps.length - 1; s >= 0 && !host; s--) {
          const cand = t.steps[s];
          if (cand && (cand.tool === "Agent" || cand.tool === "Task") && cand.children && !cand.agentType) host = cand;
        }
        if (!host) {
          // Agent start event lost (best-effort stream) — synthesize the host row.
          host = { key: `agent-${agentId}`, tool: "Agent", summary: "", ts: ev.ts, status: "running", children: [], raw: null };
          t.steps.push(host);
        }
        host.agentType = typeof p.agentType === "string" ? p.agentType : "subagent";
        agentHosts.set(agentId, host);
      }
      host.children!.push(step);
      return;
    }

    if (tool === "Agent" || tool === "Task") step.children = [];
    open(ev.ts).steps.push(step);
  });

  return turns;
}

// ── human labels ───────────────────────────────────────────────────────────

const MCP_LABEL: [RegExp, (s: string) => string][] = [
  [/telegram__reply$/, () => "Отвечает в Telegram"],
  [/telegram__react$/, () => "Реакция на сообщение"],
  [/telegram__edit_message$/, () => "Редактирует сообщение"],
  [/telegram__status_update$/, () => "Статус в Telegram"],
  [/exa__web_search/, (s) => `Ищет в вебе: ${s}`],
  [/exa__crawling/, (s) => `Читает страницу: ${s}`],
  [/exa__deep_researcher/, () => "Глубокое исследование"],
];

function base(p: string): string {
  return p.split("/").filter(Boolean).pop() ?? p;
}

function stepLabel(s: Step): { icon: string; text: string; mono?: string } {
  const t = s.tool;
  const sum = s.summary;
  if (t === "Agent" || t === "Task")
    return { icon: "🤖", text: `Субагент${s.agentType ? ` ${s.agentType}` : ""}${sum ? `: ${sum.split("—").slice(1).join("—").trim() || sum}` : ""}` };
  if (t === "Bash") return { icon: "🖥", text: "Терминал", mono: sum };
  if (t === "Read") return { icon: "📖", text: `Читает ${base(sum)}` };
  if (t === "Write") return { icon: "📄", text: `Создаёт ${base(sum)}` };
  if (t === "Edit" || t === "NotebookEdit") return { icon: "✏️", text: `Правит ${base(sum)}` };
  if (t === "Grep" || t === "Glob") return { icon: "🔎", text: `Ищет в коде: ${sum}` };
  if (t === "Skill") return { icon: "🧩", text: `Скилл /${sum}` };
  if (t === "ToolSearch") return { icon: "🔧", text: "Подключает инструмент" };
  if (t === "WebSearch") return { icon: "🌐", text: `Ищет в вебе: ${sum}` };
  if (t === "WebFetch") return { icon: "🌐", text: `Открывает ${sum}` };
  if (t === "Workflow") return { icon: "🛠", text: `Workflow: ${sum}` };
  if (/^Task(Create|Update|Get|List)$/.test(t)) return { icon: "📋", text: "Задачник" };
  if (t.startsWith("mcp__")) {
    for (const [re, f] of MCP_LABEL) if (re.test(t)) return { icon: "💬", text: f(sum) };
    const short = t.replace(/^mcp__/, "").replace(/__/g, " · ");
    return { icon: "🔌", text: `${short}${sum ? `: ${sum}` : ""}` };
  }
  // non-tool kinds folded as instant rows
  if (t === "live.hello") return { icon: "👋", text: "Подключение к стриму" };
  if (t.startsWith("auth.")) return { icon: "🔑", text: "Авторизация" };
  if (t.startsWith("fs.")) return { icon: "📝", text: `Файл: ${sum}` };
  return { icon: "⚙️", text: `${t}${sum ? `: ${sum}` : ""}` };
}

function fmtTokens(n: number): string {
  return n >= 10_000 ? `${Math.round(n / 1000)}k` : String(n);
}

function usageLine(u: Record<string, unknown>): string {
  const n = (k: string) => (typeof u[k] === "number" ? (u[k] as number) : 0);
  const model = typeof u.model === "string" ? u.model.replace(/^claude-/, "") : "?";
  return `${model} · ↑${fmtTokens(n("inputTokens"))} ↓${fmtTokens(n("outputTokens"))} · кеш ${fmtTokens(n("cacheReadTokens"))}r/${fmtTokens(n("cacheCreationTokens"))}w`;
}

function fmtMs(ms?: number): string | null {
  if (typeof ms !== "number") return null;
  return ms < 1000 ? `${ms}мс` : `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)}с`;
}

function shortTs(ts: string): string {
  const m = /T(\d{2}:\d{2}:\d{2})/.exec(ts);
  return m?.[1] ?? ts;
}

// ── components ─────────────────────────────────────────────────────────────

function StatusMark({ s }: { s: Step["status"] }) {
  if (s === "running") return <span className="step-spin" aria-label="выполняется" />;
  if (s === "failed") return <span className="step-mark step-fail">✗</span>;
  if (s === "done") return <span className="step-mark step-ok">✓</span>;
  return <span className="step-mark step-dot">·</span>;
}

function StepRow({ step, depth }: { step: Step; depth: number }) {
  // Agent rows: expanded while running, auto-collapse when done; tap toggles.
  const [openOverride, setOpenOverride] = useState<boolean | null>(null);
  const [showRaw, setShowRaw] = useState(false);
  const isAgent = step.children !== undefined;
  const open = openOverride ?? step.status === "running";
  const { icon, text, mono } = stepLabel(step);
  const dur = fmtMs(step.ms);

  return (
    <li className={`step-row${depth ? " step-child" : ""}`}>
      <div
        className="step-line"
        onClick={() => (isAgent ? setOpenOverride(!open) : setShowRaw(!showRaw))}
      >
        <StatusMark s={step.status} />
        <span className="step-icon">{icon}</span>
        <span className="step-text">
          {text}
          {mono && <code className="step-mono">{mono}</code>}
        </span>
        {dur && <span className="step-dur">{dur}</span>}
        {isAgent && <span className="step-chev">{open ? "▾" : `▸ ${step.children!.length}`}</span>}
      </div>
      {isAgent && open && (
        <>
          <ul className="step-children">
            {step.children!.map((c) => (
              <StepRow key={c.key} step={c} depth={depth + 1} />
            ))}
          </ul>
          {step.agentResult && <div className="step-result">→ {step.agentResult}</div>}
        </>
      )}
      {!isAgent && showRaw && step.raw !== null && step.raw !== undefined && (
        <pre className="content live-payload">{JSON.stringify(step.raw, null, 2)}</pre>
      )}
    </li>
  );
}

export function LiveActivity({ token, onClose }: { token: string; onClose: () => void }) {
  const [events, setEvents] = useState<LiveEvent[]>([]);
  const [conn, setConn] = useState<ConnState>("connecting");
  const wsRef = useRef<WebSocket | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const stickBottom = useRef(true); // auto-scroll unless the user scrolled up

  useEffect(() => {
    // One reconnect-on-drop loop per mount. The JWT may expire mid-stream
    // (close 4401); surface that as "closed" instead of retrying forever.
    let disposed = false;
    let retryTimer: number | undefined;

    const connect = () => {
      if (disposed) return;
      setConn("connecting");
      const ws = new WebSocket(liveWsUrl(token));
      wsRef.current = ws;

      ws.onopen = () => setConn("open");
      ws.onmessage = (msg) => {
        try {
          const ev = JSON.parse(String(msg.data)) as LiveEvent;
          setEvents((prev) => [...prev, ev].slice(-MAX_EVENTS)); // chronological
        } catch {
          /* non-JSON frame — ignore */
        }
      };
      ws.onclose = (e) => {
        if (disposed) return;
        setConn("closed");
        // 4401 = auth rejected (expired/revoked session) — don't hammer the
        // server with a token that will never work; user can reopen the screen.
        if (e.code !== 4401) retryTimer = window.setTimeout(connect, 3000);
      };
      ws.onerror = () => {
        /* onclose follows and handles retry */
      };
    };

    connect();
    return () => {
      disposed = true;
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      wsRef.current?.close();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  const turns = useMemo(() => fold(events), [events]);

  // Stick to bottom while new steps stream in (Cursor-style follow mode).
  useEffect(() => {
    const el = scrollRef.current;
    if (el && stickBottom.current) el.scrollTop = el.scrollHeight;
  }, [turns]);

  return (
    <div className="fileview">
      <div className="fileview-header">
        <button className="ghost" onClick={onClose}>
          ←
        </button>
        <span className="path">Live-активность</span>
        <span className={`live-dot live-${conn}`} title={conn} />
      </div>
      {conn === "closed" && <p className="warn">Соединение закрыто. Переподключение…</p>}
      {turns.length === 0 ? (
        <p className="muted">
          Пока пусто. Здесь в реальном времени появляются шаги бота: запуск субагентов, команды,
          правки файлов, ответы в Telegram. Лента best-effort — полная история в журнале аудита.
        </p>
      ) : (
        <div
          className="live-scroll"
          ref={scrollRef}
          onScroll={(e) => {
            const el = e.currentTarget;
            stickBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
          }}
        >
          {turns.map((turn) => (
            <div className="turn-card" key={turn.key}>
              <div className="turn-head">
                <span>{turn.steps[0] ? shortTs(turn.steps[0].ts) : ""}</span>
                {!turn.usage && <span className="turn-live">сейчас</span>}
              </div>
              <ul className="step-list">
                {turn.steps.map((s) => (
                  <StepRow key={s.key} step={s} depth={0} />
                ))}
              </ul>
              {turn.usage && <div className="turn-usage">📊 {usageLine(turn.usage)}</div>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
