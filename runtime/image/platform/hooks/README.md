# Locked platform hooks (read-only in the image)

Placeholder for M2.1. The real PreToolUse/PostToolUse hooks are populated at
**M4 (security stack)** and baked in read-only:

- `block-nested-claude.py` (the M0 nested-claude guard, carried into the image)
- shellfirm wrapper wiring
- audit PostToolUse hook (feeds usage/events to the audit-collector socket — see
  M2.5 metering, ADR-001: event-driven, no recurring LLM calls)

Tenants cannot edit these; they live under `/opt/platform/` and are merged ahead
of the tenant's own `~/.claude/settings.json`.
