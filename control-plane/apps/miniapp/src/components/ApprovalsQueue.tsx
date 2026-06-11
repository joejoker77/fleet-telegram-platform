// M5.4b ApprovalsQueue — pending platform approvals (✅/❌) + history.
// Realtime: reuses the /live ws; any approval.* audit event triggers a refetch
// (the event payload is not trusted as state — the list endpoint is, and it
// also lazily expires overdue rows server-side).

import { useCallback, useEffect, useRef, useState } from "react";

import { approvalAnswer, approvalsList, liveWsUrl, ApiError, type Approval } from "../api";

export function ApprovalsQueue({ token, onClose }: { token: string; onClose: () => void }) {
  const [approvals, setApprovals] = useState<Approval[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null); // approval id being answered
  const wsRef = useRef<WebSocket | null>(null);

  const refetch = useCallback(async () => {
    try {
      const res = await approvalsList(token);
      setApprovals(res.approvals);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [token]);

  useEffect(() => {
    void refetch();
    // Refetch on approval.* live events; ws drop is fine — the list is still
    // manually refreshable and answers refetch anyway.
    const ws = new WebSocket(liveWsUrl(token));
    wsRef.current = ws;
    ws.onmessage = (msg) => {
      try {
        const ev = JSON.parse(String(msg.data)) as { kind?: string };
        if (ev.kind?.startsWith("approval.")) void refetch();
      } catch {
        /* ignore non-JSON frames */
      }
    };
    return () => ws.close();
  }, [token, refetch]);

  async function answer(id: string, decision: "allow" | "deny") {
    setBusy(id);
    try {
      await approvalAnswer(token, id, decision);
    } catch (e) {
      // 404 = already answered/expired elsewhere — the refetch below shows the truth
      if (!(e instanceof ApiError && e.status === 404)) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setBusy(null);
      void refetch();
    }
  }

  const pending = (approvals ?? []).filter((a) => a.status === "pending");
  const history = (approvals ?? []).filter((a) => a.status !== "pending");

  return (
    <div className="fileview">
      <div className="fileview-header">
        <button className="ghost" onClick={onClose}>
          ←
        </button>
        <span className="path">Аппрувы</span>
        <button className="ghost" onClick={() => void refetch()} title="Обновить">
          ⟳
        </button>
      </div>
      {error && <p className="error">{error}</p>}
      {approvals === null ? (
        <p className="muted">Загрузка…</p>
      ) : (
        <>
          {pending.length === 0 ? (
            <p className="muted">Нет запросов, ждущих решения.</p>
          ) : (
            <ul className="live-list">
              {pending.map((a) => (
                <li key={a.id} className="approval-card">
                  <div className="live-line">
                    <span className="live-kind">{a.title}</span>
                    <span className="live-ts">{shortTs(a.createdAt)}</span>
                  </div>
                  <div className="live-actor">{a.kind}</div>
                  {a.payload != null && (
                    <details>
                      <summary className="muted">детали запроса</summary>
                      <pre className="content live-payload">{JSON.stringify(a.payload, null, 2)}</pre>
                    </details>
                  )}
                  <div className="toolbar approval-actions">
                    <button className="primary" disabled={busy === a.id} onClick={() => void answer(a.id, "allow")}>
                      ✅ Разрешить
                    </button>
                    <button disabled={busy === a.id} onClick={() => void answer(a.id, "deny")}>
                      ❌ Отклонить
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}
          {history.length > 0 && (
            <>
              <p className="muted">История</p>
              <ul className="live-list">
                {history.map((a) => (
                  <li key={a.id} className="live-row">
                    <div className="live-line">
                      <span>
                        {statusIcon(a.status)} {a.title}
                      </span>
                      <span className="live-ts">{shortTs(a.answeredAt ?? a.createdAt)}</span>
                    </div>
                    <div className="live-actor">
                      {a.kind} · {statusLabel(a.status)}
                    </div>
                  </li>
                ))}
              </ul>
            </>
          )}
        </>
      )}
    </div>
  );
}

function shortTs(iso: string): string {
  const m = /T(\d{2}:\d{2})/.exec(iso);
  const d = iso.slice(5, 10); // MM-DD
  return m ? `${d} ${m[1]}` : iso;
}

function statusIcon(s: Approval["status"]): string {
  return s === "allowed" ? "✅" : s === "denied" ? "❌" : "⏳";
}

function statusLabel(s: Approval["status"]): string {
  return s === "allowed" ? "разрешено" : s === "denied" ? "отклонено" : "истекло (= отказ)";
}
