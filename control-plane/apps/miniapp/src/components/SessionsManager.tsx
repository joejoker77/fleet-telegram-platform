// M5.7 SessionsManager — named project sessions: list (active badge), create,
// switch. A switch respawns the bot's claude pane in the project dir, so it
// interrupts whatever the bot is doing — a confirmation step is mandatory.
// NOT window.confirm(): Telegram's WebView renders the dialog but always
// returns false (blocking dialogs are suppressed), so OK silently no-ops.
// Instead: two-tap inline confirm — first tap arms the button, second fires.
// The switch call is synchronous (≤90s): the pod supervisor confirms via the
// result file before the API returns. "Switched" (pane respawned) is NOT
// "ready" (the new claude's telegram plugin is polling) — the supervisor
// reports real readiness via session-state.json and the API surfaces it as
// `ready`; until then the active row shows 🟡 «запускается…» and we poll.

import { useCallback, useEffect, useRef, useState } from "react";

import {
  checkpointCreate,
  checkpointDelete,
  checkpointRewind,
  checkpointsList,
  sessionCreate,
  sessionDelete,
  sessionsList,
  sessionSwitch,
  type CheckpointInfo,
  type SessionInfo,
} from "../api";

const NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;

export function SessionsManager({ token, onClose }: { token: string; onClose: () => void }) {
  const [sessions, setSessions] = useState<SessionInfo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);
  const [switching, setSwitching] = useState<string | null>(null); // session id mid-switch
  const [armed, setArmed] = useState<string | null>(null); // session id awaiting 2nd tap
  const [armedDel, setArmedDel] = useState<string | null>(null); // session id awaiting delete confirm
  const [deleting, setDeleting] = useState<string | null>(null); // session id mid-delete
  const [ckptFor, setCkptFor] = useState<SessionInfo | null>(null); // M5.8: timeline open for this session

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

  // While the active session is still starting (ready === false), poll every
  // 3s until the supervisor reports ready. Bounded: the supervisor's own
  // readiness watch gives up after ~3 min, so 100 polls (~5 min) is a hard cap
  // against a dead pod keeping the timer alive forever.
  const pollCount = useRef(0);
  const starting = sessions?.some((s) => s.active && s.ready === false) ?? false;
  useEffect(() => {
    if (!starting) {
      pollCount.current = 0;
      return;
    }
    if (pollCount.current >= 100) return;
    const t = setTimeout(() => {
      pollCount.current += 1;
      void refetch();
    }, 3000);
    return () => clearTimeout(t);
  }, [starting, sessions, refetch]);

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
    if (armed !== s.id) {
      // first tap: arm and show the warning inline; auto-disarm after 8s
      setArmed(s.id);
      setArmedDel(null);
      setTimeout(() => setArmed((cur) => (cur === s.id ? null : cur)), 8000);
      return;
    }
    setArmed(null);
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

  // Same two-tap pattern as doSwitch (window.confirm is a no-op in the
  // Telegram webview). The server moves the dir to ~/work/.trash — recoverable.
  async function doDelete(s: SessionInfo) {
    if (armedDel !== s.id) {
      setArmedDel(s.id);
      setArmed(null);
      setTimeout(() => setArmedDel((cur) => (cur === s.id ? null : cur)), 8000);
      return;
    }
    setArmedDel(null);
    setDeleting(s.id);
    setError(null);
    try {
      await sessionDelete(token, s.id);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setDeleting(null);
      void refetch();
    }
  }

  if (ckptFor) {
    return (
      <CheckpointsPanel
        token={token}
        session={ckptFor}
        onBack={() => {
          setCkptFor(null);
          void refetch(); // a rewind may have flipped readiness → restart polling
        }}
      />
    );
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
                  {s.active ? (s.ready === false ? "🟡" : "🟢") : "⚪"} <strong>{s.name}</strong>
                  {s.name === "default" && <span className="muted"> (~/work)</span>}
                </span>
                {s.active ? (
                  <span className="live-ts">
                    {s.ready === false ? "запускается…" : "активна"}{" "}
                    <button className="ghost" title="Чекпоинты" onClick={() => setCkptFor(s)}>
                      🕑
                    </button>
                  </span>
                ) : (
                  <span>
                    <button
                      disabled={switching !== null || deleting !== null}
                      className={armed === s.id ? "primary" : undefined}
                      onClick={() => void doSwitch(s)}
                    >
                      {switching === s.id
                        ? "переключение…"
                        : armed === s.id
                          ? "⚠️ точно переключить"
                          : "переключить"}
                    </button>{" "}
                    <button
                      disabled={switching !== null || deleting !== null}
                      className="ghost"
                      title="Чекпоинты"
                      onClick={() => setCkptFor(s)}
                    >
                      🕑
                    </button>{" "}
                    {s.name !== "default" && (
                      <button
                        disabled={switching !== null || deleting !== null}
                        className={armedDel === s.id ? "primary" : "ghost"}
                        title="Удалить сессию"
                        onClick={() => void doDelete(s)}
                      >
                        {deleting === s.id ? "…" : armedDel === s.id ? "⚠️ удалить?" : "🗑"}
                      </button>
                    )}
                  </span>
                )}
              </div>
              {armed === s.id && switching === null && (
                <p className="muted">
                  Текущая задача бота будет прервана: его Claude перезапустится в папке проекта.
                  Разговор сохранится и продолжится при переключении обратно. Нажмите ещё раз для
                  подтверждения.
                </p>
              )}
              {armedDel === s.id && deleting === null && (
                <p className="muted">
                  Сессия исчезнет из списка, папка проекта переедет в ~/work/.trash (данные не
                  уничтожаются — бот сможет восстановить или вычистить по запросу). Нажмите ещё раз
                  для подтверждения.
                </p>
              )}
            </li>
          ))}
        </ul>
      )}
      {switching !== null && (
        <p className="muted">Переключение: супервизор перезапускает Claude в папке проекта (до 90 с)…</p>
      )}
      {switching === null && starting && (
        <p className="muted">
          Сессия переключена, Claude запускается… Бот начнёт отвечать, когда статус станет
          «активна».
        </p>
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

// ── M5.8 checkpoints timeline ──
// Checkpoint = git snapshot of the project dir + a copy of the conversation.
// Create is instant and safe (no confirm needed); rewind restores BOTH files
// and conversation — destructive for state created after the checkpoint, so
// it gets the two-tap confirm (window.confirm is a no-op in the Telegram
// webview) and a pre-rewind auto-checkpoint server-side makes it undoable.

function fmtTs(iso: string): string {
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : d.toLocaleString();
}

function CheckpointsPanel({
  token,
  session,
  onBack,
}: {
  token: string;
  session: SessionInfo;
  onBack: () => void;
}) {
  const [list, setList] = useState<CheckpointInfo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [label, setLabel] = useState("");
  const [creating, setCreating] = useState(false);
  const [armedRw, setArmedRw] = useState<string | null>(null); // ckpt id awaiting rewind confirm
  const [rewinding, setRewinding] = useState<string | null>(null);
  const [rewound, setRewound] = useState<string | null>(null); // last applied ckpt («← вы здесь»)
  const [armedDel, setArmedDel] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);

  const refetch = useCallback(async () => {
    try {
      const res = await checkpointsList(token, session.id);
      setList(res.checkpoints);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [token, session.id]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  async function create() {
    setCreating(true);
    setError(null);
    try {
      await checkpointCreate(token, session.id, label.trim() || undefined);
      setLabel("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCreating(false);
      void refetch();
    }
  }

  async function doRewind(c: CheckpointInfo) {
    if (armedRw !== c.id) {
      setArmedRw(c.id);
      setArmedDel(null);
      setTimeout(() => setArmedRw((cur) => (cur === c.id ? null : cur)), 8000);
      return;
    }
    setArmedRw(null);
    setRewinding(c.id);
    setError(null);
    try {
      await checkpointRewind(token, session.id, c.id);
      setRewound(c.id);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setRewinding(null);
      void refetch(); // the pre-rewind auto-checkpoint shows up
    }
  }

  async function doDelete(c: CheckpointInfo) {
    if (armedDel !== c.id) {
      setArmedDel(c.id);
      setArmedRw(null);
      setTimeout(() => setArmedDel((cur) => (cur === c.id ? null : cur)), 8000);
      return;
    }
    setArmedDel(null);
    setDeleting(c.id);
    setError(null);
    try {
      await checkpointDelete(token, session.id, c.id);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setDeleting(null);
      void refetch();
    }
  }

  const busy = creating || rewinding !== null || deleting !== null;

  return (
    <div className="fileview">
      <div className="fileview-header">
        <button className="ghost" onClick={onBack}>
          ←
        </button>
        <span className="path">Чекпоинты: {session.name}</span>
        <button className="ghost" onClick={() => void refetch()} title="Обновить">
          ⟳
        </button>
      </div>
      {error && <p className="error">{error}</p>}
      <div className="toolbar">
        <input
          value={label}
          placeholder="метка (необязательно)"
          onChange={(e) => setLabel(e.target.value)}
          disabled={busy}
        />
        <button className="primary" disabled={busy} onClick={() => void create()}>
          {creating ? "…" : "＋ Чекпоинт"}
        </button>
      </div>
      {list === null ? (
        <p className="muted">Загрузка…</p>
      ) : list.length === 0 ? (
        <p className="muted">
          Чекпоинтов пока нет. Чекпоинт сохраняет файлы проекта и разговор Claude — к нему можно
          откатиться в любой момент. Авто-чекпоинты создаются при каждом переключении сессии.
        </p>
      ) : (
        <ul className="live-list">
          {list.map((c) => (
            <li key={c.id} className="live-row">
              <div className="live-line">
                <span>
                  {c.auto ? "🤖" : "📌"} <strong>{c.label}</strong>
                  {rewound === c.id && <span className="muted"> ← вы здесь</span>}
                </span>
                <span className="live-ts">{fmtTs(c.ts)}</span>
              </div>
              <div className="live-line">
                <span className="muted">{c.auto ? "авто" : "ручной"}</span>
                <span>
                  <button
                    disabled={busy}
                    className={armedRw === c.id ? "primary" : undefined}
                    onClick={() => void doRewind(c)}
                  >
                    {rewinding === c.id ? "откат…" : armedRw === c.id ? "⚠️ точно откатить" : "⏪ откатить"}
                  </button>{" "}
                  <button
                    disabled={busy}
                    className={armedDel === c.id ? "primary" : "ghost"}
                    title="Удалить чекпоинт"
                    onClick={() => void doDelete(c)}
                  >
                    {deleting === c.id ? "…" : armedDel === c.id ? "⚠️ удалить?" : "🗑"}
                  </button>
                </span>
              </div>
              {armedRw === c.id && rewinding === null && (
                <p className="muted">
                  Файлы проекта и разговор Claude вернутся к состоянию этого чекпоинта. Текущее
                  состояние будет сохранено авто-чекпоинтом (откат обратим).
                  {session.active && " Сессия активна: Claude перезапустится, текущая задача бота прервётся."}
                  {" "}Нажмите ещё раз для подтверждения.
                </p>
              )}
              {armedDel === c.id && deleting === null && (
                <p className="muted">Запись чекпоинта и копия разговора будут удалены. Нажмите ещё раз.</p>
              )}
            </li>
          ))}
        </ul>
      )}
      {rewinding !== null && (
        <p className="muted">Откат: супервизор восстанавливает файлы и разговор (до 90 с)…</p>
      )}
      {rewound !== null && rewinding === null && (
        <p className="muted">
          Откат выполнен.
          {session.active
            ? " Claude перезапускается — вернитесь к списку сессий, чтобы увидеть статус готовности."
            : " Изменения вступят в силу при переключении на эту сессию."}
        </p>
      )}
      <p className="muted">
        Чекпоинт = снимок файлов проекта + разговора Claude. Вложенные git-репозитории сохраняются
        как ссылки (их файлы защищает их собственный git). 🤖 — авто, 📌 — ручной.
      </p>
    </div>
  );
}
