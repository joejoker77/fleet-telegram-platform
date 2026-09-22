// Portability lint — will this skill work on a colleague's machine?
//
// DELIBERATELY NOT PART OF THE SAFETY SCAN. The deterministic findings in
// deterministic.ts are fed to the judge that decides pass/fail, so a style
// observation placed there ("the author's name is used as the actor") could end up
// refusing a publish. Julian asked for the opposite: warn the bot so it fixes the
// skill, never block it. So this has no vote on the verdict, is never shown to the
// judge, and its only output is advice printed after a successful publish.
//
// It exists because the guide already tells bots to generalise before sharing, and
// two of the first five catalogue skills turned out to be duplicates that only ran
// on their author's machine — the guide catches the diligent, this catches the rest.
import fs from "node:fs";
import path from "node:path";

export interface PortabilityWarning {
  rule: string;
  file: string;
  line: number;
  message: string;
  excerpt: string;
}

// Helpers every workspace has, from runtime/install/tenant-skel/work/bin. A path into
// ~/work/bin that is NOT one of these does not exist for the colleague installing the
// skill. Keep in step with the skeleton; an extra name here only costs a missed warning.
const STANDARD_TOOLS = new Set([
  "check-my-access", "deal-brief", "field-map", "my-deadlines", "my-matters",
  "pd-attachments", "pd-upload", "report-daemon", "report-schedule", "sa-sign",
  "share-skill", "stt-transcribe", "tg-file",
]);

const TEXT_EXT = /\.(md|markdown|txt|ya?ml|json|sh|py|js|ts)$/i;

function nameTokens(osUsername: string): string[] {
  // daria-rudenko -> ["daria","rudenko"]. A username with no separators (tonysoprano1337)
  // yields one token and is matched whole; that is weaker, and deliberately not guessed at.
  return osUsername
    .split(/[-_.]+/)
    .map((t) => t.replace(/[0-9]+$/, ""))
    .filter((t) => t.length >= 3 && /^[a-z]+$/i.test(t));
}

function walk(dir: string, out: string[] = []): string[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === "node_modules" || e.name === ".git" || e.name === "__pycache__") continue;
      walk(full, out);
    } else if (TEXT_EXT.test(e.name)) {
      out.push(full);
    }
  }
  return out;
}

/** Lint one already-read file. Exported so the retro run and the publish path share it. */
export function lintText(relPath: string, text: string, owner: string): PortabilityWarning[] {
  const warnings: PortabilityWarning[] = [];
  const tokens = nameTokens(owner);
  const ownerRe = tokens.length ? new RegExp(`\\b(${tokens.join("|")})\\b`, "i") : null;
  const lines = text.split("\n");

  // Credit lines are legitimate: the guide keeps the owner as the named source of the
  // method. Only the first name hit is reported, so a skill is not buried in repeats.
  let namedAlready = false;

  lines.forEach((raw, i) => {
    const line = raw.trim();
    if (!line) return;
    const at = (rule: string, message: string) =>
      warnings.push({ rule, file: relPath, line: i + 1, message, excerpt: line.slice(0, 120) });

    if (ownerRe && !namedAlready && ownerRe.test(line)) {
      namedAlready = true;
      at("author-name",
         "the author's name appears here — if it names who does the work, say \"the lawyer\"; keep it only as the credited source of the method");
    }

    // Machine-local paths. ~/work/bin/<standard tool> is fine; anything else under a home
    // directory is this author's own and will not exist for anyone installing the skill.
    const pathRe = /(?:~|\/home\/[A-Za-z0-9._-]+)\/[A-Za-z0-9._\-/]+/g;
    for (const m of line.match(pathRe) ?? []) {
      const tool = m.match(/\/work\/bin\/([A-Za-z0-9._-]+)/)?.[1];
      if (tool && STANDARD_TOOLS.has(tool)) continue;
      if (/^~\/work\/?$/.test(m) || /^~\/work\/bin\/?$/.test(m)) continue;
      at("local-path",
         `"${m}" exists on this machine only — replace it with a fetch every workspace can do (pd-attachments, deal-brief, the firm's APIs)`);
      break; // one per line is enough to make the point
    }

    if (/\[\[[^\]]+\]\]/.test(line)) {
      at("memory-link", "a [[memory]] link points at this workspace's memory — inline what it says or drop it");
    }

    const personal = [
      { re: /calendly\.com\/[A-Za-z0-9._-]+/i, what: "a personal Calendly link" },
      { re: /\bca_[A-Za-z0-9]{8,}\b/, what: "a Composio connected-account id" },
      { re: /--user-id\s+\d{6,}/, what: "a hardcoded Telegram chat id" },
      { re: /--alias\s+[A-Za-z0-9._-]+/, what: "a personal account alias" },
      { re: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, what: "a mailbox address" },
    ];
    for (const p of personal) {
      if (p.re.test(line)) {
        at("personal-identifier", `${p.what} is tied to one person — say "your own connection" instead`);
        break;
      }
    }
  });

  return warnings;
}

/** Lint a skill directory as it sits in a tenant's workspace. */
export function portabilityLint(dir: string, owner: string): PortabilityWarning[] {
  const out: PortabilityWarning[] = [];
  for (const file of walk(dir)) {
    let text: string;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    out.push(...lintText(path.relative(dir, file) || path.basename(file), text, owner));
  }
  return out;
}

/** One line per warning, for a terminal or a Telegram message. */
export function formatWarnings(ws: PortabilityWarning[]): string[] {
  return ws.map((w) => `${w.file}:${w.line}  [${w.rule}] ${w.message}`);
}
