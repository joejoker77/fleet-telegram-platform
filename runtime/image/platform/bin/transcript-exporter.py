#!/usr/bin/env python3
"""transcript-exporter — turn Claude Code's own .jsonl transcripts into readable,
per-session text archives that `session-search` can index.

Why this exists
---------------
On this platform nothing writes `session_current.txt`: the baked telegram plugin
is the clean official one, and only the fleet's patched build had the logging
hook.  `session_indexer.py` globs `session_*.txt`, finds nothing, and the FTS
index stays empty — search has never worked for most tenants.

The transcripts Claude Code writes itself are a better source anyway:

  * one file per session already (`<uuid>.jsonl`), with `sessionId` + timestamps;
  * they cover EVERY kind of session — Telegram, project sessions, subagents and
    sessions started from the Claude App over remote control, which never reach
    the tmux pane dump at all;
  * they are structured, so we can drop tool noise instead of indexing ANSI soup.

This exporter renders each transcript into
`~/.claude/channels/telegram-<user>/logs/sessions/session_<utc>_<uuid8>.txt`
and the indexer picks it up from there.

Two deliberate design choices
-----------------------------
1. Output goes to a `sessions/` SUBDIRECTORY, not next to `session_current.txt`.
   The entrypoint's session-restore block does `ls -t .../session_*.txt | head -1`
   and pastes the tail into a fresh session.  Writing our archives where it looks
   would silently revive a dormant feature and could seed a Telegram session with
   a Claude App conversation.  A subdirectory keeps the two concerns apart.
2. Append-only.  `session_indexer.py` tracks (mtime, size) and seeks to the
   previous size, so appending is cheap and never re-indexes.  We never rewrite a
   line we have already written.
3. `===== <ts> =====` marker lines every hour.  That is the ONLY thing the
   indexer recognises as a timestamp (it sets `current_ts` from such lines), so
   without them every hit would show `ts=(no ts)` and `session-search --since`
   would silently match nothing in our archives.

Usage:
    transcript-exporter.py [--once] [--dry-run] [--verbose]
                           [--home DIR] [--max-chars N]

Exit status is 0 unless the state file could not be written.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# A tool result or a pasted file can be megabytes.  Full text lives in the .jsonl;
# the archive keeps enough to be searchable and readable.
DEFAULT_MAX_CHARS = 2000
STATE_NAME = ".export_state.json"

# Anything that is bulk binary rather than conversation.
B64_RE = re.compile(r"^[A-Za-z0-9+/=\s]{512,}$")
DATA_URI_RE = re.compile(r"data:[a-z]+/[a-z0-9.+-]+;base64,[A-Za-z0-9+/=]+", re.I)


def log_dir_for(home: Path) -> Path:
    user = home.name
    return home / ".claude" / "channels" / f"telegram-{user}" / "logs"


def squeeze(text: str, max_chars: int) -> str:
    """Collapse a value to one searchable blob: no base64, no giant blocks."""
    if not text:
        return ""
    text = DATA_URI_RE.sub("<inline-binary>", text)
    if B64_RE.match(text):
        return f"<binary blob, {len(text)} chars>"
    text = text.replace("\r", "")
    if len(text) > max_chars:
        text = text[:max_chars] + f"… <truncated, {len(text)} chars total>"
    return text.strip()


def render_content(content, max_chars: int) -> list[str]:
    """Claude Code stores content as a string or a list of typed blocks."""
    out: list[str] = []
    if content is None:
        return out
    if isinstance(content, str):
        s = squeeze(content, max_chars)
        if s:
            out.append(s)
        return out
    if isinstance(content, dict):
        content = [content]
    if not isinstance(content, list):
        out.append(squeeze(str(content), max_chars))
        return out

    for block in content:
        if isinstance(block, str):
            s = squeeze(block, max_chars)
            if s:
                out.append(s)
            continue
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            s = squeeze(block.get("text", ""), max_chars)
            if s:
                out.append(s)
        elif btype == "thinking":
            # Reasoning is not conversation; keep a marker so the gap is visible.
            out.append("<thinking omitted>")
        elif btype == "tool_use":
            name = block.get("name", "?")
            args = block.get("input", {})
            try:
                arg_s = json.dumps(args, ensure_ascii=False)
            except (TypeError, ValueError):
                arg_s = str(args)
            out.append(f"TOOL {name}({squeeze(arg_s, max_chars)})")
        elif btype == "tool_result":
            body = block.get("content")
            rendered = render_content(body, max_chars) if not isinstance(body, str) \
                else [squeeze(body, max_chars)]
            joined = " ".join(x for x in rendered if x)
            out.append(f"RESULT {joined}" if joined else "RESULT <empty>")
        elif btype in ("image", "document"):
            out.append(f"<{btype} attachment>")
    return out


def render_record(rec: dict, max_chars: int) -> str | None:
    """One transcript record -> one archive line, or None to skip it."""
    rtype = rec.get("type")
    ts = rec.get("timestamp", "")
    if ts:
        ts = ts.replace("T", " ").replace("Z", "")[:19]

    if rtype in ("user", "assistant", "system"):
        msg = rec.get("message") or rec.get("content")
        if isinstance(msg, dict):
            body = render_content(msg.get("content"), max_chars)
        else:
            body = render_content(msg, max_chars)
        if not body:
            return None
        return f"[{ts}] {rtype.upper()}: " + " | ".join(body)

    if rtype == "attachment":
        # Never inline the payload; record that something was attached.
        c = rec.get("content")
        name = ""
        if isinstance(c, dict):
            name = c.get("filename") or c.get("name") or c.get("type") or ""
        return f"[{ts}] ATTACHMENT: {squeeze(str(name), 200)}".rstrip()

    if rtype in ("summary", "ai-title"):
        c = rec.get("content") or rec.get("summary") or ""
        s = squeeze(c if isinstance(c, str) else json.dumps(c, ensure_ascii=False), 500)
        return f"[{ts}] TITLE: {s}" if s else None

    # queue-operation, last-prompt, file-history-snapshot, … — bookkeeping.
    return None


def session_started(path: Path) -> str:
    """UTC stamp of the first timestamped record; falls back to file mtime."""
    try:
        with path.open("r", errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = rec.get("timestamp")
                if ts:
                    try:
                        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                        return dt.astimezone(timezone.utc).strftime("%Y%m%d_%H%M%S")
                    except ValueError:
                        pass
    except OSError:
        pass
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime("%Y%m%d_%H%M%S")


def archive_name(src: Path, projects: Path) -> str:
    """Name every archive so a search hit is attributable.

      <project>/<uuid>.jsonl                                -> session_<utc>_<uuid8>.txt
      <project>/<session>/subagents/agent-<id>.jsonl        -> session_<utc>_<sess8>_agent_<id8>.txt
      <project>/<session>/subagents/workflows/wf_<w>/…jsonl -> session_<utc>_<sess8>_wf<w6>_agent_<id8>.txt

    Workflow runs put dozens of agents under one session, so the workflow id has
    to be part of the name or two agents from different runs could collide.
    """
    stamp = session_started(src)
    try:
        parts = src.relative_to(projects).parts
    except ValueError:
        parts = (src.name,)

    if len(parts) <= 2:
        return f"session_{stamp}_{src.stem[:8]}.txt"

    sess = parts[1][:8]
    agent = src.stem.replace("agent-", "")[:8]
    wf = next((p for p in parts if p.startswith("wf_")), "")
    wf_tag = f"_wf{wf[3:9]}" if wf else ""
    return f"session_{stamp}_{sess}{wf_tag}_agent_{agent}.txt"


def load_state(p: Path) -> dict:
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(p: Path, state: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".export_state.")
    with os.fdopen(fd, "w") as fh:
        json.dump(state, fh, indent=1, sort_keys=True)
    os.replace(tmp, p)


def export_one(src: Path, out_dir: Path, projects: Path, state: dict,
               max_chars: int, dry_run: bool) -> tuple[int, str | None]:
    """Append records added since the last run.  Returns (lines_written, note)."""
    st = src.stat()
    key = str(src)
    prev = state.get(key, {})

    # Unchanged since last pass — the common case, costs one stat().
    if prev.get("size") == st.st_size and prev.get("mtime") == st.st_mtime:
        return 0, None

    consumed = int(prev.get("records", 0))
    out_name = prev.get("out") or archive_name(src, projects)
    out_path = out_dir / out_name

    # Truncated or replaced upstream → start the archive over rather than
    # interleave two different sessions in one file.
    if st.st_size < int(prev.get("size", 0)):
        consumed = 0
        if not dry_run and out_path.exists():
            out_path.unlink()

    lines: list[str] = []
    marker = prev.get("marker", "")
    seen = 0
    with src.open("r", errors="replace") as fh:
        for raw in fh:
            seen += 1
            if seen <= consumed:
                continue
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except json.JSONDecodeError:
                continue
            # Hourly `===== ts =====` marker: what the indexer parses into its
            # ts column, so --since works on these archives too.
            rts = rec.get("timestamp") or ""
            hour = rts[:13]
            if hour and hour != marker:
                marker = hour
                lines.append("===== " + rts.replace("T", " ").replace("Z", "")[:19] + " =====")
            line = render_record(rec, max_chars)
            if line:
                lines.append(line)

    if dry_run:
        return len(lines), f"would write {len(lines)} lines -> {out_path.name}"

    if lines or not out_path.exists():
        new_file = not out_path.exists()
        with out_path.open("a") as fh:
            if new_file:
                fh.write(f"# session {src.stem}\n")
                fh.write(f"# source  {src}\n")
                fh.write(f"# exported {datetime.now(timezone.utc).isoformat(timespec='seconds')}\n\n")
            for line in lines:
                fh.write(line + "\n")

    state[key] = {"size": st.st_size, "mtime": st.st_mtime,
                  "records": seen, "out": out_name, "marker": marker}
    return len(lines), None


def main() -> int:
    ap = argparse.ArgumentParser(prog="transcript-exporter")
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--once", action="store_true", help="accepted for symmetry; always one pass")
    args = ap.parse_args()

    home = Path(args.home)
    logs = log_dir_for(home)
    if not logs.is_dir():
        sys.stderr.write(f"transcript-exporter: no log dir {logs}\n")
        return 0

    projects = home / ".claude" / "projects"
    if not projects.is_dir():
        sys.stderr.write(f"transcript-exporter: no transcripts at {projects}\n")
        return 0

    out_dir = logs / "sessions"
    if not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)

    state_path = out_dir / STATE_NAME
    state = load_state(state_path) if out_dir.is_dir() else {}

    # EVERY transcript at any depth: top-level sessions, subagents, and the
    # per-agent transcripts a workflow run nests under subagents/workflows/wf_*/.
    # Subagent output often exists ONLY there — the parent session keeps just the
    # agent's final message — and on this platform one tenant's workflow agents
    # already outnumber his session transcripts 341 to 6.  A shallow glob would
    # have silently dropped 86% of his history.
    sources = sorted(projects.rglob("*.jsonl"))

    total_lines = 0
    touched = 0
    for src in sources:
        try:
            n, note = export_one(src, out_dir, projects, state,
                                 args.max_chars, args.dry_run)
        except OSError as e:
            sys.stderr.write(f"transcript-exporter: {src}: {e}\n")
            continue
        if n or note:
            touched += 1
            total_lines += n
            if args.verbose or args.dry_run:
                print(f"  {src.name}: {note or f'+{n} lines'}")

    if not args.dry_run:
        try:
            save_state(state_path, state)
        except OSError as e:
            sys.stderr.write(f"transcript-exporter: cannot write state: {e}\n")
            return 1

    if args.verbose or args.dry_run or touched:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        print(f"transcript-exporter: {stamp} {touched} transcript(s), {total_lines} line(s)"
              + (" [dry-run]" if args.dry_run else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
