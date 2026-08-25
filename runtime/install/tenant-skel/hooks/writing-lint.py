#!/usr/bin/env python3
"""writing-lint.py — PreToolUse hook: check outgoing text against the firm's
writing rules before it is sent.

Enforces only the CHECKABLE half of the rules (the lexical ones). Register,
deference and padding are judgement calls and stay in CLAUDE.md where they
belong — a regex cannot see them, and pretending otherwise would just add noise.

  * banned words and phrases
  * banned constructions ("it's not just X, it's Y", sentence-initial
    Furthermore/Moreover/Additionally, "it's important to note that")
  * at most one em dash per message

No LLM call, no network: pure regex on stdin. Deterministic and free.

Contract (docs: code.claude.com/docs/en/hooks):
  stdin  = {"tool_name": ..., "tool_input": {...}}
  stdout = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
            "permissionDecision": "deny", "permissionDecisionReason": "..."}}
  exit 0 with no output = no opinion, normal flow continues.

Safety valve: the same text is blocked at most MAX_BLOCKS times. If the model
cannot satisfy the linter after that, the message goes out rather than the
conversation deadlocking. A bot silently stuck in a rewrite loop is worse than
one em dash.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

STATE = Path(os.path.expanduser("~/.claude/channels")) / ".writing-lint-state.json"
MAX_BLOCKS = 2
STATE_TTL = 3600

BANNED_WORDS = [
    "delve", "leverage", "robust", "seamless", "elevate", "unlock", "harness",
    "tapestry", "vibrant", "pivotal", "foster", "testament", "underscore",
    "meticulous", "holistic", "synergy", "game-changer", "cutting-edge",
    "transformative",
]
BANNED_PHRASES = [
    "navigate the landscape", "in the realm of", "embark on a journey",
    "it's important to note that", "it is important to note that",
    "in today's fast-moving", "in today's fast moving",
]
# "it's not just X, it's Y" and its variants.
NOT_JUST_RE = re.compile(r"\b(it'?s|this is|that'?s)\s+not\s+just\b.{0,60}?\bit'?s\b", re.I)
OPENER_RE = re.compile(r"(?:^|(?<=[.!?]\s))\s*(Furthermore|Moreover|Additionally)\b", re.M)
EM_DASH = "—"
EM_DASH_LIMIT = 1

# Telegram markup and code should not be linted: a banned word inside a code
# block or a URL is not prose. Strip those first.
STRIP_RE = [
    re.compile(r"<pre>.*?</pre>", re.S | re.I),
    re.compile(r"<code>.*?</code>", re.S | re.I),
    re.compile(r"```.*?```", re.S),
    re.compile(r"`[^`]*`"),
    re.compile(r"https?://\S+"),
    re.compile(r"<[^>]+>"),
]


def text_of(tool_input: dict) -> str:
    for k in ("text", "message", "content", "body"):
        v = tool_input.get(k)
        if isinstance(v, str) and v.strip():
            return v
    return ""


def is_cyrillic(s: str) -> bool:
    """Russian text: the em-dash rule is an English-typography rule and would
    mangle it, and the word list cannot match anyway."""
    letters = [c for c in s if c.isalpha()]
    if not letters:
        return False
    cyr = sum(1 for c in letters if "Ѐ" <= c <= "ӿ")
    return cyr / len(letters) > 0.2


def strip_markup(s: str) -> str:
    for rx in STRIP_RE:
        s = rx.sub(" ", s)
    return s


def findings(prose: str, russian: bool) -> list[str]:
    out: list[str] = []
    low = prose.lower()

    hits = sorted({w for w in BANNED_WORDS if re.search(rf"\b{re.escape(w)}\b", low)})
    if hits:
        out.append("banned words: " + ", ".join(hits))

    ph = sorted({p for p in BANNED_PHRASES if p in low})
    if ph:
        out.append("banned phrases: " + "; ".join(f'"{p}"' for p in ph))

    if NOT_JUST_RE.search(prose):
        out.append('the "it\'s not just X, it\'s Y" construction')

    op = OPENER_RE.findall(prose)
    if op:
        out.append("sentence opening with " + ", ".join(sorted(set(w for w in op))))

    if not russian:
        n = prose.count(EM_DASH)
        if n > EM_DASH_LIMIT:
            out.append(f"{n} em dashes (limit {EM_DASH_LIMIT}); a full stop, comma or colon does the same work")

    return out


def block_count(key: str) -> int:
    try:
        data = json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        data = {}
    now = time.time()
    data = {k: v for k, v in data.items() if now - v.get("ts", 0) < STATE_TTL}
    entry = data.get(key, {"n": 0})
    entry["n"] = int(entry.get("n", 0)) + 1
    entry["ts"] = now
    data[key] = entry
    try:
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(data))
    except OSError:
        pass
    return entry["n"]


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # never break the tool call over a parsing problem

    raw = text_of(payload.get("tool_input") or {})
    if not raw.strip():
        return 0

    prose = strip_markup(raw)
    problems = findings(prose, is_cyrillic(prose))
    if not problems:
        return 0

    key = hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest()[:16]
    if block_count(key) > MAX_BLOCKS:
        return 0  # let it through rather than deadlock

    reason = ("Writing rules: rewrite before sending. "
              + "; ".join(problems)
              + ". Keep the meaning and the length; change only the wording.")
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
