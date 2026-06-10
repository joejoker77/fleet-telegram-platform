import { useMemo, useState } from "react";

import type { FsEntry } from "../api";

interface TreeNode {
  name: string;
  path: string;
  type: "file" | "dir";
  size: number;
  children: TreeNode[];
}

// /fs/tree returns a flat pre-order list; rebuild the hierarchy by path.
function buildTree(entries: FsEntry[]): TreeNode[] {
  const roots: TreeNode[] = [];
  const byPath = new Map<string, TreeNode>();
  for (const e of entries) {
    const name = e.path.split("/").pop() ?? e.path;
    const node: TreeNode = { name, path: e.path, type: e.type, size: e.size, children: [] };
    byPath.set(e.path, node);
    const parentPath = e.path.includes("/") ? e.path.slice(0, e.path.lastIndexOf("/")) : "";
    const parent = parentPath ? byPath.get(parentPath) : undefined;
    (parent ? parent.children : roots).push(node);
  }
  const sortRec = (nodes: TreeNode[]) => {
    nodes.sort((x, y) => (x.type === y.type ? x.name.localeCompare(y.name) : x.type === "dir" ? -1 : 1));
    nodes.forEach((nd) => sortRec(nd.children));
  };
  sortRec(roots);
  return roots;
}

function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function Node({ node, depth, onOpen }: { node: TreeNode; depth: number; onOpen: (path: string) => void }) {
  const [expanded, setExpanded] = useState(depth === 0);
  const pad = { paddingLeft: `${depth * 16 + 8}px` };
  if (node.type === "dir") {
    return (
      <>
        <div className="tree-row tree-dir" style={pad} onClick={() => setExpanded(!expanded)}>
          <span className="tree-caret">{expanded ? "▾" : "▸"}</span> {node.name}/
        </div>
        {expanded && node.children.map((c) => <Node key={c.path} node={c} depth={depth + 1} onOpen={onOpen} />)}
      </>
    );
  }
  return (
    <div className="tree-row tree-file" style={pad} onClick={() => onOpen(node.path)}>
      <span className="tree-name">{node.name}</span>
      <span className="tree-size">{fmtSize(node.size)}</span>
    </div>
  );
}

export function FileTree({ entries, onOpen }: { entries: FsEntry[]; onOpen: (path: string) => void }) {
  const roots = useMemo(() => buildTree(entries), [entries]);
  if (roots.length === 0) return <p className="muted">Песочница .claude/ пуста.</p>;
  return (
    <div className="tree">
      {roots.map((n) => (
        <Node key={n.path} node={n} depth={0} onOpen={onOpen} />
      ))}
    </div>
  );
}
