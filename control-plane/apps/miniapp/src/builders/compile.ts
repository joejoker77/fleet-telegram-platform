// Compile builder forms into the exact bytes written to .claude/ — the raw
// view shows precisely this output (design doc 10: builders are форма +
// обязательный raw view; no hidden transforms).

export interface SubagentFields {
  name: string;
  description: string;
  tools: string[]; // empty = inherit all
  model: "inherit" | "sonnet" | "opus" | "haiku";
  prompt: string;
}

export interface CommandFields {
  name: string;
  description: string;
  argumentHint: string;
  body: string;
}

export const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

export function validateName(name: string): string | null {
  if (!name) return "Имя обязательно";
  if (!NAME_RE.test(name)) return "Только строчные латинские буквы/цифры через дефис (kebab-case)";
  if (name.length > 64) return "Слишком длинное имя (макс. 64)";
  return null;
}

// YAML frontmatter values: keep on one line, quote when YAML could misparse.
function yamlValue(s: string): string {
  const oneLine = s.replace(/\s*\n\s*/g, " ").trim();
  if (/^[A-Za-z0-9][A-Za-z0-9 ,._()/-]*$/.test(oneLine)) return oneLine;
  return JSON.stringify(oneLine); // JSON string is valid YAML double-quoted scalar
}

export function compileSubagent(f: SubagentFields): { path: string; content: string } {
  const lines = ["---", `name: ${yamlValue(f.name)}`, `description: ${yamlValue(f.description)}`];
  if (f.tools.length > 0) lines.push(`tools: ${f.tools.join(", ")}`);
  if (f.model !== "inherit") lines.push(`model: ${f.model}`);
  lines.push("---", "", f.prompt.trim(), "");
  return { path: `agents/${f.name}.md`, content: lines.join("\n") };
}

export function compileCommand(f: CommandFields): { path: string; content: string } {
  const fm = ["---"];
  if (f.description) fm.push(`description: ${yamlValue(f.description)}`);
  if (f.argumentHint) fm.push(`argument-hint: ${yamlValue(f.argumentHint)}`);
  fm.push("---");
  const head = fm.length > 2 ? fm.join("\n") + "\n\n" : "";
  return { path: `commands/${f.name}.md`, content: `${head}${f.body.trim()}\n` };
}

/** Tools commonly granted to subagents — the form offers these as toggles. */
export const KNOWN_TOOLS = ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "WebFetch", "WebSearch"] as const;
