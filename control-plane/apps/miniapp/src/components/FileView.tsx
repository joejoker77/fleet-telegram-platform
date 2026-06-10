import { useEffect, useState } from "react";

import { ApiError, fsFile, fsPut } from "../api";
import { diffLines, hasChanges } from "../diff";

type Mode = "view" | "edit" | "diff";

export function FileView({ token, path, onClose }: { token: string; path: string; onClose: () => void }) {
  const [original, setOriginal] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [mode, setMode] = useState<Mode>("view");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [advisory, setAdvisory] = useState<string | null>(null);

  useEffect(() => {
    setOriginal(null);
    setError(null);
    setAdvisory(null);
    setMode("view");
    fsFile(token, path)
      .then((r) => {
        setOriginal(r.content);
        setDraft(r.content);
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }, [token, path]);

  const dirty = original !== null && draft !== original;

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const res = await fsPut(token, path, draft);
      setOriginal(draft);
      setMode("view");
      // Scanner advisory comes back non-blocking — show it inline (M5 design:
      // verdict visible before/at save; hard rejects arrive as HTTP errors).
      setAdvisory(res.advisory ? JSON.stringify(res.advisory, null, 2) : null);
    } catch (e) {
      if (e instanceof ApiError) setError(`Сохранение отклонено (${e.status}): ${e.message}`);
      else setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  if (error && original === null) {
    return (
      <div className="fileview">
        <Header path={path} onClose={onClose} />
        <p className="error">{error}</p>
      </div>
    );
  }
  if (original === null) {
    return (
      <div className="fileview">
        <Header path={path} onClose={onClose} />
        <p className="muted">Загрузка…</p>
      </div>
    );
  }

  const d = mode === "diff" ? diffLines(original, draft) : [];

  return (
    <div className="fileview">
      <Header path={path} onClose={onClose} />
      <div className="toolbar">
        <button disabled={mode === "view"} onClick={() => setMode("view")}>
          Просмотр
        </button>
        <button disabled={mode === "edit"} onClick={() => setMode("edit")}>
          Редактировать
        </button>
        <button disabled={!dirty || mode === "diff"} onClick={() => setMode("diff")}>
          Diff
        </button>
        <button className="primary" disabled={!dirty || busy} onClick={save}>
          {busy ? "Сохраняю…" : "Сохранить"}
        </button>
      </div>
      {error && <p className="error">{error}</p>}
      {advisory && (
        <details className="advisory" open>
          <summary>⚠️ Замечания сканера (сохранено, но просмотрите)</summary>
          <pre>{advisory}</pre>
        </details>
      )}
      {mode === "edit" ? (
        <textarea className="editor" value={draft} onChange={(e) => setDraft(e.target.value)} spellCheck={false} />
      ) : mode === "diff" ? (
        hasChanges(d) ? (
          <pre className="diff">
            {d.map((l, i) => (
              <div key={i} className={`diff-${l.kind}`}>
                {l.kind === "add" ? "+ " : l.kind === "del" ? "- " : "  "}
                {l.text}
              </div>
            ))}
          </pre>
        ) : (
          <p className="muted">Изменений нет.</p>
        )
      ) : (
        <pre className="content">{draft}</pre>
      )}
    </div>
  );
}

function Header({ path, onClose }: { path: string; onClose: () => void }) {
  return (
    <div className="fileview-header">
      <button onClick={onClose}>← Дерево</button>
      <code className="path">.claude/{path}</code>
    </div>
  );
}
