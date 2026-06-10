// Minimal line diff (LCS) for the pre-save review screen. Good enough for
// .claude/ artifacts (small text files, ≤1 MiB enforced server-side); swap
// for a library only if real usage hits its O(n·m) wall.

export interface DiffLine {
  kind: "same" | "add" | "del";
  text: string;
}

export function diffLines(before: string, after: string): DiffLine[] {
  const a = before.split("\n");
  const b = after.split("\n");
  const n = a.length;
  const m = b.length;
  // LCS table
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i]![j] = a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }
  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ kind: "same", text: a[i]! });
      i++;
      j++;
    } else if (lcs[i + 1]![j]! >= lcs[i]![j + 1]!) {
      out.push({ kind: "del", text: a[i]! });
      i++;
    } else {
      out.push({ kind: "add", text: b[j]! });
      j++;
    }
  }
  for (; i < n; i++) out.push({ kind: "del", text: a[i]! });
  for (; j < m; j++) out.push({ kind: "add", text: b[j]! });
  return out;
}

export function hasChanges(d: DiffLine[]): boolean {
  return d.some((l) => l.kind !== "same");
}
