// M5.7 SessionsManager — named project sessions: list (active badge), create,
// switch. A switch respawns the bot's claude pane in the project dir, so it
// interrupts whatever the bot is doing — the confirm() warning is mandatory.
// The switch call is synchronous (≤90s): the pod supervisor confirms via the
// result file before the API returns.

import { useCallback, useEffect, useState } from "react";

import { sessionCreate, sessionsList, sessionSwitch, type SessionInfo } from "../api";

const NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;

export function SessionsManager({ token, onClose }: { token: string; onClose: () => void }) {
  const [sessions, setSessions] = useState<SessionInfo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);
  const [switching, setSwitching] = useState<string | null>(null); // session id mid-switch

  const refetch = useCallback(async () => {
    try {
      const res = await sessionsList(token);
      setSessions(res.sessions);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [token]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  async function create() {
    const name = newName.trim();
    if (!NAME_RE.test(name)) {
      setError("Имя: строчные латинские буквы, цифры, дефис; до 32 символов; начинается с буквы/цифры.");
      return;
    }
    setCreating(true);
    setError(null);
    try {
      await sessionCreate(token, name);
      setNewName("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCreating(false);
      void refetch();
    }
  }

  async function doSwitch(s: SessionInfo) {
    const ok = window.confirm(
      `Переключиться на «${s.name}»?\n\nТекущая задача бота будет ПРЕРВАНА: ` +
        "его сессия Claude перезапустится в папке проекта. Разговор в текущей " +
        "сессии сохраняется и продолжится при переключении обратно.",
    );
    if (!ok) return;
    setSwitching(s.id);
    setError(null);
    try {
      await sessionSwitch(token, s.id);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSwitching(null);
      void refetch();
    }
  }

  return (
    <div className="fileview">
      <div className="fileview-header">
        <button className="ghost" onClick={onClose}>
          ←
        </button>
        <span className="path">Сессии</span>
        <button className="ghost" onClick={() => void refetch()} title="Обновить">
          ⟳
        </button>
      </div>
      {error && <p className="error">{error}</p>}
      {sessions === null ? (
        <p className="muted">Загрузка…</p>
      ) : (
        <ul className="live-list">
          {sessions.map((s) => (
            <li key={s.id} className="live-row">
              <div className="live-line">
                <span>
                  {s.active ? "🟢" : "⚪"} <strong>{s.name}</strong>
                  {s.name === "default" && <span className="muted"> (~/work)</span>}
                </span>
                {s.active ? (
                  <span className="live-ts">активна</span>
                ) : (
                  <button disabled={switching !== null} onClick={() => void doSwitch(s)}>
                    {switching === s.id ? "переключение…" : "переключить"}
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
      {switching !== null && (
        <p className="muted">Переключение: супервизор перезапускает Claude в папке проекта (до 90 с)…</p>
      )}
      <div className="toolbar">
        <input
          value={newName}
          placeholder="новая-сессия"
          onChange={(e) => setNewName(e.target.value)}
          disabled={creating}
        />
        <button className="primary" disabled={creating || !newName.trim()} onClick={() => void create()}>
          {creating ? "…" : "＋ Создать"}
        </button>
      </div>
      <p className="muted">
        Сессия = папка проекта (~/work/projects/&lt;имя&gt;) со своим разговором Claude. Создание не
        переключает — нажмите «переключить», когда готовы.
      </p>
    </div>
  );
}
