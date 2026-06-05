#!/usr/bin/env python3
"""Self-test for block-nested-claude.py. Run: python3 test_guard.py"""
import json
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "block-nested-claude.py")

# (command, should_block)
CASES = [
    # --- must BLOCK (would boot a 2nd plugin / evict poller) ---
    ("claude -p 'hello'", True),
    ("claude mcp list", True),                       # the 2026-06-03 killer
    ("claude plugin list", True),
    ("claude doctor", True),
    ("claude config get", True),
    ("cd /tmp && claude -p 'x'", True),
    ("echo hi && claude", True),
    ("bash -c 'claude mcp list'", True),
    ("timeout 30 claude -p 'x'", True),
    # --- must ALLOW ---
    ("claude-sub -p 'do work'", False),              # our wrapper
    ("claude --strict-mcp-config --mcp-config empty-mcp.json mcp list", False),
    ("claude --bare -p 'x'", False),
    ("claude --version", False),
    ("claude update", False),
    ("claude setup-token", False),
    ("systemctl restart claude-tg@vitaliy", False),
    ("session-search 'claude plugin'", False),
    ("ls ~/.claude/ && grep claude file", False),
    ("git commit -m 'claude mcp notes'", False),
]


def blocks(cmd):
    payload = {"tool_name": "Bash", "tool_input": {"command": cmd}}
    r = subprocess.run([sys.executable, GUARD], input=json.dumps(payload),
                       capture_output=True, text=True)
    return r.returncode == 2


def main():
    bad = 0
    for cmd, want in CASES:
        got = blocks(cmd)
        tag = "OK " if got == want else "FAIL"
        if got != want:
            bad += 1
        print(f"  [{tag}] block={got!s:5} want={want!s:5}  {cmd}")
    print(f"\n{'ALL PASS' if bad == 0 else str(bad) + ' FAILED'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
