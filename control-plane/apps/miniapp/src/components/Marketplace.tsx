// M8.1 — artifact marketplace screen. Two tabs:
//   • Каталог: browse my + public artifacts, open versions, import (→ approval)
//   • Опубликовать: publish one of my .claude artifacts (scan → admin: now,
//     non-admin: approval)
// Mirrors apps/api registry-routes.ts. Import always routes through the approval
// queue (🛂); admin publish lands immediately, non-admin publish → approval too.
import { useEffect, useState } from "react";
import {
  ApiError,
  registryItems,
  registryItem,
  registryImport,
  registryPublish,
  registryDelete,
  type ArtifactType,
  type RegistryItem,
  type RegistryVersion,
} from "../api";

const TYPES: ArtifactType[] = ["skill", "subagent", "command", "workflow"];
const TYPE_ICON: Record<ArtifactType, string> = { skill: "🧩", subagent: "🤖", command: "⚡", workflow: "🧱" };

export function Marketplace({ token, onClose }: { token: string; onClose: () => void }) {
  const [tab, setTab] = useState<"browse" | "publish">("browse");
  return (
    <div className="fileview">
      <header className="fileview-header">
        <strong>📦 Маркетплейс</strong>
        <span>
          <button className={tab === "browse" ? "primary" : "ghost"} onClick={() => setTab("browse")}>
            Каталог
          </button>
          <button className={tab === "publish" ? "primary" : "ghost"} onClick={() => setTab("publish")}>
            Опубликовать
          </button>
          <button className="ghost" onClick={onClose}>
            ✕
          </button>
        </span>
      </header>
      {tab === "browse" ? <Browse token={token} /> : <PublishForm token={token} />}
    </div>
  );
}

function Browse({ token }: { token: string }) {
  const [items, setItems] = useState<RegistryItem[] | null>(null);
  const [filter, setFilter] = useState<ArtifactType | "all">("all");
  const [err, setErr] = useState<string | null>(null);
  const [open, setOpen] = useState<RegistryItem | null>(null);

  async function load() {
    setErr(null);
    setItems(null);
    try {
      const res = await registryItems(token, filter === "all" ? undefined : filter);
      setItems(res.items);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }
  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter]);

  if (open) return <Detail token={token} item={open} onClose={() => { setOpen(null); void load(); }} />;

  return (
    <div className="mp-body">
      <div className="scope-bar">
        <button className={filter === "all" ? "primary" : ""} onClick={() => setFilter("all")}>
          Все
        </button>
        {TYPES.map((tp) => (
          <button key={tp} className={filter === tp ? "primary" : ""} onClick={() => setFilter(tp)}>
            {TYPE_ICON[tp]} {tp}
          </button>
        ))}
      </div>
      {err && <p className="error">{err}</p>}
      {!items && !err && <p className="muted">Загрузка…</p>}
      {items && items.length === 0 && <p className="muted">Пусто. Опубликуй первый артефакт во вкладке «Опубликовать».</p>}
      <ul className="mp-list">
        {items?.map((it) => (
          <li key={it.id} className="mp-row" onClick={() => setOpen(it)}>
            <span>
              {TYPE_ICON[it.type]} <strong>{it.name}</strong>
              {it.mine && <span className="badge">моё</span>}
              {it.visibility === "public" ? <span className="badge">public</span> : <span className="badge muted">private</span>}
            </span>
            <small className="muted">{it.description || it.ownerUsername || ""}</small>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Detail({ token, item, onClose }: { token: string; item: RegistryItem; onClose: () => void }) {
  const [versions, setVersions] = useState<RegistryVersion[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setErr(null);
    try {
      const res = await registryItem(token, item.id);
      setVersions(res.versions);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }
  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function doImport(v: RegistryVersion) {
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      await registryImport(token, v.id);
      setMsg(`Импорт v${v.version} отправлен в 🛂 аппрувы — подтверди там, файлы установятся после.`);
    } catch (e) {
      setErr(e instanceof ApiError ? `${e.message}` : e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }
  async function doDelete() {
    if (!item.mine) return;
    setBusy(true);
    setErr(null);
    try {
      await registryDelete(token, item.id);
      onClose();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setBusy(false);
    }
  }

  return (
    <div className="mp-body">
      <button className="ghost" onClick={onClose}>
        ← назад
      </button>
      <h3>
        {TYPE_ICON[item.type]} {item.name}
      </h3>
      {item.description && <p className="muted">{item.description}</p>}
      <p className="muted">
        автор: {item.ownerUsername ?? "—"} · {item.visibility}
      </p>
      {msg && <p className="success">{msg}</p>}
      {err && <p className="error">{err}</p>}
      {!versions && <p className="muted">Загрузка версий…</p>}
      <ul className="mp-list">
        {versions?.map((v) => (
          <li key={v.id} className="mp-row">
            <span>
              <strong>v{v.version}</strong> <span className="badge muted">{v.status}</span>
            </span>
            {v.status === "published" && (
              <button className="primary" disabled={busy} onClick={() => void doImport(v)}>
                Импортировать
              </button>
            )}
          </li>
        ))}
      </ul>
      {item.mine && (
        <button className="danger" disabled={busy} onClick={() => void doDelete()}>
          Снять с публикации
        </button>
      )}
    </div>
  );
}

function PublishForm({ token }: { token: string }) {
  const [type, setType] = useState<ArtifactType>("skill");
  const [name, setName] = useState("");
  const [version, setVersion] = useState("1.0.0");
  const [pub, setPub] = useState(false);
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function submit() {
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      const res = await registryPublish(token, {
        type,
        name: name.trim(),
        version: version.trim(),
        visibility: pub ? "public" : "private",
        ...(description.trim() ? { description: description.trim() } : {}),
      });
      if (res.published) {
        setMsg(`Опубликовано ✅ ${res.prUrl ? `(PR: ${res.prUrl})` : ""}`);
      } else if (res.approvalId) {
        setMsg("Скан пройден. Отправлено в 🛂 аппрувы — подтверди публикацию там.");
      }
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mp-body">
      <p className="muted">
        Публикует артефакт из твоей песочницы <code>.claude/</code> в общий маркетплейс. Перед публикацией — обязательный
        скан (fail-closed).
      </p>
      <label>
        Тип
        <select value={type} onChange={(e) => setType(e.target.value as ArtifactType)}>
          {TYPES.map((tp) => (
            <option key={tp} value={tp}>
              {TYPE_ICON[tp]} {tp}
            </option>
          ))}
        </select>
      </label>
      <label>
        Имя
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="например proposal-generator" />
      </label>
      <label>
        Версия
        <input value={version} onChange={(e) => setVersion(e.target.value)} placeholder="1.0.0" />
      </label>
      <label>
        Описание (необязательно)
        <input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="коротко, что делает" />
      </label>
      <label className="row">
        <input type="checkbox" checked={pub} onChange={(e) => setPub(e.target.checked)} />
        Публичный (виден всем в каталоге)
      </label>
      {msg && <p className="success">{msg}</p>}
      {err && <p className="error">{err}</p>}
      <button className="primary" disabled={busy || !name.trim()} onClick={() => void submit()}>
        {busy ? "Публикую…" : "Опубликовать"}
      </button>
    </div>
  );
}
