import { useEffect, useState } from "react";

import { ApiError, fsTreeScoped, type FsEntry, type FsScope } from "../api";
import { t, tErr } from "../i18n";

// M5.10 lazy tree: ONE directory level per /fs/tree call, children fetched on
// expand. Mount with key={`${scope}:${showAll}:${refreshKey}`} — scope/toggle/
// refresh changes remount the tree, so nodes never need reload logic.

function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

type Level =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "ok"; entries: FsEntry[]; hidden: number };

function useLevel(token: string, scope: FsScope, dir: string, showAll: boolean, active: boolean): [Level, () => void] {
  const [level, setLevel] = useState<Level>({ kind: "loading" });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!active) return;
    let alive = true;
    setLevel({ kind: "loading" });
    fsTreeScoped(token, scope, dir, showAll)
      .then((r) => alive && setLevel({ kind: "ok", entries: r.entries, hidden: r.hidden }))
      .catch((e: unknown) => {
        if (!alive) return;
        const msg = e instanceof ApiError ? tErr(e.code, e.message) : e instanceof Error ? e.message : String(e);
        setLevel({ kind: "error", message: msg });
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token, scope, dir, showAll, active, attempt]);
  return [level, () => setAttempt((a) => a + 1)];
}

function LevelRows({
  token,
  scope,
  dir,
  showAll,
  depth,
  active,
  onOpen,
}: {
  token: string;
  scope: FsScope;
  dir: string;
  showAll: boolean;
  depth: number;
  active: boolean;
  onOpen: (path: string) => void;
}) {
  const [level, retry] = useLevel(token, scope, dir, showAll, active);
  const pad = { paddingLeft: `${depth * 16 + 8}px` };

  if (level.kind === "loading") {
    return (
      <div className="tree-row muted" style={pad}>
        {t("tree.loading")}
      </div>
    );
  }
  if (level.kind === "error") {
    return (
      <div className="tree-row" style={pad}>
        <span className="error">
          {t("tree.loadError")}: {level.message}
        </span>{" "}
        <button className="ghost" onClick={retry}>
          ⟳
        </button>
      </div>
    );
  }
  return (
    <>
      {level.entries.length === 0 && level.hidden === 0 && (
        <div className="tree-row muted" style={pad}>
          {t("tree.empty")}
        </div>
      )}
      {level.entries.map((e) =>
        e.type === "dir" ? (
          <DirNode key={e.path} token={token} scope={scope} entry={e} showAll={showAll} depth={depth} onOpen={onOpen} />
        ) : (
          <div key={e.path} className="tree-row tree-file" style={pad} onClick={() => onOpen(e.path)}>
            <span className="tree-name">{e.name ?? e.path}</span>
            <span className="tree-size">{fmtSize(e.size)}</span>
          </div>
        ),
      )}
      {level.hidden > 0 && (
        <div className="tree-row muted" style={pad}>
          👁 {t("tree.hidden", { n: level.hidden })}
        </div>
      )}
    </>
  );
}

function DirNode({
  token,
  scope,
  entry,
  showAll,
  depth,
  onOpen,
}: {
  token: string;
  scope: FsScope;
  entry: FsEntry;
  showAll: boolean;
  depth: number;
  onOpen: (path: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const [everExpanded, setEverExpanded] = useState(false);
  const pad = { paddingLeft: `${depth * 16 + 8}px` };
  return (
    <>
      <div
        className="tree-row tree-dir"
        style={pad}
        onClick={() => {
          setExpanded(!expanded);
          if (!expanded) setEverExpanded(true);
        }}
      >
        <span className="tree-caret">{expanded ? "▾" : "▸"}</span> {entry.name ?? entry.path}/
      </div>
      {everExpanded && (
        <div style={expanded ? undefined : { display: "none" }}>
          <LevelRows
            token={token}
            scope={scope}
            dir={entry.path}
            showAll={showAll}
            depth={depth + 1}
            active={everExpanded}
            onOpen={onOpen}
          />
        </div>
      )}
    </>
  );
}

export function FileTree({
  token,
  scope,
  showAll,
  onOpen,
}: {
  token: string;
  scope: FsScope;
  showAll: boolean;
  onOpen: (path: string) => void;
}) {
  return (
    <div className="tree">
      <LevelRows token={token} scope={scope} dir="" showAll={showAll} depth={0} active onOpen={onOpen} />
    </div>
  );
}
