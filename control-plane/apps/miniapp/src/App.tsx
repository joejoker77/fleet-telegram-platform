import { useEffect, useState } from "react";

import { fsTree, me, type FsEntry, type MeResponse } from "./api";
import { dropSession, ensureSession, type Session } from "./auth";
import { CommandBuilder } from "./components/CommandBuilder";
import { FileTree } from "./components/FileTree";
import { FileView } from "./components/FileView";
import { LiveActivity } from "./components/LiveActivity";
import { SubagentBuilder } from "./components/SubagentBuilder";

type State =
  | { phase: "auth" }
  | { phase: "error"; message: string }
  | { phase: "ready"; session: Session; profile: MeResponse; entries: FsEntry[] };

type Screen =
  | { kind: "tree" }
  | { kind: "file"; path: string }
  | { kind: "new" }
  | { kind: "subagent" }
  | { kind: "command" }
  | { kind: "live" };

export function App() {
  const [state, setState] = useState<State>({ phase: "auth" });
  const [screen, setScreen] = useState<Screen>({ kind: "tree" });

  async function boot() {
    setState({ phase: "auth" });
    try {
      const session = await ensureSession();
      const [profile, tree] = await Promise.all([me(session.token), fsTree(session.token)]);
      setState({ phase: "ready", session, profile, entries: tree.entries });
    } catch (e) {
      dropSession(); // a stale cached JWT must not wedge the app in an error loop
      setState({ phase: "error", message: e instanceof Error ? e.message : String(e) });
    }
  }

  useEffect(() => {
    void boot();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (state.phase === "auth") {
    return <Centered>Авторизация…</Centered>;
  }
  if (state.phase === "error") {
    return (
      <Centered>
        <p className="error">{state.message}</p>
        <button onClick={() => void boot()}>Повторить</button>
      </Centered>
    );
  }

  const existingPaths = new Set(state.entries.map((e) => e.path));
  const toTree = () => setScreen({ kind: "tree" });
  const savedToTree = () => {
    setScreen({ kind: "tree" });
    void boot(); // refresh the tree so the new artifact shows up
  };

  return (
    <div className="app">
      <header className="app-header">
        <strong>.claude/ — {state.profile.osUsername}</strong>
        <span>
          <button className="ghost" onClick={() => setScreen({ kind: "live" })} title="Live-активность">
            📡
          </button>
          <button className="ghost" onClick={() => setScreen({ kind: "new" })} title="Создать">
            ＋
          </button>
          <button
            className="ghost"
            onClick={() => {
              toTree();
              void boot();
            }}
          >
            ⟳
          </button>
        </span>
      </header>
      {screen.kind === "tree" && <FileTree entries={state.entries} onOpen={(path) => setScreen({ kind: "file", path })} />}
      {screen.kind === "file" && <FileView token={state.session.token} path={screen.path} onClose={toTree} />}
      {screen.kind === "new" && (
        <div className="centered">
          <button className="primary" onClick={() => setScreen({ kind: "subagent" })}>
            🤖 Новый субагент
          </button>
          <button className="primary" onClick={() => setScreen({ kind: "command" })}>
            ⚡ Новая slash-команда
          </button>
          <button onClick={toTree}>Отмена</button>
          <p className="muted">MCP-серверы подключаются через бота (гейт с подтверждением), не отсюда.</p>
        </div>
      )}
      {screen.kind === "subagent" && (
        <SubagentBuilder token={state.session.token} existingPaths={existingPaths} onClose={toTree} onSaved={savedToTree} />
      )}
      {screen.kind === "command" && (
        <CommandBuilder token={state.session.token} existingPaths={existingPaths} onClose={toTree} onSaved={savedToTree} />
      )}
      {screen.kind === "live" && <LiveActivity token={state.session.token} onClose={toTree} />}
    </div>
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="centered">{children}</div>;
}
