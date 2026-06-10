// M5.4 LiveActivity — live stream of the tenant's own audit events over
// ws /live. Read-only window into "what is my bot doing right now": every
// attributed audit record (auth, fs writes, usage turns, …) appears here the
// moment audit-collector commits it. Best-effort by design — missed events
// are still in the WORM audit file; this screen never claims completeness.

import { useEffect, useRef, useState } from "react";

import { liveWsUrl, type LiveEvent } from "../api";

const MAX_EVENTS = 200; // keep memory bounded on long-lived screens

type ConnState = "connecting" | "open" | "closed";

export function LiveActivity({ token, onClose }: { token: string; onClose: () => void }) {
  const [events, setEvents] = useState<LiveEvent[]>([]);
  const [conn, setConn] = useState<ConnState>("connecting");
  const [expanded, setExpanded] = useState<number | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

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
          setEvents((prev) => [ev, ...prev].slice(0, MAX_EVENTS));
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
      {events.length === 0 ? (
        <p className="muted">
          Пока пусто. Здесь в реальном времени появляются события бота: авторизации, изменения файлов,
          расход токенов. Лента best-effort — полная история в журнале аудита.
        </p>
      ) : (
        <ul className="live-list">
          {events.map((ev, i) => (
            <li key={`${ev.ts}-${i}`} className="live-row" onClick={() => setExpanded(expanded === i ? null : i)}>
              <div className="live-line">
                <span className="live-kind">{kindIcon(ev.kind)} {ev.kind}</span>
                <span className="live-ts">{shortTs(ev.ts)}</span>
              </div>
              {ev.actor && <div className="live-actor">{ev.actor}</div>}
              {expanded === i && ev.payload !== undefined && (
                <pre className="content live-payload">{JSON.stringify(ev.payload, null, 2)}</pre>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function shortTs(ts: string): string {
  // "2026-06-10T14:03:21.123Z" → "14:03:21"
  const m = /T(\d{2}:\d{2}:\d{2})/.exec(ts);
  return m?.[1] ?? ts;
}

function kindIcon(kind: string): string {
  if (kind === "live.hello") return "👋";
  if (kind.startsWith("auth.")) return "🔑";
  if (kind.startsWith("fs.")) return "📝";
  if (kind.startsWith("usage.")) return "📊";
  return "•";
}
