// M5.5 McpBuilder — connect a user MCP server through the gate:
// form → POST /mcp/connect (validate → scan → approval) → the user confirms in
// ApprovalsQueue; apply happens server-side in the answer handler. The scanner
// verdict (or block reason) is shown inline. Disconnect is immediate (no
// approval; it is the rollback of a connect).
// M5.5b: optional 🔑 secret section — the value goes straight to the vault
// (staged unbound; bound only on allow). It never enters the stanza/scan/
// approval. Covered: MCPs authenticated by an HTTP header on outbound HTTPS
// (the egress proxy injects it). NOT covered: MCPs that need the raw key
// locally (AWS sigv4 etc.).

import { useCallback, useEffect, useMemo, useState } from "react";

import {
  mcpConnectRaw,
  mcpDisconnect,
  mcpList,
  type McpFinding,
  type McpSecretSpec,
  type McpServerInfo,
} from "../api";

type Mode = "stdio" | "remote";

type Outcome =
  | { kind: "none" }
  | { kind: "approval"; approvalId: string; ttlSeconds: number; overwrite: boolean; secretStaged: boolean; secretRotated: boolean }
  | { kind: "blocked"; verdict: string; severity: string | null; findings: McpFinding[]; reportRef: string | null; error: string }
  | { kind: "error"; message: string };

const VALUE_FORMAT_PRESETS = ["Bearer {value}", "{value}", "Basic {value}"] as const;

export function McpBuilder({
  token,
  onClose,
  onGoApprovals,
}: {
  token: string;
  onClose: () => void;
  onGoApprovals: () => void;
}) {
  const [servers, setServers] = useState<McpServerInfo[] | null>(null);
  const [mode, setMode] = useState<Mode>("stdio");
  const [name, setName] = useState("");
  const [command, setCommand] = useState("");
  const [args, setArgs] = useState("");
  const [env, setEnv] = useState("");
  const [url, setUrl] = useState("");
  const [headers, setHeaders] = useState("");
  const [timeout_, setTimeout_] = useState("");
  // M5.5b secret section (optional, collapsed by default)
  const [withSecret, setWithSecret] = useState(false);
  const [secretValue, setSecretValue] = useState("");
  const [secretHost, setSecretHost] = useState("");
  const [secretHeader, setSecretHeader] = useState("Authorization");
  const [secretFormat, setSecretFormat] = useState<string>(VALUE_FORMAT_PRESETS[0]);
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState<Outcome>({ kind: "none" });

  const refetch = useCallback(async () => {
    try {
      const res = await mcpList(token);
      setServers(res.servers);
    } catch {
      setServers([]);
    }
  }, [token]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  const stanza = useMemo(() => {
    const s: Record<string, unknown> = {};
    if (mode === "stdio") {
      if (command.trim()) s.command = command.trim();
      const a = lines(args);
      if (a.length) s.args = a;
      const e = kvRecord(env, "=");
      if (e && Object.keys(e).length) s.env = e;
    } else {
      s.type = "http";
      if (url.trim()) s.url = url.trim();
      const h = kvRecord(headers, ":");
      if (h && Object.keys(h).length) s.headers = h;
    }
    const t = Number(timeout_);
    if (timeout_.trim() && Number.isFinite(t)) s.timeout = t;
    return s;
  }, [mode, command, args, env, url, headers, timeout_]);

  const secretSpec: McpSecretSpec | undefined = useMemo(() => {
    if (!withSecret) return undefined;
    return {
      value: secretValue,
      hostPattern: secretHost.trim(),
      headerName: secretHeader.trim(),
      valueFormat: secretFormat,
    };
  }, [withSecret, secretValue, secretHost, secretHeader, secretFormat]);

  const secretValid =
    !withSecret ||
    (secretValue.length > 0 &&
      secretValue.length <= 4096 &&
      !secretValue.includes("\n") &&
      /^(\*\.)?[A-Za-z0-9][A-Za-z0-9.-]{1,200}\.[A-Za-z]{2,}$/.test(secretHost.trim()) &&
      /^[A-Za-z0-9-]{1,64}$/.test(secretHeader.trim()) &&
      secretFormat.includes("{value}") &&
      secretFormat.length <= 64);

  const formValid =
    name.trim() !== "" &&
    (mode === "stdio" ? command.trim() !== "" : url.trim().startsWith("https://")) &&
    secretValid;

  async function submit() {
    setBusy(true);
    setOutcome({ kind: "none" });
    try {
      const res = await mcpConnectRaw(token, name.trim(), stanza, secretSpec);
      if (res.kind === "approval") {
        // The value never comes back — drop it from the form as soon as it is
        // staged in the vault.
        if (secretSpec) setSecretValue("");
        setOutcome({
          kind: "approval",
          approvalId: res.res.approvalId,
          ttlSeconds: res.res.ttlSeconds,
          overwrite: res.res.overwrite,
          secretStaged: res.res.secret !== undefined,
          secretRotated: res.res.secret?.rotated === true,
        });
      } else {
        setOutcome(res);
      }
    } catch (e) {
      setOutcome({ kind: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  async function disconnect(n: string) {
    if (!window.confirm(`Отключить MCP «${n}»?`)) return;
    try {
      await mcpDisconnect(token, n);
    } catch (e) {
      setOutcome({ kind: "error", message: e instanceof Error ? e.message : String(e) });
    }
    void refetch();
  }

  return (
    <div className="fileview">
      <div className="fileview-header">
        <button className="ghost" onClick={onClose}>
          ←
        </button>
        <span className="path">Подключить MCP</span>
        <button className="ghost" onClick={() => void refetch()} title="Обновить">
          ⟳
        </button>
      </div>

      {servers !== null && servers.length > 0 && (
        <>
          <p className="muted">Подключённые серверы</p>
          <ul className="live-list">
            {servers.map((s) => (
              <li key={s.name} className="live-row">
                <div className="live-line">
                  <span>
                    {s.kind === "remote" ? "🌐" : "🖥"} {s.name}
                    {!s.enabled && " (выключен)"}
                  </span>
                  <button className="ghost" onClick={() => void disconnect(s.name)} title="Отключить">
                    ✖
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}

      <form
        className="builder-form"
        onSubmit={(e) => {
          e.preventDefault();
          if (formValid && !busy) void submit();
        }}
      >
        <label>
          Имя сервера
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="my-mcp" />
        </label>
        <label>
          Тип
          <select value={mode} onChange={(e) => setMode(e.target.value as Mode)}>
            <option value="stdio">stdio — локальная команда (npx, бинарь)</option>
            <option value="remote">remote — https-сервер</option>
          </select>
        </label>
        {mode === "stdio" ? (
          <>
            <label>
              Команда
              <input value={command} onChange={(e) => setCommand(e.target.value)} placeholder="npx" />
            </label>
            <label>
              Аргументы (по одному в строке)
              <textarea rows={3} value={args} onChange={(e) => setArgs(e.target.value)} placeholder={"-y\n@scope/some-mcp"} />
            </label>
            <label>
              Переменные окружения (KEY=значение, по одной в строке; секреты — не сюда, а в 🔑-секцию ниже)
              <textarea rows={2} value={env} onChange={(e) => setEnv(e.target.value)} placeholder={"SOME_FLAG=1"} />
            </label>
          </>
        ) : (
          <>
            <label>
              URL (только https)
              <input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://mcp.example.com/sse" />
            </label>
            <label>
              Заголовки (Имя: значение, по одному в строке; секреты — не сюда, а в 🔑-секцию ниже)
              <textarea rows={2} value={headers} onChange={(e) => setHeaders(e.target.value)} placeholder={"X-Client: miniapp"} />
            </label>
          </>
        )}
        <label>
          Timeout, мс (опционально)
          <input value={timeout_} onChange={(e) => setTimeout_(e.target.value)} placeholder="30000" inputMode="numeric" />
        </label>

        <label className="live-line">
          <span>🔑 Секрет (API-ключ / токен)</span>
          <input type="checkbox" checked={withSecret} onChange={(e) => setWithSecret(e.target.checked)} />
        </label>
        {withSecret && (
          <>
            <p className="muted">
              Значение уйдёт сразу в защищённое хранилище — не в файлы и не на скан. Прокси сам подставит его
              в заголовок, когда сервер пойдёт на указанный домен. Подходит для авторизации HTTP-заголовком;
              если ключ нужен процессу «как есть» (например, AWS-подпись) — этот способ не сработает.
              В стансе вместо значения оставьте заполнитель вида {"${API_KEY}"} или ничего.
            </p>
            <label>
              Значение секрета
              <input
                type="password"
                value={secretValue}
                onChange={(e) => setSecretValue(e.target.value)}
                placeholder="sk-…"
                autoComplete="off"
              />
            </label>
            <label>
              Домен API (куда подставлять)
              <input
                value={secretHost}
                onChange={(e) => setSecretHost(e.target.value)}
                placeholder="api.example.com или *.example.com"
              />
            </label>
            <label>
              HTTP-заголовок
              <input value={secretHeader} onChange={(e) => setSecretHeader(e.target.value)} placeholder="Authorization" />
            </label>
            <label>
              Формат значения
              <select value={secretFormat} onChange={(e) => setSecretFormat(e.target.value)}>
                {VALUE_FORMAT_PRESETS.map((p) => (
                  <option key={p} value={p}>
                    {p === "{value}" ? "{value} — ключ как есть (X-API-Key и т.п.)" : p}
                  </option>
                ))}
              </select>
            </label>
          </>
        )}

        <details>
          <summary className="muted">JSON-станса (что уйдёт на скан{withSecret ? " — секрета здесь нет" : ""})</summary>
          <pre className="content live-payload">{JSON.stringify({ [name.trim() || "имя"]: stanza }, null, 2)}</pre>
        </details>

        <div className="toolbar">
          <button className="primary" type="submit" disabled={!formValid || busy}>
            {busy ? "Сканирую…" : "🛡 Проверить и подключить"}
          </button>
        </div>
      </form>

      {outcome.kind === "approval" && (
        <div className="approval-card">
          <p>
            ✅ Скан пройден{outcome.overwrite ? " (⚠️ это перезапись существующего сервера)" : ""}.
            {outcome.secretStaged &&
              ` 🔑 Секрет ${outcome.secretRotated ? "обновлён" : "сохранён"} в хранилище (активируется после подтверждения).`}{" "}
            Осталось подтвердить в аппрувах — запрос живёт {Math.round(outcome.ttlSeconds / 60)} мин.
          </p>
          <button className="primary" onClick={onGoApprovals}>
            🛂 Открыть аппрувы
          </button>
        </div>
      )}
      {outcome.kind === "blocked" && (
        <div className="approval-card">
          <p className="error">
            ⛔ {outcome.error} (вердикт: {outcome.verdict}
            {outcome.severity ? `, severity: ${outcome.severity}` : ""})
          </p>
          {outcome.findings.length > 0 && (
            <ul>
              {outcome.findings.map((f, i) => (
                <li key={i} className="muted">
                  [{f.severity}] {f.ruleId}: {f.message}
                </li>
              ))}
            </ul>
          )}
          {outcome.reportRef && <p className="muted">{outcome.reportRef}</p>}
        </div>
      )}
      {outcome.kind === "error" && <p className="error">{outcome.message}</p>}
    </div>
  );
}

function lines(text: string): string[] {
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
}

function kvRecord(text: string, sep: "=" | ":"): Record<string, string> | undefined {
  const out: Record<string, string> = {};
  for (const line of lines(text)) {
    const i = line.indexOf(sep);
    if (i <= 0) continue;
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return Object.keys(out).length ? out : undefined;
}
