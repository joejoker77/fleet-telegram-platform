#!/usr/bin/env python3
"""PreToolUse hook: block any Bash command that starts a *plain* `claude`
session (which would boot a second telegram plugin and evict the parent bot's
poll lock).

Policy
------
BLOCK a Bash command iff it invokes the `claude` binary WITHOUT an isolation
flag (`--bare` or `--strict-mcp-config`).

ALLOW everything else, specifically:
  - `claude-sub ...`            (our wrapper; basename != "claude")
  - `claude --bare ...`         (skips all plugins -> no telegram)
  - `claude --strict-mcp-config --mcp-config X ...`  (only listed MCP servers)
  - `claude update|install|setup-token|--help|--version ...` (no MCP load)
  - `systemctl restart claude-tg@...`   (program is systemctl, not claude)
  - any `.claude/` path, `claude-tg`, `claude-bot-skills`, `session-search`, etc.

M0 fix (2026-06-05): `mcp`, `plugin(s)`, `config`, `doctor`, `agents` were
REMOVED from the safe list. They load the project MCP configuration (which
includes the telegram plugin) to probe/list it, which boots a second plugin
instance and SIGTERMs the parent poller — proven on 2026-06-03 when
`claude mcp list` silently killed this bot's channel. To run any of those
safely, isolate them: `claude --strict-mcp-config --mcp-config empty-mcp.json mcp list`.

Contract: exit 0 = allow, exit 2 = block (stderr is shown back to Claude).
"""
import json
import os
import re
import shlex
import sys

# Subcommands / flags that neither start a chat session NOR load project MCP
# servers, so they cannot boot the telegram plugin even without isolation.
# Deliberately conservative: when unsure, leave it OUT (the cost of a false
# block is a retry via claude-sub; the cost of a false allow is a dead bot).
SAFE_FIRST_ARG = {
    "update", "install", "migrate-installer", "setup-token", "help",
    "--help", "-h", "--version", "-v",
}
ISOLATION_FLAGS = {"--bare", "--strict-mcp-config"}

# Split a compound command into individual simple-command segments on the shell
# operators that begin a new command. Good enough for our (non-adversarial) use.
SEGMENT_SPLIT = re.compile(r"&&|\|\||[;&|\n()]|\$\(|`")


def segments(command: str):
    for seg in SEGMENT_SPLIT.split(command):
        seg = seg.strip()
        if seg:
            yield seg


DURATION_RE = re.compile(r"^[0-9]+(\.[0-9]+)?[smhd]?$")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def tokenize(seg: str):
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        # Unbalanced quote because we split mid-string; fall back to naive split.
        return seg.split()


def strip_wrappers(toks):
    """Drop leading env-assignments and exec/timeout/nohup/sudo-style wrappers so
    the real program token is exposed. Returns the remaining token list."""
    i = 0
    while i < len(toks):
        t = toks[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):          # FOO=bar
            i += 1
            continue
        base = os.path.basename(t)
        if base in ("env", "command", "exec", "nohup", "time", "sudo", "stdbuf",
                    "doas", "ionice", "nice", "setsid"):
            i += 1
            continue
        if base == "timeout":                                  # timeout [opts] DUR cmd
            i += 1
            seen_duration = False
            while i < len(toks):
                t = toks[i]
                if t.startswith("-"):                          # option
                    if t in ("-s", "-k", "--signal", "--kill-after"):
                        i += 1                                 # consumes a value
                    i += 1
                    continue
                if not seen_duration and DURATION_RE.match(t):
                    seen_duration = True
                    i += 1
                    continue
                break
            continue
        break
    return toks[i:]


def scan_tokens(toks):
    """Return a reason string if these tokens start a plain claude session."""
    toks = strip_wrappers(toks)
    if not toks:
        return None
    prog = os.path.basename(toks[0])
    args = toks[1:]

    # Recurse into `bash -c "<payload>"` / `sh -c '<payload>'`.
    if prog in SHELLS:
        for j, a in enumerate(args):
            if a == "-c" and j + 1 < len(args):
                r = is_dangerous(args[j + 1])
                if r:
                    return r
        return None

    if prog != "claude":            # excludes claude-sub, claude-tg, paths, etc.
        return None
    first = args[0] if args else None
    if first in SAFE_FIRST_ARG:     # update/setup-token/--help/... -> no MCP load
        return None
    if any(a in ISOLATION_FLAGS for a in args):  # --bare / --strict-mcp-config
        return None
    return ("Blocked: `claude` would start a session (or probe MCP servers) that "
            "loads the telegram plugin and kill the parent bot's poll lock. Use "
            "`claude-sub` for an isolated nested session, or add `--bare` / "
            "`--strict-mcp-config --mcp-config <file>`.")


def is_dangerous(command: str):
    """Return a reason string if the command starts a plain claude session, else None."""
    for seg in segments(command):
        reason = scan_tokens(tokenize(seg))
        if reason:
            return reason + "\n  offending command: " + command.strip()
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # malformed -> don't get in the way
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    command = (payload.get("tool_input") or {}).get("command", "")
    if not command:
        sys.exit(0)
    reason = is_dangerous(command)
    if reason:
        sys.stderr.write(reason + "\n")
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
