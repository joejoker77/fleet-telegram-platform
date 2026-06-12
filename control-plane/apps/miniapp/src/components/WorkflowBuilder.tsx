import { useEffect, useMemo, useState } from "react";

import { fsTreeScoped } from "../api";
import { compileWorkflow, validateName, type WorkflowFields, type WorkflowStep, type WorkflowStepKind } from "../builders/compile";
import { t } from "../i18n";
import { BuilderShell } from "./BuilderShell";

// M5.9 (docs/M5.9-workflow-builder-design.md): linear steps over EXISTING
// subagents/skills → compiled client-side into commands/<name>.md. Zero new
// API surface: refs enumerated via the scoped fs/tree, save via PUT /fs/file.

const KINDS: WorkflowStepKind[] = ["agent", "skill", "note"];

export function WorkflowBuilder({
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
  const [argumentHint, setArgumentHint] = useState("");
  const [steps, setSteps] = useState<WorkflowStep[]>([{ kind: "note", ref: "", task: "" }]);
  const [agents, setAgents] = useState<string[] | null>(null);
  const [skills, setSkills] = useState<string[] | null>(null);

  // Enumerate existing subagents/skills from the artifacts scope (one lazy
  // level each; a missing dir 404s → empty list).
  useEffect(() => {
    fsTreeScoped(token, "artifacts", "agents")
      .then((r) =>
        setAgents(
          r.entries.filter((e) => e.type === "file" && e.path.endsWith(".md")).map((e) => (e.name ?? e.path).replace(/\.md$/, "")),
        ),
      )
      .catch(() => setAgents([]));
    fsTreeScoped(token, "artifacts", "skills")
      .then((r) => setSkills(r.entries.filter((e) => e.type === "dir").map((e) => e.name ?? e.path)))
      .catch(() => setSkills([]));
  }, [token]);

  const fields: WorkflowFields = useMemo(
    () => ({
      name: name.trim(),
      description: description.trim(),
      argumentHint: argumentHint.trim(),
      steps,
    }),
    [name, description, argumentHint, steps],
  );

  const stepError = (): string | null => {
    if (steps.length === 0) return t("wf.err.noSteps");
    for (const [i, s] of steps.entries()) {
      if (s.kind !== "note" && !s.ref) return t("wf.err.stepRef", { n: i + 1 });
      if (!s.task.trim()) return t("wf.err.stepTask", { n: i + 1 });
    }
    return null;
  };
  const formValid = validateName(fields.name) ?? stepError();

  const compiled = fields.name && formValid === null ? compileWorkflow(fields, "ru") : null;

  const patchStep = (i: number, patch: Partial<WorkflowStep>) =>
    setSteps((prev) => prev.map((s, j) => (j === i ? { ...s, ...patch } : s)));
  const moveStep = (i: number, d: -1 | 1) =>
    setSteps((prev) => {
      const j = i + d;
      const a = prev[i];
      const b = prev[j];
      if (a === undefined || b === undefined) return prev;
      const next = [...prev];
      next[i] = b;
      next[j] = a;
      return next;
    });
  const removeStep = (i: number) => setSteps((prev) => prev.filter((_, j) => j !== i));
  const addStep = () => setSteps((prev) => [...prev, { kind: "note", ref: "", task: "" }]);

  const refsFor = (kind: WorkflowStepKind): string[] | null => (kind === "agent" ? agents : kind === "skill" ? skills : []);

  return (
    <BuilderShell
      token={token}
      title={t("wf.title")}
      compiled={compiled}
      formValid={formValid}
      existingPaths={existingPaths}
      onClose={onClose}
      onSaved={onSaved}
    >
      <label>
        {t("wf.name")}
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="release-check" />
      </label>
      <label>
        {t("wf.description")}
        <textarea rows={2} value={description} onChange={(e) => setDescription(e.target.value)} />
      </label>
      <label>
        {t("wf.argumentHint")}
        <input value={argumentHint} onChange={(e) => setArgumentHint(e.target.value)} placeholder="[ветка или тег]" />
      </label>

      <fieldset>
        <legend>{t("wf.steps")}</legend>
        {agents === null || skills === null ? (
          <p className="muted">{t("wf.loadingRefs")}</p>
        ) : (
          <>
            {steps.map((s, i) => {
              const refs = refsFor(s.kind);
              return (
                <div key={i} className="wf-step">
                  <div className="wf-step-head">
                    <strong>{i + 1}.</strong>
                    <select
                      value={s.kind}
                      onChange={(e) => patchStep(i, { kind: e.target.value as WorkflowStepKind, ref: "" })}
                    >
                      {KINDS.map((k) => (
                        <option key={k} value={k} disabled={k === "agent" ? agents.length === 0 : k === "skill" ? skills.length === 0 : false}>
                          {t(k === "agent" ? "wf.kind.agent" : k === "skill" ? "wf.kind.skill" : "wf.kind.note")}
                        </option>
                      ))}
                    </select>
                    {s.kind !== "note" && (
                      <select value={s.ref} onChange={(e) => patchStep(i, { ref: e.target.value })}>
                        <option value="">{t("wf.pickRef")}</option>
                        {(refs ?? []).map((r) => (
                          <option key={r} value={r}>
                            {r}
                          </option>
                        ))}
                      </select>
                    )}
                    <span className="wf-step-actions">
                      <button className="ghost" disabled={i === 0} onClick={() => moveStep(i, -1)}>
                        ↑
                      </button>
                      <button className="ghost" disabled={i === steps.length - 1} onClick={() => moveStep(i, 1)}>
                        ↓
                      </button>
                      <button className="ghost" onClick={() => removeStep(i)}>
                        ✕
                      </button>
                    </span>
                  </div>
                  <textarea
                    rows={3}
                    value={s.task}
                    onChange={(e) => patchStep(i, { task: e.target.value })}
                    placeholder={t(s.kind === "agent" ? "wf.task.agent" : s.kind === "skill" ? "wf.task.skill" : "wf.task.note")}
                  />
                </div>
              );
            })}
            <button onClick={addStep}>{t("wf.addStep")}</button>
            {agents.length === 0 && <p className="muted">{t("wf.noAgents")}</p>}
            {skills.length === 0 && <p className="muted">{t("wf.noSkills")}</p>}
            <p className="muted">{t("wf.hint")}</p>
          </>
        )}
      </fieldset>
    </BuilderShell>
  );
}
