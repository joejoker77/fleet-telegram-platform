# 00 — Текущее состояние (прототип «Genesis»)

Снимок того, что реально работает на сервере сейчас. Источник правды для планирования миграции. Пути — реальные серверные, от `/opt/workspace/`.

## Модель запуска
- **systemd template-unit** [`scripts/claude-tg@.service`](/opt/workspace/scripts/claude-tg@.service): один файл на N пользователей, `User=%i`, `WorkingDirectory=/home/%i/work`, `Restart=always`, `RestartSec=20`, `StartLimitBurst=10/300s`. Уже включает сильный hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`, `RestrictAddressFamilies`, `RestrictNamespaces` и т.д.).
- **Лаунчер** [`scripts/claude-tg-launcher`](/opt/workspace/scripts/claude-tg-launcher): поднимает Claude Code внутри `tmux`-сессии `claude` (нужен реальный pty, иначе Claude уходит в `--print` и падает). Источает `$TELEGRAM_STATE_DIR/.env`, запускает `claude --channels plugin:telegram@claude-plugins-official --remote-control <user>-main`.
- **Восстановление контекста — «костыль»:** после старта в фоне (sleep 15) лаунчер `tail`-ит прошлый лог сессии и вливает его в TUI через `tmux load-buffer`/`paste-buffer` + `send-keys Enter`. Дублируется логикой Patch 20 в самом плагине. Это место в целевой архитектуре заменяется нативным `--resume`/`--continue`.

## Telegram-плагин
- [`scripts/telegram-plugin/server.ts`](/opt/workspace/scripts/telegram-plugin/server.ts) (~2090 строк, Bun + grammY) — самодостаточный MCP-сервер-канал (stdio transport). Реализует: pairing/allowlist/группы, reply/react/edit/download, FSM «🧠 Thinking…» плейсхолдеров (захват TUI через `tmux capture-pane`), relay permission-запросов в inline-кнопки, session-restore (Patch 20).
- **Один потребитель `getUpdates` на токен.** Плагин пишет свой PID в `bot.pid` и при старте **убивает прежнего держателя токена** (`process.kill(stale, 'SIGTERM')`, строки 64-72). Есть orphan-watchdog по смене `ppid` (строки 1659-1666) и shutdown по EOF stdin.
- Состояние канала: `~/.claude/channels/telegram-<user>/` (`access.json`, `.env`, `topics.json`, `placeholders.json`, `inbox/`, `logs/`).

## Логирование сессий
- [`scripts/claude_session_logger.sh`](/opt/workspace/scripts/claude_session_logger.sh): cron от root каждую минуту, `sudo -u <user> tmux capture-pane` → дифф по числу строк → дозапись в `logs/session_current.txt` (ротация на 2 МБ, ретеншн 14 дней). Эти логи и используются для session-restore.

## Секреты (как есть — небезопасно)
- **Bot-токен и chat_id в открытую** в [`config.json`](/opt/workspace/config.json), плюс в `$TELEGRAM_STATE_DIR/.env`.
- **Ключ Composio в открытую** в [`.mcp.json`](/opt/workspace/.mcp.json) (`x-api-key`).
- **n8n-JWT зашит прямо в правила `permissions.allow`** в [`.claude/settings.local.json`](/opt/workspace/.claude/settings.local.json) (несколько `curl ... -H "X-N8N-API-KEY: <jwt>"`).
- В `.env` пользователя — `ELEVENLABS_API_KEY`, `OPENROUTER_API_KEY`, `N8N_API_KEY`, `DATA_DB_PASSWORD` и пр.

> Важно: эти значения присутствуют в снимке прототипа в репозитории. При миграции они подлежат **обязательной ротации** (считать скомпрометированными). См. [04-secrets-and-data-migration.md](04-secrets-and-data-migration.md).

## Интеграции
- **Composio** через MCP (`enableAllProjectMcpServers: true`, `enabledMcpjsonServers: ["composio"]`) + хелперы `composio-connect`, `composio_callback.py`, `composio-proxy/`.
- **Exa** — ключ в `.env`, используется для ресёрча.
- **n8n** — внешние workflow/эскалации (`scripts/n8n_escalate_workflow.json`), вызовы через `curl` к `monacosolicitors.app.n8n.cloud`.
- Прочее из памяти/скиллов: ElevenLabs (STT/TTS), rclone-mount (iCloud/GDrive), скилл `uk-tourist-visa`, дневные отчёты (`claude_daily_report.py`), крон-задачи (англоязычный блог, дайджесты).
- **Доступ к Anthropic** — OAuth-логин Claude (`claude login` → `~/.claude/.credentials.json`), подписка **Team**. На сервере у каждого пользователя **свой** `credentials.json` (хэши различаются) → фактически **seat на пользователя** уже реализован. В `provision_user.sh` есть устаревшая опция «скопировать один `credentials.json` на ~5 пользователей» — анти-паттерн, не используем. Сессии поднимаются с `--remote-control` (доступ через claude.ai/code).
- **openclaw** — следы в `permissions` (gateway), исторический способ доступа к подписке.

## Провижининг
- [`scripts/provision_user.sh`](/opt/workspace/scripts/provision_user.sh): создание Linux-пользователя, `~/.claude/`, `.env`, окружения; источает общие переменные (где лежат ключи). Есть `role_templates/` и `memory_templates/` (стартовые `CLAUDE.md`, `feedback_*`, `reference_*`).

## Что брать в целевую архитектуру
- Концепция per-user systemd-hardening (расширяется до Podman).
- Нативный Telegram-плагин и его UX (плейсхолдеры, permission-кнопки, вложения, HTML-формат).
- Composio + Exa как интеграции по умолчанию.
- Хуки (`telegram-track-chat.sh`, `telegram-block-askuser.sh`), шаблоны ролей/памяти.

## Что переделать
- Plaintext-секреты → OneCLI + egress-контроль.
- tmux-инъекция лога для контекста → нативный `--resume`/`--continue`.
- «Убийство держателя токена» вторым `claude` → официальный плагин не патчим; основное — изолировать `claude -p` от TG-канала (не активирует канал, без общего токена), страховка — watchdog-supervisor (см. Фаза 0).
- Отсутствие egress-firewall и лимитов памяти.
- Прямой per-user seat-OAuth → тот же seat за LiteLLM-гейтвеем (fair-use, защита от падений по лимиту); `--remote-control` → web-IDE. Не возвращаться к копированию `credentials.json`.
