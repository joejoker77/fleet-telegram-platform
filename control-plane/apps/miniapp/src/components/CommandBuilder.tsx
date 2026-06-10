import { useMemo, useState } from "react";

import { compileCommand, validateName, type CommandFields } from "../builders/compile";
import { BuilderShell } from "./BuilderShell";

export function CommandBuilder({
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
  const [body, setBody] = useState("");

  const fields: CommandFields = useMemo(
    () => ({ name: name.trim(), description: description.trim(), argumentHint: argumentHint.trim(), body }),
    [name, description, argumentHint, body],
  );

  const formValid = validateName(fields.name) ?? (fields.body.trim() ? null : "Тело команды пусто");
  const compiled = fields.name && fields.body.trim() ? compileCommand(fields) : null;

  return (
    <BuilderShell
      token={token}
      title="Новая slash-команда"
      compiled={compiled}
      formValid={formValid}
      existingPaths={existingPaths}
      onClose={onClose}
      onSaved={onSaved}
    >
      <label>
        Имя — станет /{name || "имя"}
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="daily-report" />
      </label>
      <label>
        Description (для /help)
        <input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Собрать дневной отчёт" />
      </label>
      <label>
        Подсказка аргументов
        <input value={argumentHint} onChange={(e) => setArgumentHint(e.target.value)} placeholder="[дата] [проект]" />
      </label>
      <label>
        Тело команды (промпт; $ARGUMENTS подставит аргументы)
        <textarea
          rows={8}
          value={body}
          onChange={(e) => setBody(e.target.value)}
          placeholder={"Собери отчёт за $ARGUMENTS:\n1. …"}
        />
      </label>
    </BuilderShell>
  );
}
