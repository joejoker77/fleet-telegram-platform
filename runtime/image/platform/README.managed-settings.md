# `managed-settings.json` — the locked platform settings layer (M4 #3)

This file is baked **read-only** into the runtime image at the OS managed path
`/etc/claude-code/managed-settings.json` (see `Containerfile`). It is Claude
Code's **highest-precedence** settings source: it is NOT overridable by the
tenant's writable `~/.claude/settings.json`, and `/etc` is a read-only image
layer in the pod, so uid 1005 (the bot) cannot tamper with it.

It holds the un-removable security config:

- the security hooks — shellfirm dangerous-command guard
  (`/usr/local/bin/shellfirm-bot-wrapper`) and the block-nested-claude
  poll-lock guard (`/usr/local/share/claude-guard/block-nested-claude.py`);
- the `permissions.deny` rules (deny always wins and cannot be allowed back);
- the per-turn metering `Stop` hook (`/opt/platform/hooks/metering-stop-hook.mjs`).

Hooks here **merge additively** with the tenant layer. The tenant's per-user
operational hooks (telegram track-chat / block-askuser, whose paths live under
`/home/<user>`) intentionally stay tenant-side. `allowManagedHooksOnly` is
intentionally NOT set: the security guarantee comes from presence in this
un-removable layer plus deny-always-wins, without caging the authoring agent's
own hooks. All paths used here are image-portable (`/usr/local`, `/opt/platform`)
so a fresh server reproduces this verbatim.

## ⚠️ Why this rationale lives in a README, not a `_comment` key

The JSON file deliberately carries **no `_comment` key** (or any other key
outside Claude Code's settings schema).

On Claude Code **2.1.169** (the pinned fleet version), the **managed-settings
validator is stricter than the regular `settings.json` parser**: a single
entry it considers invalid/unrecognized causes the **entire managed file to be
silently dropped** — no error to the running session, no enforcement. The
regular parser tolerates an extra `_comment`; the managed validator at this
version does not, and (pre-resilience-fix) it voids the whole policy instead of
dropping just the bad key.

We hit exactly this on 2026-06-09: the file was baked correctly (RO, root:root,
valid JSON, deny+hooks inside) yet **none** of its policy was enforced —
WebFetch ran, `rm -rf` ran, no PreToolUse hook fired — leaving the bot *less*
protected than before, because the dedup had already moved the deny rules and
Bash guards out of the tenant file into this inert layer.

**Rule:** keep this file strictly to Claude Code's settings schema
(`permissions`, `hooks`, …). Put all human-facing documentation here in this
README, never in the JSON. The build (`Containerfile`) and the apply script
(`runtime/install/m4.3-apply-managed-settings.sh`) verify *acceptance* (via
`claude doctor`), not merely JSON validity — because valid JSON that the
managed validator rejects is the exact silent-failure mode above.

See memory `feedback_managed_settings_not_enforced_2_1_169` for the full
incident.
