// Path confinement for the authoring file API — the security-critical bit, kept
// dependency-free (only node:fs/node:path) so it is unit-testable in isolation.
// Every client-supplied path must resolve INSIDE the tenant's ~/.claude sandbox;
// .. / absolute / symlink escapes are rejected.
import fs from "node:fs";
import path from "node:path";

export class PathError extends Error {}

// Resolve a client-supplied relative path inside `root`. Leading slashes are
// stripped (an "absolute" client path is treated as sandbox-relative). Any result
// outside root throws.
export function safeResolve(root: string, rel: string): string {
  const cleaned = String(rel ?? "").replace(/^[/\\]+/, "");
  const abs = path.resolve(root, cleaned);
  const realRoot = path.resolve(root);
  if (abs !== realRoot && !abs.startsWith(realRoot + path.sep)) {
    throw new PathError("path escapes sandbox");
  }
  return abs;
}

// Symlink hardening: the real path of the target (or its nearest existing parent)
// must still be within root.
export function assertRealInside(root: string, abs: string): void {
  let probe = abs;
  while (probe !== path.resolve(root) && !fs.existsSync(probe)) probe = path.dirname(probe);
  const real = fs.realpathSync(probe);
  const realRoot = fs.realpathSync(root);
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
    throw new PathError("path escapes sandbox (symlink)");
  }
}
