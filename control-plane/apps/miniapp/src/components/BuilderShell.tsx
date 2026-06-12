import { useState } from "react";

import { ApiError, fsPut } from "../api";

/**
 * Shared chrome for structural builders: form → mandatory raw preview →
 * save through PUT /fs/file (scanners run server-side; advisory shown inline).
 */
export function BuilderShell({
  token,
  title,
  compiled,
  formValid,
  existingPaths,
  onClose,
  onSaved,
  children,
}: {
  token: string;
  title: string;
  compiled: { path: string; content: string } | null;
  formValid: string | null; // null = ok, string = first validation error
  existingPaths: Set<string>;
  onClose: () => void;
  onSaved: () => void;
  children: React.ReactNode;
}) {
  const [showRaw, setShowRaw] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [advisory, setAdvisory] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const overwriting = compiled !== null && existingPaths.has(compiled.path);

  async function save() {
    if (!compiled) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fsPut(token, compiled.path, compiled.content);
      // builtinScan returns an array; an empty one means "no findings" — don't
      // render the ⚠️ block for it (truthy-[] bug, msg 2999 #1).
      const adv = Array.isArray(res.advisory) && res.advisory.length > 0 ? res.advisory : null;
      setAdvisory(adv ? JSON.stringify(adv, null, 2) : null);
      setSaved(true);
    } catch (e) {
      if (e instanceof ApiError) setError(`Отклонено (${e.status}): ${e.message}`);
      else setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  if (saved) {
    return (
      <div className="builder">
        <div className="fileview-header">
          <button onClick={onSaved}>← Дерево</button>
          <strong>{title}</strong>
        </div>
        <p className="success">
          ✅ Сохранено: <code>.claude/{compiled?.path}</code>
        </p>
        {advisory && (
          <details className="advisory" open>
            <summary>⚠️ Замечания сканера</summary>
            <pre>{advisory}</pre>
          </details>
        )}
      </div>
    );
  }

  return (
    <div className="builder">
      <div className="fileview-header">
        <button onClick={onClose}>← Отмена</button>
        <strong>{title}</strong>
      </div>
      <div className="builder-form">{children}</div>
      <div className="toolbar">
        <button disabled={!compiled} onClick={() => setShowRaw(!showRaw)}>
          {showRaw ? "Скрыть raw" : "Показать raw"}
        </button>
        <button className="primary" disabled={!compiled || formValid !== null || busy} onClick={save}>
          {busy ? "Сохраняю…" : overwriting ? "Перезаписать" : "Сохранить"}
        </button>
      </div>
      {formValid && <p className="error">{formValid}</p>}
      {overwriting && <p className="warn">⚠️ Файл уже существует — будет перезаписан.</p>}
      {error && <p className="error">{error}</p>}
      {showRaw && compiled && (
        <>
          <p className="muted">
            → <code>.claude/{compiled.path}</code>
          </p>
          <pre className="content">{compiled.content}</pre>
        </>
      )}
    </div>
  );
}
