# iCloud for tenants — design (pod era)

Vitaliy 2026-06-17: iCloud isn't only viveanne's — Dmitrii has it too and wants the capability
**available to all** users. Decide how to organize it: an admin-only skill, self-service, or
nothing. This design also fixes a **live gap** found while investigating.

## Current state (verified live 2026-06-17, mechanism only — no contents/creds read)
- Only two active iCloud mounts, both **static host units**: `rclone-dmrudenko-mount.service`
  ("platform operator"), `rclone-viveanne-mount.service` ("her home"). The newer self-service
  template `rclone-icloud-mount@.service` exists but is **disabled/unused**.
- Mechanism (host runtime era): rclone `iclouddrive` backend → FUSE mount at `/home/<user>/icloud`
  on the HOST (systemd, `User=root`, `--allow-other`, `--uid/--gid <user>`, vfs-cache writes).
  Creds live in `/home/<user>/rclone.conf` (mode 600; trust_token after Apple ID + 2FA). Tooling:
  `setup-icloud-rclone` (bot user runs `rclone config`) + `sudo enable-icloud-mount` (sudoers
  wrapper, scoped to caller's own instance; refuses if a static unit exists).
- So "Dmitrii connected differently?" → **yes**: dmrudenko is on a dedicated **static** unit, not
  the template (same as viveanne).

## THE GAP (important, live now)
`claude-pod-run` bind-mounts `~/.claude, ~/work, ~/.config, ~/.local, ~/.ssh, .claude.json` — **NOT
`~/icloud`**. A pod has its own mount namespace, so the host FUSE mount is invisible inside it.
**dmrudenko is already migrated to the pod → he currently has NO in-pod iCloud access** (his host
mount is live, but his bot can't see it). This is the same reason viveanne's migration was deferred
— it's a general pod-runtime gap, not viveanne-specific.

## Technical approach (independent of the UX choice)
**Keep rclone on the HOST; propagate the mount into the pod.** Running rclone/FUSE *inside* the
pod would need `/dev/fuse` + `SYS_ADMIN` (or unprivileged FUSE), breaking the pod hardening
(`--cap-drop=ALL`, `--read-only`, `no-new-privileges`) — rejected.

- The host mount already uses `--allow-other`, so a container uid can read it.
- `claude-pod-run`: if `/home/<user>/icloud` is a mountpoint, add
  `-v /home/<user>/icloud:/home/<user>/icloud:rslave`. **`:rslave` (or `:rshared`) is required** —
  podman's default `rprivate` would NOT show the FUSE submount; rslave makes the pod see the live
  mount (and survive rclone restarts). Ensure the rclone unit starts before / independently of the
  pod (rslave picks the mount up whenever it appears).
- **Creds stay host-only**: the pod sees the mounted *data*, never `rclone.conf`. Consistent with
  the no-plaintext-secrets-in-pod canon (the secret never enters the container). OneCLI storage of
  the trust_token is a possible future hardening, not required.

This makes the rclone mount a **justified host-bootstrap** per the product canon (per-user data
infra, templated `rclone-icloud-mount@<user>`, install.sh-managed) — NOT ad-hoc host sprawl.

## Provisioning UX — the decision
Provisioning touches the HOST (rclone config + enable systemd mount + ensure pod bind + pod
restart) and handles the user's **full Apple ID password + 2FA**. A hardened tenant pod cannot do
host ops, and `no-new-privileges` blocks the old in-pod sudo-wrapper path.

| Option | What it is | Verdict |
|---|---|---|
| **A. Admin-only skill (RECOMMEND)** | An admin (vitaliy/dmrudenko, who hold the host-sudo broker) runs a skill: collect the target user's Apple ID + **regular** password + 2FA via Telegram → host rclone config for that user → enable the templated mount → ensure the pod bind → graceful pod restart (the A1 command). "Available to all" = any user can REQUEST; an admin provisions. | Fits the admin tier + pod security (privileged host step stays with admins) + the canon (no per-tenant host-mount surface). Reuses existing tooling (adapt `setup-icloud-rclone`/`enable-icloud-mount`). |
| B. Self-service by the tenant | Re-expose host-mount creation to every tenant pod (scoped sudoers wrapper + drive interactive `rclone config` from inside the hardened pod + self-trigger a pod restart). | NOT recommended: enlarges host surface for every tenant, fights the hardened-pod model + "minimize host scripts" canon; `no-new-privileges` blocks the sudo path in-pod anyway. |
| C. Nothing | Drop the capability. | No — Dmitrii + viveanne genuinely use Mac-file access. Keep it, but **opt-in / on request**, never default (privacy + the cross-bot off-limits rules). |

**Recommendation: A (admin-only provisioning skill) + the `claude-pod-run` rslave-bind fix.**
"Available to all" is satisfied (anyone can have it set up); the credential-handling, host-touching
step stays with admins. The pod-bind fix is needed regardless and also restores dmrudenko's iCloud.

## Work items if A is chosen
1. `claude-pod-run`: conditional `:rslave` bind of `~/icloud` when it's a mountpoint (+ ensure
   ordering vs the rclone unit). Pilot on dmrudenko (restores his access) — validates the whole path.
2. Admin skill `icloud-connect <user>` (in the skills repo, admin-whitelisted): Telegram-driven
   Apple ID + **regular password** + 2FA → host rclone config → enable templated mount → graceful
   pod restart. Fix the stale "app-specific password" wording from `setup-icloud-rclone`.
3. Productize: templated `rclone-icloud-mount@<user>` + tooling installed by `install.sh`
   (justified bootstrap); retire the per-user static units (dmrudenko/viveanne) onto the template.
4. Keep the cross-bot off-limits rule (each user's `~/icloud` is private to that bot) — append to
   other tenants' CLAUDE.md as today.

## REFINED DESIGN — credential-split (Vitaliy 2026-06-17)
Vitaliy's privacy objection (correct): an admin must NOT see/handle a user's Apple ID + password
+ 2FA — that contradicts the app's confidentiality promise. The privileged HOST work and the
CREDENTIAL entry are **split**:

- **Plumbing step (no creds, privileged):** create `~/icloud`, install the (dormant) rclone mount
  unit, ensure the `:rslave` propagation (already global in claude-pod-run). Can be run by an admin
  on request **OR baked into `provision-tenant.sh` for everyone** (recommended — then NO admin
  action is needed per user; the scaffolding sits dormant until the user authenticates). No creds
  ever touched here.
- **Auth step (creds, USER-self-service):** the user's OWN bot skill collects Apple ID + password
  + 2FA **in the user's own chat** — the admin never sees them.

Technical reality that shapes WHERE auth runs (verified 2026-06-17): rclone is **not** in the pod
image; the pod's egress is proxy-locked (rclone→Apple uncertain in-pod); and the mount must stay
host-side (FUSE-in-pod breaks hardening). So the rclone Apple-auth runs **host-side via a small
socket auth-helper** (the cp-secretd pattern): the user's bot streams the creds + relays the 2FA
prompt over a local socket to the helper, which runs as root on the host (where rclone + Apple
network + the mount live), authenticates, and **stores the secret in OneCLI** (vault storage — the
persistent secret is rclone's `trust_token`; the password isn't persisted after first auth). At
mount time a host step materializes a transient config from OneCLI (tmpfs), so no plaintext
credential persists. The helper starts the mount → it propagates into the pod via the `:rslave`
bind (done). **The admin-human never sees the creds (user→bot→host-helper→OneCLI); the bot process
never persists them.** Note: OneCLI here is the secret STORE (not the HTTP-proxy injector — rclone's
SRP auth isn't a header injection), which is a valid vault use.

The one NEW host component (the auth-helper) is a **justified bootstrap** — same reasoning as
cp-secretd: the credential handling MUST be host-side given rclone/network/mount are host-side, and
this is exactly what keeps the admin OUT of the user's credentials. Not ad-hoc sprawl.

Alternative considered & rejected: put rclone in every pod image + open egress to Apple for all
pods + still write a host-readable config — more attack surface, doesn't avoid the host mount.

### Revised work items
1. `claude-pod-run` `:rslave` propagation — ✅ DONE 2026-06-17 (commit c173caa; dmrudenko restored).
2. **Plumbing**: bake dormant iCloud scaffolding into `provision-tenant.sh` (recommended) or an
   admin `icloud-prepare <user>` — no creds.
3. **Auth-helper** (host, socket-activated, cp-secretd pattern): receives user creds from the bot,
   runs rclone Apple-auth + 2FA relay, stores trust_token in OneCLI, materializes transient config
   at mount, starts the mount.
4. **User skill** `icloud-connect` (in the bot): collect Apple ID + password + 2FA in the user's
   chat, stream to the auth-helper, relay 2FA, report success. Fix the stale "app-specific" wording.
5. Productize: templated `rclone-icloud-mount@` + helper into `install.sh`; retire static units.

Sub-choice — DECIDED 2026-06-17 (Vitaliy): **bake plumbing into provisioning for all, by default.**
Every tenant gets the dormant iCloud scaffolding at provision time; no admin step per user; the
user activates it themselves via the auth skill whenever they want. Work item 2 → `provision-tenant.sh`.

## (superseded) earlier DECISION — A confirmed (Vitaliy 2026-06-17)
**Variant A (admin-only provisioning skill).** Also: this must be **documented into the rollout
plan BEFORE migrating all users to pods** (Vitaliy) — because any user who has/wants iCloud must
not lose Mac-file access at cutover (dmrudenko already did). Integrated into `docs/08` (Block A
work item), `docs/09` (per-bot runbook step), and `docs/11` (rclone mount = justified bootstrap +
the admin skill). Start with the `claude-pod-run` `:rslave` propagation fix — required for any
in-pod iCloud and it restores dmrudenko now.
