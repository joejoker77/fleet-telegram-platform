# fleet-platform

Single-directory, portable deliverable for the Claude bot fleet: everything
needed to deploy the platform on a fresh server lives in this one repo
(`git clone` + `install.sh`). Migrating the existing server is just one
deployment mode of this same artifact.

> Status: **bootstrapping**. First module landed is `stabilization/` (M0 — hotfixes
> for the live stack). The rest of the tree fills in per milestone (see
> `docs/06-build-overview.md`, milestones M0–M10).

## Layout (intended)

```
install/         bootstrap: install.sh, preflight.sh, uninstall.sh   (later)
config/          platform.yaml schema + example (NO secrets)         (later)
control-plane/   monorepo apps/packages (api, provisioner, registry…) (M1)
runtime/         Containerfile, entrypoint, locked hooks, settings    (M2)
gateways/        litellm/, onecli/ configs + units                    (M2)
systemd/         claude-pod@.service, cp-*.service, timers            (M2)
network/         nftables egress templates                           (M2)
db/              drizzle migrations                                   (M1)
migrate/         existing-server per-user cutover tooling             (M3+)
stabilization/   M0 hotfixes for the LIVE claude-tg@ stack  <-- here now
docs/            the design docs (00–13)
```

## Principles (agreed 2026-06-05)
- **One repo = the deliverable.** Repo layout (source) ≠ deployed layout
  (`/opt/control-plane`, `/opt/runtime`, … created by the installer).
- **Config-driven; secrets never in the repo** — loaded into OneCLI at install
  time. Supports both 1-tenant and N-tenant via config.
- **Capture-as-you-go.** Every config/script/unit built during the in-place
  upgrade is committed here, so the final install package is "assemble + clean
  up", not "reverse-engineer the prod server".
- **One clean `install.sh` dry-run on a throwaway target** is the gate before
  mass rollout.

See `docs/` for the full design.
