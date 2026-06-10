import { useMemo, useState } from "react";

import { compileSubagent, KNOWN_TOOLS, validateName, type SubagentFields } from "../builders/compile";
import { BuilderShell } from "./BuilderShell";

export function SubagentBuilder({
  token,
  existingPaths,
  onClose,
  onSaved,
}: {
  token: string;
  existingPaths: Set<string>;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [tools, setTools] = useState<string[]>([]);
  const [extraTools, setExtraTools] = useState("");
  const [model, setModel] = useState<SubagentFields["model"]>("inherit");
  const [prompt, setPrompt] = useState("");

  const fields: SubagentFields = useMemo(
    () => ({
      name: name.trim(),
      description: description.trim(),
      tools: [
        ...tools,
        ...extraTools
          .split(",")
          .map((t) => t.trim())
          .filter(Boolean),
      ],
      model,
      prompt,
    }),
    [name, description, tools, extraTools, model, prompt],
  );

  const formValid =
    validateName(fields.name) ??
    (fields.description ? null : "Description обязателен — по нему делегируются задачи") ??
    (fields.prompt.trim() ? null : "Системный промпт пуст");

  const compiled = fields.name && fields.description && fields.prompt.trim() ? compileSubagent(fields) : null;

  const toggleTool = (t: string) =>
    setTools((prev) => (prev.includes(t) ? prev.filter((x) => x !== t) : [...prev, t]));

  return (
    <BuilderShell
      token={token}
      title="Новый субагент"
      compiled={compiled}
      formValid={formValid}
      existingPaths={existingPaths}
      onClose={onClose}
      onSaved={onSaved}
    >
      <label>
        Имя (kebab-case)
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="code-reviewer" />
      </label>
      <label>
        Description — когда его звать
        <textarea
          rows={2}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Reviews code for bugs after each change"
        />
      </label>
      <fieldset>
        <legend>Инструменты (пусто = наследует все)</legend>
        <div className="tool-grid">
          {KNOWN_TOOLS.map((t) => (
            <label key={t} className="tool-toggle">
              <input type="checkbox" checked={tools.includes(t)} onChange={() => toggleTool(t)} /> {t}
            </label>
          ))}
        </div>
        <input
          value={extraTools}
          onChange={(e) => setExtraTools(e.target.value)}
          placeholder="другие, через запятую (mcp__exa__web_search_exa, …)"
        />
      </fieldset>
      <label>
        Модель
        <select value={model} onChange={(e) => setModel(e.target.value as SubagentFields["model"])}>
          <option value="inherit">наследовать</option>
          <option value="sonnet">sonnet</option>
          <option value="opus">opus</option>
          <option value="haiku">haiku</option>
        </select>
      </label>
      <label>
        Системный промпт
        <textarea
          rows={8}
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="You are a senior code reviewer…"
        />
      </label>
    </BuilderShell>
  );
}
