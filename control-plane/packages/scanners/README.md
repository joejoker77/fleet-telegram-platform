# @fleet/scanners (M4 / WP4)

The **L4/L5/L6 artifact gate** (docs 09-security-stack.md). One entry point,
`scanArtifact()`, plus the `fleet-scan` CLI any install/authoring path can call.

## Two-stage gate

1. **Deterministic** (free, local, no LLM):
   - built-in rules (`deterministic.ts`) — credential/exfil, curl|bash, eval/exec,
     reverse-shell, hook-injection, prompt-injection. This is L6 AgentShield's fast path.
   - Cisco YARA scanners (`external.ts`) when installed — `mcp-scanner` (L4),
     `skill-scanner` (L5). **Degrades gracefully**: absent binaries → `null`, the
     gate falls back to built-ins + the judge. No hard dependency.
   - A **CRITICAL** finding fails fast → **no LLM call**.
2. **Judge** (`@fleet/judge-orchestrator`, the single LLM-as-judge): everything
   non-critical is adjudicated with the artifact + the deterministic findings as
   context. **Fail-closed** — a judge error/timeout → `verdict=error` → block.

`mcp` → L4, `skill` → L5, `agentshield` (.claude change) → L6, `plugin` → all three
(worst verdict wins). Every scan emits a `scan.result` audit event.

## CLI

```
tsx packages/scanners/src/cli.ts <mcp|skill|agentshield|plugin> <path> [actor]
# env: JUDGE_URL (default http://127.0.0.1:8090), AUDIT_SOCKET
# exit: 0 pass · 2 fail (block) · 3 error (fail-closed, block)
```

## Verify

- `pnpm --filter @fleet/scanners smoke` — offline logic proof (critical→fail-fast
  no-LLM, clean→judge→pass, medium→routed-to-judge, judge-error→fail-closed,
  audit emitted). **8/8 green.**
- `install/m4.2-scanners.sh` (root) — pnpm install → smoke → live integration vs
  cp-judge (obvious malware blocked deterministically; subtly-bad blocked by judge;
  clean passes).

## Not yet wired

`scanArtifact`/`fleet-scan` is a ready library + CLI. Binding it to the actual
trigger points (MCP install, skill install, .claude change, M5 authoring
save/publish/import) is the next WP4 step — operator picks the first surface.
