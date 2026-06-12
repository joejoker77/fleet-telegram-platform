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

// ── M5.9 workflow (docs/M5.9-workflow-builder-design.md) ──
// workflow = an ORCHESTRATING slash-command (commands/<name>.md): linear steps
// delegating to EXISTING subagents (Task tool) / skills (Skill tool), glued by
// free-text instructions. No new runtime — Claude Code executes the native file.

export type WorkflowStepKind = "agent" | "skill" | "note";

export interface WorkflowStep {
  kind: WorkflowStepKind;
  ref: string; // agent/skill name; unused for "note"
  task: string; // the step's task text (or the instruction body for "note")
}

export interface WorkflowFields {
  name: string;
  description: string;
  argumentHint: string;
  steps: WorkflowStep[];
}

// Compiled-file language is a COMPILER input (i18n design: lang threads through
// explicitly — the bilingual stage only adds dictionary entries, no rewrites).
export type CompileLang = "ru" | "en";

const WF_TEXT: Record<CompileLang, {
  intro: (name: string) => string;
  stepAgent: (n: number, ref: string) => string;
  runAgent: (ref: string) => string;
  stepSkill: (n: number, ref: string) => string;
  runSkill: (ref: string) => string;
  stepNote: (n: number) => string;
  outro: string;
}> = {
  ru: {
    intro: (name) =>
      `Ты — оркестратор воркфлоу «${name}». Вход: $ARGUMENTS\n` +
      "Выполни шаги строго по порядку; результат каждого шага используй в следующих.",
    stepAgent: (n, ref) => `## Шаг ${n} — субагент: ${ref}`,
    runAgent: (ref) => `Запусти субагента \`${ref}\` (Task tool, subagent_type=${ref}) с задачей:`,
    stepSkill: (n, ref) => `## Шаг ${n} — скилл: ${ref}`,
    runSkill: (ref) => `Выполни скилл \`${ref}\` (Skill tool):`,
    stepNote: (n) => `## Шаг ${n} — инструкция`,
    outro: "В конце сведи результаты шагов в один ответ пользователю.",
  },
  en: {
    intro: (name) =>
      `You are the orchestrator of the "${name}" workflow. Input: $ARGUMENTS\n` +
      "Execute the steps strictly in order; feed each step's result into the next ones.",
    stepAgent: (n, ref) => `## Step ${n} — subagent: ${ref}`,
    runAgent: (ref) => `Run the \`${ref}\` subagent (Task tool, subagent_type=${ref}) with the task:`,
    stepSkill: (n, ref) => `## Step ${n} — skill: ${ref}`,
    runSkill: (ref) => `Run the \`${ref}\` skill (Skill tool):`,
    stepNote: (n) => `## Step ${n} — instruction`,
    outro: "Finally, merge the step results into one answer for the user.",
  },
};

export function compileWorkflow(f: WorkflowFields, lang: CompileLang = "ru"): { path: string; content: string } {
  const T = WF_TEXT[lang];
  const fm = ["---"];
  if (f.description) fm.push(`description: ${yamlValue(f.description)}`);
  if (f.argumentHint) fm.push(`argument-hint: ${yamlValue(f.argumentHint)}`);
  fm.push("---");
  const parts: string[] = [fm.join("\n"), "", T.intro(f.name), ""];
  f.steps.forEach((s, i) => {
    const n = i + 1;
    if (s.kind === "agent") parts.push(T.stepAgent(n, s.ref), T.runAgent(s.ref), s.task.trim(), "");
    else if (s.kind === "skill") parts.push(T.stepSkill(n, s.ref), T.runSkill(s.ref), s.task.trim(), "");
    else parts.push(T.stepNote(n), s.task.trim(), "");
  });
  parts.push(T.outro, "");
  return { path: `commands/${f.name}.md`, content: parts.join("\n") };
}
