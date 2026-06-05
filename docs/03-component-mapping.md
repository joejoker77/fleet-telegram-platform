# 03 — Карта компонентов: текущее → целевое

Что во что превращается при миграции. Каждая строка — единица переноса с пометкой стратегии.

## Рантайм и запуск
- **systemd `claude-tg@.service` (tmux + plugin)** → **rootless-Podman контейнер на пользователя** под per-user systemd-юнитом. Hardening-директивы сохраняются как второй слой. Реализация: [08](08-runtime-and-gateways.md). Стратегия: новый юнит рядом, cutover по runbook.
- **`claude-tg-launcher` (tmux-сессия `claude`)** → лаунчер внутри контейнера; pty даёт tty контейнера. **tmux сохраняется и в целевом рантайме**: официальный плагин завязан на tmux (`capture-pane` для FSM «🧠», детект `active`-сигнала, session-logger). Без tmux + доступа к панели `claude` сломаются индикатор, квисценс при cutover и логирование. Это требование к образу контейнера.
- **Восстановление контекста: tmux `load-buffer`/`send-keys` (+ Patch 20)** → **двухступенчато**: (1) **разовый сидинг** на шве — на первом старте новой сессии один раз вливается хвост старого лога как стартовый контекст (нативный `--resume` тут «нечего» поднимать: старые `session_*.txt` — это tmux-захваты, а не resumable-сессии Claude); (2) **далее — нативный `--resume`/`--continue`**, который ведёт контекст сам. Старую постоянную инъекцию и Patch 20 не используем за пределами одноразового сидинга.
- **Жизненный цикл и подписки** → существующих пользователей при переводе раскладываем по состояниям Provisioned/Active/Idle/Suspended/Deleted и статусу подписки; включаем idle-`podman pause` и политику ретеншна. На старом стеке этих состояний нет — заводятся при cutover.
- **Эластичные ресурсы** → к лимитам памяти добавляются `CPUWeight`/`IOWeight` (мягкое, но эластичное распределение из целевого дизайна), не только `MemoryMax`.

## Telegram-канал
- **`server.ts` как канал (stdio-MCP-ребёнок `claude`)** → **остаётся официальным плагином — ребёнком ОСНОВНОЙ сессии `claude`**. Делать из него самостоятельный демон нельзя без патча/переписывания (исключено). Поэтому: «надзор» = watchdog-supervisor рестартит **весь юнит** по `bot.pid` (`systemctl restart`); «развязка от `claude -p`» = **предотвращение** того, что дочерний `claude -p` поднимет конкурирующий канал (не активирует канал + без общего токена/`bot.pid`). Полноценный «отдельный надзираемый channel-процесс» из целевого дизайна достижим только при будущем переписывании канала — вне скоупа миграции. **Официальный плагин не патчим.** См. [01-stabilization-hotfixes.md](01-stabilization-hotfixes.md).
- **«Новый экземпляр убивает держателя токена» / orphan-watchdog по `ppid`** → поведение плагина не меняем; основное лечение — **предотвращение** (второй экземпляр по `-p` вообще не касается токена), плюс **рекавери** watchdog'ом на прочие отвалы.
- **Состояние канала `~/.claude/channels/telegram-<user>/`** (`access.json`, `topics.json`, `placeholders.json`, `inbox/`) → переносится как есть (см. [04](04-secrets-and-data-migration.md)).
- **bot-токен** → **остаётся тем же** (ключ бесшовности), но переезжает из `.env`/`config.json` в OneCLI.

## Доступ к модели
- **Прямой per-user OAuth seat (Anthropic Team, `claude login` → свой `credentials.json`; + `--remote-control`)** → тот же **per-user Team seat, но за LiteLLM-гейтвеем** (`ANTHROPIC_BASE_URL`), pluggable-режим (Team seat / API), per-user fair-use/квоты/очередь, метеринг. Реализация: [08](08-runtime-and-gateways.md). Это же лечит рестарты по лимиту seat (Проблема B). **Не возвращаемся** к копированию `credentials.json` между пользователями (анти-паттерн прототипа).

## Секреты
- **`config.json` (bot_token), `.mcp.json` (Composio key), `settings.local.json` (n8n-JWT), `.env` (Exa/ElevenLabs/OpenRouter/DB)** → **OneCLI vault + egress-подмена по host/path**, агент видит только заполнители. Все значения **ротируются**. Реализация: [08](08-runtime-and-gateways.md); детали переноса: [04](04-secrets-and-data-migration.md).

## Сеть
- **Свободный egress контейнера/процесса** → **nftables default-deny**, выход только на LiteLLM/OneCLI/белый список (Composio, Exa). Реализация: [08](08-runtime-and-gateways.md).

## Безопасность
- **`permissions.allow` со встроенными секретами и широкими правилами** → **слоистый `settings.json`**: платформенный locked-слой (security-хуки, deny-list, привязка к гейтвею) + пользовательский `settings.local.json` через AgentShield-гейт.
- **Нет фильтра команд** → **shellfirm** `PreToolUse` (одинаково для терминала web-IDE и агента).
- **Нет сканирования артефактов/MCP** → **MCP/Skill Scanner + AgentShield + Promptfoo** через **Judge Orchestrator**. Реализация: [09](09-security-stack.md).
- **Хуки `telegram-track-chat.sh`, `telegram-block-askuser.sh`** → сохраняются; `block-askuser` эволюционирует в inline-кнопки/очередь аппрувов Mini App.

## Логирование/аудит
- **root-cron `claude_session_logger.sh` (tmux capture → файл, 14 дней)** → на переходный период остаётся; затем **нативные логи сессии + централизованный append-only аудит** вне контейнера. Реализация: [07](07-control-plane.md).

## Интеграции
- **Composio (MCP, ключ в `.mcp.json`), `composio-connect`, `composio_callback.py`, `composio-proxy/`** → Composio по умолчанию, ключ в OneCLI, callback — сервис control plane, egress в белом списке. Реализация: [11](11-integrations.md).
- **Exa** → интеграция по умолчанию, ключ в OneCLI.
- **n8n (внешние workflow/эскалации, `n8n_escalate_workflow.json`)** → на MVP **не переносим как движок** (workflow = нативная композиция, см. [12](12-artifacts-sharing.md)); эскалационные уведомления → admin notifications control plane. n8n опционален в будущем.
- **ElevenLabs (STT/TTS), rclone-mount** → переносятся как пользовательские навыки/задачи; ключи в OneCLI; egress в белый список. Голос — расширение по дорожной карте.
- **Плановые задачи root-cron (`daily report`, блог, `ai_digest`, `vfs_monitor`)** → переносятся на **per-user планировщик внутри контейнера** (systemd user-таймеры/cron в песочнице) либо на планировщик control plane; запускаются под shellfirm/OneCLI/egress, как любая агентная задача. Прямой root-cron хоста не переносится.

## Онбординг и доступ
- **`/start` + код пейринга → `access.json`** (модель прототипа) → целевая модель: пользователь **заранее заведён и одобрен админом**, `/start` лишь стартует сессию (провижининг — [07](07-control-plane.md)). Для существующих пользователей `access.json` переносится как есть (пейринг не теряется); сдвиг модели онбординга применяется к **новым** пользователям после миграции.
- **Браузерный доступ через `--remote-control` (claude.ai/code)** → **убирается** (привязан к хостингу/OAuth Anthropic, несовместим с доступом через LiteLLM) и **заменяется per-user web-IDE** (см. [10](10-authoring-miniapp-ide.md)).

## Провижининг и шаблоны
- **`provision_user.sh` (Linux-user + `.claude` + общий `.env`)** → **Provisioner control plane** (OS-учётка + Podman + scaffold `.claude/` + выдача bot-токена и onecli-токена + запись в Postgres). Реализация: [07](07-control-plane.md), [08](08-runtime-and-gateways.md).
- **`role_templates/`, `memory_templates/` (`feedback_*`, `reference_*`)** → переносятся как стартовые `CLAUDE.md`/память; часть `feedback_*` (например, «читать логи на рестарте») теряет смысл при нативном `--resume` — ревизируется.

## Артефакты пользователя
- **`skills/` (напр. `uk-tourist-visa`), `docs/`, рабочие файлы** → переносятся в песочницу пользователя как есть; при включении обмена проходят сканеры. Реализация: [12](12-artifacts-sharing.md).
