# 08 — Рантайм Podman и гейтвеи (LiteLLM, OneCLI)

Майлстоун **M2**. Контейнерный рантайм пользователя (изоляция) + два гейтвея: LiteLLM (модель) и OneCLI (секреты).

Это контейнерный рантайм пользователя + два гейтвея, на которые завязан весь периметр. Образ и гейтвеи готовятся **до** пилота (M3); на старых пользователей не влияют.

## Образ контейнера пользователя (`/opt/runtime/image/Containerfile`)
Базовый Ubuntu + всё, что нужно одному тенанту. Сохраняем зависимости официального плагина (Bun, tmux).

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
      curl ca-certificates git tmux python3 nodejs npm && \
    npm i -g @anthropic-ai/claude-code && \
    curl -fsSL https://bun.sh/install | bash && \
    curl -fsSL https://code-server.dev/install.sh | sh
# VS Code-расширение Claude Code + платформенные locked-хуки + shellfirm
COPY hooks/ /opt/platform/hooks/            # locked, read-only для пользователя
COPY settings.platform.json /opt/platform/  # locked-слой settings
RUN /opt/platform/install-shellfirm.sh
ENV ANTHROPIC_BASE_URL=http://litellm.internal:4000
ENTRYPOINT ["/opt/platform/entrypoint.sh"]  # поднимает tmux+claude (канал) и code-server
```

`entrypoint.sh` поднимает: tmux-сессию `claude` с официальным плагином (как в прототипе, без патча), `code-server`, и логирует в аудит. Контекст первой сессии — разовый сидинг старого лога, далее нативный `--resume` (см. [04](04-secrets-and-data-migration.md)).

## Per-user systemd template-unit (`/opt/runtime/systemd/claude-pod@.service`)
Оборачивает запуск контейнера, наследует hardening прототипа как второй слой + cgroups-лимиты.

```ini
[Service]
User=%i
ExecStart=/usr/bin/podman run --rm --name claude-%i \
  --userns=keep-id --cap-drop=ALL --security-opt=no-new-privileges \
  --read-only --tmpfs /tmp \
  -v /home/%i/.claude:/home/%i/.claude -v /home/%i/work:/home/%i/work \
  -v /run/audit/collector.sock:/run/audit/collector.sock:rw \
  --network=ns:/var/run/netns/claude-%i \
  claude-user:latest
# Эластичные ресурсы
CPUWeight=100
CPUQuota=200%
MemoryHigh=3G
MemoryMax=4G
MemoryAccounting=true
IOWeight=100
OOMPolicy=continue
Restart=always
RestartSec=20
```

- **Rootless Podman**, `--userns=keep-id`, drop capabilities, seccomp-профиль, read-only rootfs + tmpfs.
- **Idle → `podman pause`** через provisioner/idle-детектор (экономия CPU/RAM, быстрый резюм).
- **Watchdog-supervisor** (из [01](01-stabilization-hotfixes.md)) переносится: следит за здоровьем канала по `bot.pid`.

## Сетевой egress (`/opt/runtime/nftables/`)
У контейнера — отдельный netns; egress **default-deny**, разрешены только гейтвеи и белый список.

```nft
table inet egress_%i {
  chain output {
    type filter hook output priority 0; policy drop;
    ct state established,related accept
    ip daddr $LITELLM_IP tcp dport 4000 accept     # модель
    ip daddr $ONECLI_IP   tcp dport 10255 accept   # секреты
    ip daddr @whitelist accept                     # Composio backend, Exa
    udp dport 53 ip daddr $DNS_RESOLVER accept      # контролируемый DNS
  }
}
```

Любой новый egress-хост → через onecli-привязку/авто-пайплайн, не правкой firewall вручную пользователем.

## LiteLLM gateway (`/opt/gateways/litellm/`)
Единая точка доступа к модели; режим — **Team seat пользователя** (один seat = один пользователь; см. [03](03-component-mapping.md), [01](01-stabilization-hotfixes.md)).

> **БЛОКИРУЮЩИЙ спайк S1 — провести ДО M2 (несущий риск).**
> LiteLLM спроектирован под **API-ключи**, а флот сидит на **подписочном Team-seat (OAuth)**, который маршрутизируется через `ANTHROPIC_BASE_URL`. На этом маршруте висят **и метеринг, и «лечение рестартов по лимиту»** — если он не работает, рушится половина стека. Поэтому **до строительства M2** доказать на одном тестовом seat сквозной путь: `claude` → `ANTHROPIC_BASE_URL=http://litellm.internal:4000` → LiteLLM → Anthropic, с форвардом OAuth-заголовков seat (`forward_client_headers_to_llm_api`).
> - **Что проверить (все 4 — критерий go):** (1) авторизация и ответ модели проходят через LiteLLM на OAuth-seat (не на API-ключе); (2) **стриминг** работает без обрывов; (3) **usage снимается per-user** (видно в LiteLLM/Postgres); (4) при приближении к лимиту seat — **троттлинг/деградация**, а не падение сессии.
> - **Fallback при no-go:** тонкий **прозрачный reverse-proxy** перед Anthropic (только метеринг + троттлинг по `Authorization`, без вмешательства в OAuth) вместо LiteLLM; либо перевод флота на **Anthropic API-ключи** (меняет ToS/биллинг — согласовать). Выбранный исход зафиксировать как ADR-дельту в [02](02-strategy-and-phases.md).
> - **Если спайк не пройден — M2 строится на fallback-маршруте**, конфиг ниже заменяется соответствующим.

```yaml
# config.yaml
model_list:
  - model_name: opus
    litellm_params:
      model: anthropic/claude-opus-4-latest
general_settings:
  master_key: ${LITELLM_MASTER_KEY}
  database_url: ${LITELLM_DB}          # virtual keys, usage
litellm_settings:
  forward_client_headers_to_llm_api: true   # форвард seat-OAuth пользователя
  # per-user virtual keys с бюджетами/лимитами (fair-use)
```

- **Virtual key на пользователя** (создаёт provisioner) → `x-litellm-api-key`; для учёта/квот/деградации.
- Контейнер ходит через `ANTHROPIC_BASE_URL=http://litellm.internal:4000`; OAuth-токен seat пользователя форвардится.
- **usage_records** в Postgres агрегируются из LiteLLM (дашборд расхода, [10](10-authoring-miniapp-ide.md)).
- Очередь/троттлинг/деградация при приближении к лимиту seat — вместо падения сессии (лечит рестарты «по лимиту», [01](01-stabilization-hotfixes.md)).

## OneCLI gateway (`/opt/gateways/onecli/`)
Секреты: агент видит только заполнители, реальные подставляются на egress по host+path (детали переноса — [04](04-secrets-and-data-migration.md)).

- Rust-gateway (порт 10255) + Next.js dashboard (10254) + AES-256-GCM vault.
- **Scoped access-токен на агента** (`Proxy-Authorization`) — секреты пользователя недоступны другим.
- **Привязки** (placeholder → секрет, host+path+метод), default-deny на незнакомый хост:

```yaml
secrets:
  TELEGRAM_BOT_TOKEN: { placeholder: "FAKE-tg-0001", inject: {query: "token"}, bindings: [{host: "api.telegram.org"}] }
  COMPOSIO_KEY:       { placeholder: "FAKE-composio", inject: {header: "x-api-key"}, bindings: [{host: "backend.composio.dev"}] }
  EXA_KEY:            { placeholder: "FAKE-exa", inject: {query: "exaApiKey"}, bindings: [{host: "mcp.exa.ai"}] }
```

- **Платформенные секреты** (bot-токены, Composio/Exa, доступ к LiteLLM) отделены от пользовательских.
- Использование ключа → запись в аудит (`agent_id`, `ts`, `host`).

## Интеграция в провижининг
`provisioner` при создании тенанта: OS-учётка → netns + nftables → scaffold `.claude/` (locked-слой) → virtual key LiteLLM → scoped onecli-токен + привязки → запись в Postgres (`containers`, `secret_bindings`) → enable `claude-pod@<user>`.

## Критерии приёмки (M2)
- Образ собирается; контейнер стартует под rootless Podman с cgroups-лимитами.
- Egress default-deny: контейнер достаёт модель **только** через LiteLLM (или fallback-прокси из спайка S1), внешние API — **только** через OneCLI/белый список; прямой интернет закрыт.
- OneCLI подменяет заполнители по host/path; попытка «выгрузить env» отдаёт только FAKE-значения.
- LiteLLM (или fallback-прокси) ведёт per-user usage; деградация вместо падения при лимите.
- Всё это — на **тестовом** тенанте, без влияния на старый стек.
