import { useEffect, useState } from "react";

import { fsTree, me, type FsEntry, type MeResponse } from "./api";
import { dropSession, ensureSession, type Session } from "./auth";
import { FileTree } from "./components/FileTree";
import { FileView } from "./components/FileView";

type State =
  | { phase: "auth" }
  | { phase: "error"; message: string }
  | { phase: "ready"; session: Session; profile: MeResponse; entries: FsEntry[] };

export function App() {
  const [state, setState] = useState<State>({ phase: "auth" });
  const [openPath, setOpenPath] = useState<string | null>(null);

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

  return (
    <div className="app">
      <header className="app-header">
        <strong>.claude/ — {state.profile.osUsername}</strong>
        <button
          className="ghost"
          onClick={() => {
            setOpenPath(null);
            void boot();
          }}
        >
          ⟳
        </button>
      </header>
      {openPath === null ? (
        <FileTree entries={state.entries} onOpen={setOpenPath} />
      ) : (
        <FileView token={state.session.token} path={openPath} onClose={() => setOpenPath(null)} />
      )}
    </div>
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="centered">{children}</div>;
}
