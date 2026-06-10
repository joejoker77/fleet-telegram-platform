// Offline smoke for the path-confinement core (no deps, no infra). Proves the
// authoring file API cannot be tricked into reading/writing outside the tenant's
// ~/.claude sandbox. Run: tsx src/fs-safety.smoke.ts
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { safeResolve, assertRealInside, PathError } from "./fs-safety.js";

let pass = 0,
  fail = 0;
const ok = (c: boolean, m: string) => (c ? (pass++, console.log(`  ✓ ${m}`)) : (fail++, console.error(`  ✗ ${m}`)));
const throws = (fn: () => unknown) => {
  try {
    fn();
    return false;
  } catch (e) {
    return e instanceof PathError;
  }
};

const root = fs.mkdtempSync(path.join(os.tmpdir(), "sbx-")) + "/.claude";
fs.mkdirSync(path.join(root, "skills"), { recursive: true });

// allowed
ok(safeResolve(root, "skills/x.md") === path.join(root, "skills/x.md"), "normal nested path allowed");
ok(safeResolve(root, "settings.json") === path.join(root, "settings.json"), "top-level file allowed");
ok(safeResolve(root, "/etc/passwd") === path.join(root, "etc/passwd"), "leading slash treated as sandbox-relative");
ok(safeResolve(root, "") === root, "empty path resolves to root");

// rejected escapes
ok(throws(() => safeResolve(root, "../../etc/passwd")), "../.. escape rejected");
ok(throws(() => safeResolve(root, "a/../../b")), "mid-path .. escape rejected");
ok(throws(() => safeResolve(root, "../.claude-other/x")), "sibling-dir escape rejected");

// symlink escape: a symlink inside the sandbox pointing out must be caught
const linkPath = path.join(root, "evil-link");
try {
  fs.symlinkSync("/etc", linkPath);
  ok(throws(() => assertRealInside(root, path.join(linkPath, "passwd"))), "symlink-out escape rejected");
} catch {
  console.log("  (skip symlink test — symlink not permitted here)");
}
// a real in-sandbox path passes the symlink check
ok(!throws(() => assertRealInside(root, path.join(root, "skills/x.md"))), "in-sandbox path passes symlink check");

console.log(`\nfs-safety smoke: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
