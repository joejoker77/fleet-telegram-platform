// M5.10 i18n foundation (docs/M5.10-workspace-scopes-design.md). The rule going
// forward: NO new UI string is hardcoded in JSX — everything goes through t().
// ru is filled now; en keeps the SAME keys and is filled at the bilingual stage
// (missing en key → ru fallback, so a half-filled dictionary never breaks UI).
// Locale: localStorage override → Telegram language_code → ru. While en is
// empty the language switcher stays hidden (isLangSwitchReady()).

export type Lang = "ru" | "en";

const ru = {
  // file tree / scopes
  "tree.scope.project": "📁 Проект",
  "tree.scope.artifacts": "🧩 Артефакты",
  "tree.scope.home": "🗂 Всё (~)",
  "tree.showHidden": "показать скрытое",
  "tree.hidden": "скрыто: {n}",
  "tree.empty": "Каталог пуст.",
  "tree.loading": "Загрузка…",
  "tree.loadError": "Не удалось загрузить каталог",
  "tree.retry": "Повторить",

  // generic API error codes (server sends a stable `code` beside the human text)
  "err.bad_scope": "Неизвестная область",
  "err.bad_path": "Недопустимый путь",
  "err.not_found": "Не найдено",
  "err.file_too_large": "Файл слишком большой",
  "err.list_failed": "Не удалось получить список",
} as const;

export type I18nKey = keyof typeof ru;

// Same keys as ru; values land here at the en stage.
const en: Partial<Record<I18nKey, string>> = {};

const dicts: Record<Lang, Partial<Record<I18nKey, string>>> = { ru, en };

function detect(): Lang {
  try {
    const saved = localStorage.getItem("lang");
    if (saved === "ru" || saved === "en") return saved;
  } catch {
    /* storage unavailable */
  }
  const tg = (window as { Telegram?: { WebApp?: { initDataUnsafe?: { user?: { language_code?: string } } } } })
    .Telegram?.WebApp?.initDataUnsafe?.user?.language_code;
  const nav = tg ?? navigator.language;
  return nav?.toLowerCase().startsWith("ru") ? "ru" : "en";
}

let lang: Lang = detect();

export function getLang(): Lang {
  return lang;
}

export function setLang(l: Lang): void {
  lang = l;
  try {
    localStorage.setItem("lang", l);
  } catch {
    /* ignore */
  }
}

/** The switcher appears only once the en dictionary is actually filled. */
export function isLangSwitchReady(): boolean {
  return Object.keys(en).length > 0;
}

export function t(key: I18nKey, vars?: Record<string, string | number>): string {
  let s = dicts[lang][key] ?? ru[key] ?? key;
  if (vars) for (const [k, v] of Object.entries(vars)) s = s.replace(`{${k}}`, String(v));
  return s;
}

/** Translate an API error by its stable code; unknown code → the server's text. */
export function tErr(code: string | undefined, fallback: string): string {
  const key = `err.${code}` as I18nKey;
  return code && key in ru ? t(key) : fallback;
}
