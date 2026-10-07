# skill-autoshare — the catalogue fills itself

On 2026-10-07 there were 101 different skills across 35 workspaces and 8 of them in the
firm catalogue. Six skills had been copied between homes by hand, so the author's later
fixes never reached the people running them. Sharing was something a person had to
remember to do, and almost nobody did.

This publishes every tenant's new or changed skill by itself, hourly.

| Piece | Where | What it does |
|---|---|---|
| Publisher | `/opt/skill-autoshare/autoshare.py` (repo `runtime/skill-autoshare/`) | Walks every tenant's `~/work/.claude/skills`, publishes what changed, through that tenant's own `share-skill` inside their pod. |
| Timer | `skill-autoshare.timer` | Hourly, 5 min jitter, catches up after a reboot. |
| State | `/var/lib/skill-autoshare/state.json` | Content hash + last version per skill, so nothing is published twice. |
| Report | `/var/log/skill-autoshare/last-run.json` | What was published, held back, or skipped. |

## The rules it follows

**It publishes; it never installs.** Distribution to colleagues stays a separate
decision: a skill that lands on 35 machines takes effect on their next message and
cannot be recalled from the people who already have it.

**Public by default, private when it is one person's own.** Dmitrii's rule: everything
reaches the catalogue, and what should not spread is listed but not offered. A skill is
published private when the folder has a `.noshare` file, when SKILL.md says
`share: false` or `visibility: private`, when the name or the description carries the
owner's own name, or when it reads as somebody's voice or standing rules. The owner can
publish it public by hand at any time.

**It holds back anything that looks like client data** — an outside email address, a UK
postcode, a National Insurance number, a phone number, a deal id in a URL — and names the
file and line instead of publishing. It does not try to de-identify a playbook; that is
not a machine's call. Expect false alarms on the firm's own letterhead details.

**Skills that came from the catalogue are skipped**, so an install is never republished
under the wrong name.

## Running it

```
/opt/skill-autoshare/autoshare.py                 what it would do (changes nothing)
/opt/skill-autoshare/autoshare.py --apply         publish
/opt/skill-autoshare/autoshare.py --user <name>   one person
/opt/skill-autoshare/autoshare.py --status        what the catalogue holds
./install.sh            install + enable the timer
./install.sh --rollback stop and remove it (state is kept)
```

A newly published skill is listed immediately; a colleague still installs it with
`share-skill get <name>`.
