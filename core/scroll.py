#!/usr/bin/env python3
"""One collector core for macOS and Windows.

A faithful port of the zsh scripts, behind the same stdout contracts the app
already parses, because those contracts are the product:

    SESSIONS|N                       digest.sh
    sid|proj|title|HH:MM|inc         chats_list.sh
    phase|detail|done|total          the progress file
    start|chats|trigger|outcome|new|end     history.log

Stdlib only, on purpose. The Windows build ships the embeddable Python
distribution, and anything needing pip would need a wheel, a compiler, or an
IT conversation.

    python3 scroll.py probe                what this machine looks like
    python3 scroll.py digest [YYYY-MM-DD]  rebuild a day's context file
    python3 scroll.py chats                sid|proj|title|HH:MM|inc, one per line
    python3 scroll.py projects             name|chats_today|included
    python3 scroll.py history [days]       YYYY-MM-DD|collected
    python3 scroll.py status [--check]     health, line 1 is the menu bar text
    python3 scroll.py collect [trigger]    the run itself
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python < 3.9
    ZoneInfo = None

WINDOWS = os.name == "nt"


# --------------------------------------------------------------------------
# config
#
# paths.conf and schedule.conf keep the exact key='value' shape they have now,
# so the app's own readConf/writeConf/shQuote code is untouched and either
# implementation can write a file the other reads.
# --------------------------------------------------------------------------

DEFAULTS = {
    "daily_enabled": "true",
    "daily_start": "9",
    "daily_end": "18",
    "daily_every": "1",
    "daily_minute": "7",
    "daily_weekdays_only": "false",
    "daily_final": "",
    "weekly_enabled": "true",
    "weekly_day": "5",
    "weekly_time": "18:15",
    "notify_on_failure": "true",
    "DAILY_COMMAND": "/update_daily_auto",
    "REPORT_COMMAND": "",
    "EOD_SCRIPT": "",
    "EOW_SCRIPT": "",
    "EXCLUDED": "",
    "EXCLUDED_CHATS": "",
    "AGENT_FLAGS": "",
    "TZ_NAME": "Europe/Prague",
    "EXTRA_SOURCES": "true",
    "CURSOR_INCLUDE_UNSCOPED": "true",
    "SUMMARY_ENABLED": "true",
    "SUMMARY_CLI": "",
    "SUMMARY_MODEL": "",
    "SUMMARY_SKILL": "",
}

PATH_KEYS = ("WORKDIR", "PROJECTS", "LOGDIR", "FIVE", "AGENT_CLI",
             "PROJ_PREFIX", "HIST", "PROG", "LOG", "CODEX_SESSIONS", "CURSOR_PROJECTS", "CURSOR_DB")

_ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def _unquote(raw: str) -> str:
    """The subset of shell quoting these two files actually use."""
    raw = raw.strip()
    for q in ("'", '"'):
        if raw.startswith(q):
            end = raw.find(q, 1)
            if end != -1:
                return raw[1:end]
    # unquoted: a comment needs whitespace in front of it, as in shell
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip()


def read_conf(path: Path) -> dict:
    out = {}
    try:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return out
    for line in text.replace("\r\n", "\n").split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _ASSIGN.match(line)
        if m:
            out[m.group(1)] = _unquote(m.group(2))
    return out


def encode_cwd(path: str) -> str:
    """How an agent names the transcript folder for a working directory.

    macOS: every separator becomes a dash, so /Users/x/Work -> -Users-x-Work.

    Windows is UNVERIFIED. The rule below (drop the drive colon, separators to
    dashes) is a guess and it is the one assumption the whole Windows port sits
    on. `scroll.py probe` prints what this computes next to what is actually on
    disk, so half a day on a real machine settles it. Nothing else in this file
    encodes a path, deliberately: when the guess turns out wrong, this is the
    only line that changes.
    """
    p = str(path).replace("\\", "/").replace(":", "")
    return p.replace("/", "-")


class Conf:
    def __init__(self):
        self.home = Path.home()
        env = os.environ
        here = Path(__file__).resolve().parent
        # the checkout, not core/
        self.beat_home = Path(
            env.get("SCROLLBACK_HOME") or env.get("BEAT_HOME") or here.parent
        )

        conf_path = Path(env.get("BEAT_CONF") or self.home / ".beatbar/paths.conf")
        fromfile = {}
        for f in (conf_path, self.beat_home / "paths.conf",
                  self.beat_home / "schedule.conf"):
            fromfile.update(read_conf(f))
        # The precedence paths.sh has: a config file is a hard assignment and
        # wins, but the environment fills anything no file sets, which is what
        # lets a test run point FIVE somewhere harmless.
        vals = dict(DEFAULTS)
        for k in set(DEFAULTS) | set(PATH_KEYS):
            if env.get(k):
                vals[k] = env[k]
        vals.update(fromfile)
        self.v = vals

        self.workdir = Path(vals.get("WORKDIR") or self.home / "Work")
        self.projects = Path(vals.get("PROJECTS") or self.home / ".claude/projects")
        self.logdir = Path(vals.get("LOGDIR") or self.home / ".claude/logs")
        self.agent_cli = vals.get("AGENT_CLI") or str(self.home / ".local/bin/claude")
        self.five = Path(vals.get("FIVE") or self.workdir / "5_15")
        self.prefix = vals.get("PROJ_PREFIX") or encode_cwd(self.workdir)
        self.hist = Path(vals.get("HIST") or self.five / ".beats/history.log")
        self.prog = Path(vals.get("PROG") or self.logdir / "collect-progress.txt")
        self.log = Path(vals.get("LOG") or self.logdir / "daily-auto.log")
        self.excluded = [x for x in vals.get("EXCLUDED", "").split(",") if x]
        self.excluded_chats = [x for x in vals.get("EXCLUDED_CHATS", "").split(",") if x]
        for d in (self.logdir, self.hist.parent):
            d.mkdir(parents=True, exist_ok=True)

    def __getitem__(self, k):
        return self.v.get(k, "")

    def on(self, k) -> bool:
        return self.v.get(k, "true").lower() == "true"

    def num(self, k, default=0) -> int:
        try:
            return int(str(self.v.get(k, "")).strip() or default)
        except ValueError:
            return default

    @property
    def tz(self):
        if ZoneInfo is None:
            return None
        try:
            return ZoneInfo(self["TZ_NAME"] or "Europe/Prague")
        except Exception:
            # Windows without tzdata. Local time is closer than UTC, and this
            # only affects the HH:MM shown beside a chat.
            return None

    def project_dirs(self):
        """Every project root under the work directory, newest name order.

        One session per project is normal, and a hardcoded list once saw 2 of
        10. Roots outside the work directory are deliberately not matched.
        """
        try:
            entries = sorted(self.projects.iterdir())
        except OSError:
            return []
        return [d for d in entries if d.is_dir() and d.name.startswith(self.prefix)]

    def proj_name(self, d: Path) -> str:
        n = d.name[len(self.prefix):].lstrip("-")
        return n or self.workdir.name


# --------------------------------------------------------------------------
# shared helpers
# --------------------------------------------------------------------------

NOISE_DIGEST = re.compile(
    r"^(Auto daily-log|<task-notification|<scheduled-task|<command-message"
    r"|<command-name|<local-command|<system-reminder|/update_daily|/loop"
    r"|reply with exactly|Caveat:|You are handling a /|You are the time-gated"
    r"|Base directory for this skill|Skill /)"
)
NOISE_CHATS = re.compile(
    r"^(Auto daily-log|<task-notification|<scheduled-task|<command-message"
    r"|<command-name|<local-command|<system-reminder|/update_daily|/loop|Caveat:)"
)
# An interactive message carries promptSource "typed"; older builds carry
# origin.kind "human". A headless run has neither, which is also how the
# collector's own write-up sessions stop counting as work.
TYPED = re.compile(r'"(promptSource":"typed|kind":"human)"')
STAMP = re.compile(r'"timestamp":"([^"]+)"')
TITLE = re.compile(r'"customTitle":"([^"]*)"')
WS = re.compile(r"[\r\n\t]+")

_SECRET = re.compile(
    r"(sk-|ghp_|gho_|ghs_|glpat-|xox[abprs]-|eyJ)[A-Za-z0-9._~+/-]{8,}=*"
)
_LONG = re.compile(r"[A-Za-z0-9_-]{40,}")


def redact(s: str) -> str:
    return _LONG.sub("[redacted]", _SECRET.sub("[redacted]", s))


def tail_lines(path: Path, n: int) -> list:
    """Last n lines without reading a 3 MB transcript into memory."""
    try:
        with path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            end = fh.tell()
            block, data = 65536, b""
            while end > 0 and data.count(b"\n") <= n:
                step = min(block, end)
                end -= step
                fh.seek(end)
                data = fh.read(step) + data
        return data.decode("utf-8", "replace").splitlines()[-n:]
    except OSError:
        return []


def head_lines(path: Path, n: int) -> list:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            return [next(fh) for _ in range(n)]
    except StopIteration:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            return fh.readlines()
    except OSError:
        return []


def last_typed_day(path: Path) -> str:
    """The day a person last typed in this chat, or "" if nobody ever did.

    Selecting by file timestamp is a different question: transcripts get
    rewritten in bulk without gaining content. Measured 2026-08-19: five in the
    same second, and 21 files touched that day against 3 anyone had typed in.
    """
    hit = [l for l in tail_lines(path, 400) if TYPED.search(l)]
    if not hit:
        return ""
    m = STAMP.search(hit[-1])
    return m.group(1).split("T")[0] if m else ""


def custom_title(path: Path) -> str:
    found = ""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = TITLE.search(line)
                if m:
                    found = m.group(1)
    except OSError:
        pass
    return found


def touched_on(path: Path, day: str) -> bool:
    try:
        return date.fromtimestamp(path.stat().st_mtime).isoformat() == day
    except OSError:
        return False


def week_of(day: str) -> str:
    y, m, d = (int(x) for x in day.split("-"))
    return "week_%02d" % date(y, m, d).isocalendar()[1]


def clock(iso: str, fmt: str, tz) -> str:
    """A transcript stamp, in the reader's timezone."""
    try:
        t = datetime.strptime(iso.split(".")[0].rstrip("Z"), "%Y-%m-%dT%H:%M:%S")
    except (ValueError, AttributeError):
        return ""
    t = t.replace(tzinfo=timezone.utc)
    return (t.astimezone(tz) if tz else t.astimezone()).strftime(fmt)


def iso_to_epoch(iso: str) -> float:
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc).timestamp()
    except (ValueError, TypeError):
        return 0.0


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# digest
# --------------------------------------------------------------------------

def parse_transcript(path: Path):
    """The four record kinds the digest cares about, in file order."""
    stamps, users, tools, files, answers = [], [], 0, [], []
    try:
        fh = path.open("r", encoding="utf-8", errors="replace")
    except OSError:
        return stamps, users, tools, files, answers
    with fh:
        for line in fh:
            line = line.strip()
            if not line or line[0] != "{":
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            if rec.get("timestamp"):
                stamps.append(rec["timestamp"])
            kind = rec.get("type")
            msg = rec.get("message") or {}
            side = bool(rec.get("isSidechain"))
            if kind == "user" and not side and isinstance(msg.get("content"), str):
                users.append(WS.sub(" ", msg["content"]))
            if kind == "assistant":
                blocks = msg.get("content")
                if isinstance(blocks, list):
                    for b in blocks:
                        if not isinstance(b, dict):
                            continue
                        if b.get("type") == "tool_use":
                            tools += 1
                            inp = b.get("input") or {}
                            p = inp.get("file_path") or inp.get("notebook_path") or ""
                            if p and b.get("name") in ("Edit", "Write", "NotebookEdit"):
                                files.append(p)
                    if not side:
                        text = " ".join(
                            b.get("text", "") for b in blocks
                            if isinstance(b, dict) and b.get("type") == "text")
                        if text:
                            answers.append(WS.sub(" ", text))
    return stamps, users, tools, files, answers


def extra_sessions(conf, day):
    if conf["EXTRA_SOURCES"] != "true":
        return []
    try:
        from .sources import sessions
    except ImportError:
        from sources import sessions
    return sessions(conf, day)


def extra_chats(conf, day):
    rows = []
    for session in extra_sessions(conf, day):
        sid, proj = session["sid"], session["project"]
        title = WS.sub(" ", session["title"] or session["users"][0])[:60]
        inc = int(proj not in conf.excluded and sid not in conf.excluded_chats)
        tm = clock(session.get("latest_activity") or session["stamps"][-1], "%H:%M", conf.tz)
        rows.append("|".join((sid, proj.replace("|", " "),
                              title.replace("|", " "), tm, str(inc))))
    return rows


def extra_changed(conf, cutoff):
    changed = 0
    for session in extra_sessions(conf, date.today().isoformat()):
        if session["sid"] in conf.excluded_chats or session["project"] in conf.excluded:
            continue
        stamps = list(session["stamps"])
        stamps.append(session.get("latest_activity"))
        for action in session.get("actions", []):
            stamps.extend((action.get("started_at"), action.get("completed_at")))
        epochs = [datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
                  for t in stamps if t]
        if epochs and max(epochs) > cutoff:
            changed += 1
    return changed


def extra_sections(conf, day):
    sections = []
    for session in extra_sessions(conf, day):
        sid = session["sid"]
        if sid in conf.excluded_chats or session["project"] in conf.excluded:
            continue
        task = WS.sub(" ", session["users"][0]) if session["users"] else ""
        if not task:
            continue
        stamps = session["stamps"]
        first = stamps[0]
        start = clock(first, "%H:%M", conf.tz) or "?"
        if clock(first, "%F", conf.tz) != day:
            start = "%s %s" % (clock(first, "%m-%d", conf.tz), start)
        end = clock(session.get("latest_activity") or stamps[-1], "%H:%M", conf.tz) or "?"
        answers = session["answers"]
        body = ["## %s  (%s - %s)\n" % (sid, start, end),
                "- Task: %s" % task[:200],
                "- Ended: %s" % (WS.sub(" ", answers[-1])[:300] if answers
                                  else "(no assistant text)"),
                "- Tool calls: %s" % session["tools"]]
        files = list(dict.fromkeys(session["files"]))[:10]
        if files:
            body.append("- Files touched:")
            body.extend("  - %s" % WS.sub(" ", f) for f in files)
        actions = session.get("actions", [])
        if actions:
            body.append("- Actions:")
            for action in actions[:100]:
                name = WS.sub(" ", str(action.get("name", "Unknown action")))[:100]
                status = WS.sub(" ", str(action.get("status", "unknown")))[:50]
                started = action.get("started_at") or "unknown"
                completed = action.get("completed_at") or "not recorded"
                body.append("  - %s | %s | started %s | completed %s" % (
                    name, status, started, completed))
            if len(actions) > 100:
                body.append("  - Showing 100 of %s actions." % len(actions))
        text = redact("\n".join(body) + "\n")
        text += "\n- Transcript: %s\n\n" % session["path"]
        sections.append((session["tools"], first, sid, text))
    return sections


def digest(conf: Conf, day: str = "", progress: Path = None) -> int:
    today = date.today().isoformat()
    day = day or today
    out = conf.five / week_of(day) / ("%s-context.md" % day)
    out.parent.mkdir(parents=True, exist_ok=True)
    tz = conf.tz

    dirs = [d for d in conf.project_dirs()
            if conf.proj_name(d) not in conf.excluded]

    total = sum(len([f for f in d.glob("*.jsonl") if touched_on(f, day)])
                for d in dirs)
    seen = 0
    sections = []

    for d in dirs:
        for f in sorted(d.glob("*.jsonl")):
            if not touched_on(f, day):
                continue
            sid = f.stem
            if sid in conf.excluded_chats:
                continue

            # Only for today. A past day is rebuilt from transcripts that have
            # since moved on, so applying this there would drop sessions that
            # were real at the time, which is what the gain-only guard below
            # exists to prevent.
            if day == today and last_typed_day(f) != day:
                continue

            seen += 1
            stamps, users, ntools, files, answers = parse_transcript(f)
            task = next((u for u in users if not NOISE_DIGEST.match(u)), "")

            if progress:
                # Named after the chat, not the folder it lives in. Emitted
                # here because the name only exists once the transcript is read.
                label = custom_title(f) or (task or conf.proj_name(d) or
                                            "work (general)")[:44]
                say(progress, "Reading transcripts|%s|%s|%s" % (label, seen, total))

            if not task:
                continue  # automated or empty session

            first_ts = stamps[0] if stamps else ""
            start = clock(first_ts, "%H:%M", tz) or "?"
            if first_ts and clock(first_ts, "%F", tz) != day:
                start = "%s %s" % (clock(first_ts, "%m-%d", tz), start)
            end = clock(stamps[-1], "%H:%M", tz) if stamps else "?"

            body = ["## %s  (%s - %s)\n" % (sid[:8], start, end or "?"),
                    "- Task: %s" % task[:200],
                    "- Ended: %s" % (answers[-1][:300] if answers
                                     else "(no assistant text)"),
                    "- Tool calls: %s" % ntools]
            uniq = list(dict.fromkeys(files))[:10]
            if uniq:
                body.append("- Files touched:")
                body += ["  - %s" % p for p in uniq]
            text = redact("\n".join(body) + "\n")
            # Appended after redaction: a project dir name is one long
            # [A-Za-z0-9_-] segment and the token scrubber would eat it. The
            # full path lets a write-up agent open the transcript itself.
            text += "\n- Transcript: %s\n\n" % f
            sections.append((ntools, first_ts, sid, text))

    sections.extend(extra_sections(conf, day))
    kept = len(sections)
    capped = ""
    if kept > 20:
        # tools, then start time, both descending: see the note in digest.sh
        sections.sort(key=lambda s: (s[0], s[1]), reverse=True)
        sections = sections[:20]
        capped = "Showing the 20 busiest sessions of %d (ranked by tool calls)." % kept
        kept = 20
    sections.sort(key=lambda s: s[1])

    # A past day may only GAIN sessions, never lose them. Rebuilding selects by
    # mtime and mtimes move, so a naive rebuild writes a thinner file over a
    # good one. Measured once at 6 sessions down to 1.
    if day != today and out.exists():
        m = re.search(r"Sessions: (\d+)", out.read_text(encoding="utf-8",
                                                        errors="replace"))
        if m and int(m.group(1)) > kept:
            print("SESSIONS|%s" % m.group(1))
            return 0

    stamp = datetime.now(tz) if tz else datetime.now()
    head = ["# Chat context, %s\n" % day,
            "Generated %s (%s). Sessions: %s." % (
                stamp.strftime("%Y-%m-%d %H:%M"),
                conf["TZ_NAME"] or "local", kept)]
    if capped:
        head.append(capped)
    head.append("")
    out.write_text("\n".join(head) + "\n" + "".join(s[3] for s in sections)
                   + "---\nGenerated by Scrollback (core/scroll.py), rebuilt hourly.\n",
                   encoding="utf-8")
    print(out)
    # The count this run produced. Callers used to grep it back out of the file,
    # which silently returned the PREVIOUS run's number whenever this had
    # crashed, and that stale figure was recorded as the run's result.
    print("SESSIONS|%s" % kept)
    return 0


# --------------------------------------------------------------------------
# chats
# --------------------------------------------------------------------------

def live_counts(conf: Conf) -> dict:
    """How many chats are open per project folder.

    macOS only. Windows has no equivalent that can be trusted: reading another
    process's working directory needs psutil, a chat running under WSL or Git
    Bash is invisible to a Windows process listing anyway, and the desktop
    app's pty-socket trick does not exist there. So on Windows every folder is
    unbudgeted and "open now" means "typed in today", which is the same
    definition the digest uses. What lands in the log is identical either way:
    the collector always runs with BEAT_ALL.
    """
    if WINDOWS:
        return {}
    try:
        pids = subprocess.run(["pgrep", "-x", "claude"], capture_output=True,
                              text=True).stdout.split()
    except OSError:
        return {}
    exact, cand = set(), []
    for pid in pids:
        try:
            args = subprocess.run(["ps", "-o", "args=", "-p", pid],
                                  capture_output=True, text=True).stdout.strip()
        except OSError:
            continue
        # The desktop app names its pty socket after the session, so those are
        # known exactly rather than counted: /tmp/cc-daemon-*/pty/<id>.sock
        if "--bg-pty-host" in args:
            m = re.search(r"pty/([^.]+)\.sock", args)
            if m:
                exact.add(m.group(1))
            continue
        # Not chats anyone has open: this app's own write-up step and any
        # scheduled job run headless, and the daemon is not a conversation.
        if " -p " in args or " --print " in args or "daemon run" in args:
            continue
        cand.append(pid)

    live = {}
    if cand:
        # One lsof for every candidate rather than one each: it takes about a
        # second to start, so asking it seven times cost seven seconds.
        try:
            out = subprocess.run(
                ["lsof", "-a", "-p", ",".join(cand), "-d", "cwd", "-Fpn"],
                capture_output=True, text=True).stdout
        except OSError:
            out = ""
        for line in out.splitlines():
            if line.startswith("n"):
                cwd = line[1:]
                if cwd.startswith(str(conf.workdir)):
                    enc = encode_cwd(cwd)
                    live[enc] = live.get(enc, 0) + 1
    live["__exact__"] = exact
    return live


def chats(conf: Conf, every: bool = None):
    """sid|proj|title|HH:MM|inc, one line per chat."""
    if every is None:
        every = bool(os.environ.get("BEAT_ALL"))
    today = date.today().isoformat()
    live = {} if every else live_counts(conf)
    exact = live.pop("__exact__", set()) if not every else set()
    own = [c for c in (conf["DAILY_COMMAND"], conf["REPORT_COMMAND"]) if c]
    rows = []

    for d in conf.project_dirs():
        proj = conf.proj_name(d)
        folder_off = proj in conf.excluded

        budget = 999
        if not every:
            budget = live.get(d.name, 0)
            if budget == 0:
                continue

        shown = 0
        # newest first, so a budget keeps the chats you last typed in
        try:
            files = sorted(d.glob("*.jsonl"),
                           key=lambda f: f.stat().st_mtime, reverse=True)
        except OSError:
            continue
        for f in files:
            # Cheap gate first: a file untouched today cannot hold a message
            # typed today, and stat costs nothing next to reading every tail.
            if not touched_on(f, today):
                continue
            if last_typed_day(f) != today:
                continue
            sid = f.stem
            # A session the desktop app holds open is listed on its own
            # evidence and does not spend the terminal budget.
            if sid not in exact:
                if shown >= budget:
                    continue
                shown += 1

            first = ""
            for line in head_lines(f, 60):
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if (isinstance(rec, dict) and rec.get("type") == "user"
                        and not rec.get("isSidechain")
                        and isinstance((rec.get("message") or {}).get("content"), str)
                        and (rec.get("promptSource") == "typed"
                             or (rec.get("origin") or {}).get("kind") == "human")):
                    c = WS.sub(" ", rec["message"]["content"])
                    if not NOISE_CHATS.match(c):
                        first = c
                        break
            if not first:
                continue
            # Not the app's own runs. A session whose first message IS one of
            # the configured commands was opened by this app, not by a person,
            # and could otherwise be switched off, which would exclude a log run
            # rather than a conversation.
            if any(first.startswith(c) for c in own):
                continue

            title = (custom_title(f) or first[:60]).replace("|", " ")
            inc = 0 if (folder_off or sid in conf.excluded_chats) else 1
            tm = datetime.fromtimestamp(f.stat().st_mtime).strftime("%H:%M")
            rows.append("%s|%s|%s|%s|%s" % (sid, proj, title, tm, inc))
    if every:
        rows.extend(extra_chats(conf, today))
    return rows


def projects(conf: Conf):
    """name|chats_today|included, derived from chats so there is one number."""
    n = {}
    for row in chats(conf, every=True):
        proj = row.split("|")[1]
        n[proj] = n.get(proj, 0) + 1
    # an excluded folder must stay visible or you could never switch it back on
    for e in conf.excluded:
        n.setdefault(e, 0)
    return ["%s|%s|%s" % (k, n[k], 0 if k in conf.excluded else 1)
            for k in sorted(n)]


def history(conf: Conf, days: int = 7):
    """YYYY-MM-DD|collected, from each day's own context file.

    There is no second "chats that existed" series: a transcript's mtime is
    only its last write, so a chat worked on across several days counts only on
    the final one, and past days read as zero.
    """
    got = {}
    for ctx in conf.five.glob("week_*/*-context.md"):
        m = re.search(r"Sessions: (\d+)", ctx.read_text(encoding="utf-8",
                                                        errors="replace")[:400])
        if m:
            got[ctx.name[:-len("-context.md")]] = m.group(1)
    out = []
    for i in range(days - 1, -1, -1):
        d = (date.today() - timedelta(days=i)).isoformat()
        out.append("%s|%s" % (d, got.get(d, "0")))
    return out


# --------------------------------------------------------------------------
# status
#
# Reads real artifacts, not a ledger, because a ledger can say "success" while
# nothing was written. Line 1 is the menu bar text; the rest is the menu.
# --------------------------------------------------------------------------

DAYNAMES = {1: "Monday", 2: "Tuesday", 3: "Wednesday", 4: "Thursday",
            5: "Friday", 6: "Saturday", 7: "Sunday"}


def fire_epoch(day: str, hh: int, mm: int) -> float:
    y, mo, d = (int(x) for x in day.split("-"))
    return datetime(y, mo, d, hh, mm).timestamp()


def last_row(conf: Conf) -> list:
    try:
        rows = [r for r in conf.hist.read_text(errors="replace").splitlines() if r]
    except OSError:
        return []
    return rows[-1].split("|") if rows else []


def last_ok_row(conf: Conf) -> list:
    try:
        rows = [r for r in conf.hist.read_text(errors="replace").splitlines()
                if "|ok|" in r]
    except OSError:
        return []
    return rows[-1].split("|") if rows else []


def status(conf: Conf, check: bool = False) -> int:
    now = time.time()
    today = date.today().isoformat()
    week = week_of(today)
    dow = date.today().isoweekday()
    friday = (date.today() - timedelta(days=(dow - 5) % 7)).isoformat()
    tz = conf.tz
    # Every unhealthy condition goes in here and nowhere else, so the headline
    # and the PROBLEM lines cannot disagree. They used to: three conditions set
    # a bad flag silently, including a FAILED RUN, which never reached the icon.
    problems, fix, out = [], "", []

    start_h, end_h = conf.num("daily_start", 9), conf.num("daily_end", 18)
    every_h = max(1, conf.num("daily_every", 1))
    minute = conf.num("daily_minute", 7)
    weekdays = conf.on("daily_weekdays_only")
    final = conf["daily_final"].strip()

    # --- Daily: the per-chat digest is the artifact it always writes.
    dg = conf.five / week / ("%s-context.md" % today)
    if dg.exists():
        n = sum(1 for l in dg.read_text(errors="replace").splitlines()
                if l.startswith("## "))
        daily = "collected %d chat(s) at %s" % (
            n, datetime.fromtimestamp(dg.stat().st_mtime).strftime("%H:%M"))
    elif not conf.on("daily_enabled"):
        daily = "collection is off"
    elif weekdays and dow > 5:
        daily = "not scheduled today"
    elif now < fire_epoch(today, start_h, minute) + 900:
        # Before the first fire nothing has failed. Saying NOTHING COLLECTED at
        # 02:00 turned the bar red for seven hours every morning.
        daily = "first run at %02d:%02d" % (start_h, minute)
    else:
        daily = "NOTHING COLLECTED TODAY"
        problems.append("No chats have been collected today. "
                        "The digest file was never written.")

    # --- Weekly: the 5/15 for the most recent Friday, matched by DATE, not by
    # a name, and in that Friday's own week folder. It used to look in this
    # week's folder, so on a Monday a missed 5/15 stayed missed silently.
    fweek = week_of(friday)
    report = None
    for f in sorted((conf.five / fweek).glob("*%s*.md" % friday)):
        if any(t in f.name for t in ("5-15", "5_15", "515")):
            report = f
            break
    wtime = conf["weekly_time"] or "18:15"
    if report:
        weekly = "written %s" % datetime.fromtimestamp(
            report.stat().st_mtime).strftime("%a %d %b %H:%M")
    elif not (conf.five / fweek).is_dir():
        weekly = "no work logged that week"
    elif not conf.on("weekly_enabled"):
        weekly = "not written for %s" % friday   # nothing will write it on its own
    elif now < fire_epoch(friday, *(int(x) for x in wtime.split(":"))) + 900:
        weekly = "due today at %s" % wtime
    else:
        weekly = "MISSING for %s" % friday
        problems.append("No 5/15 written for %s. "
                        "Open Scrollback and use the weekly button." % friday)

    # The last recorded outcome, whoever triggered it. launchd's LastExitStatus
    # is deliberately not used: it sticks until the next scheduled fire, so a
    # successful manual retry could never clear it.
    row = last_row(conf)
    last_outcome = row[3] if len(row) > 3 else ""
    last_trigger = row[2] if len(row) > 2 else ""
    d_failed = last_outcome == "fail"
    if d_failed:
        problems.append("The last run (%s) failed. Nothing was collected that "
                        "time." % (last_trigger or "manual"))

    # --- Runs that never happened. A crashed run leaves a fail row; a run that
    # never fired leaves nothing at all, and "nothing" used to read as healthy.
    missed = 0
    if conf.on("daily_enabled") and not (weekdays and dow > 5):
        ok = last_ok_row(conf)
        last_ok_ep = iso_to_epoch(ok[0]) if ok else 0
        fires = [(h, minute) for h in range(start_h, end_h + 1, every_h)]
        if final:
            fires.append(tuple(int(x) for x in final.split(":")))
        for hh, mm in fires:
            fe = fire_epoch(today, hh, mm)
            # 15 minutes of grace: a run takes minutes, so the newest fire may
            # still be going.
            if now - fe > 900 and last_ok_ep < fe:
                missed += 1
        if missed:
            problems.append("%d scheduled run(s) did not happen today. The Mac "
                            "was probably asleep or off at the time." % missed)

    # --- Chats this tool does not look at. Not an error, but never silent: a
    # collector that quietly ignores where the work happened is the bug this
    # whole tool exists to catch.
    outside = 0
    try:
        for pd in conf.projects.iterdir():
            if not pd.is_dir() or pd.name.startswith(conf.prefix):
                continue
            outside += sum(1 for f in pd.glob("*.jsonl") if touched_on(f, today))
    except OSError:
        pass

    # Signing in is the one failure a person has to fix and Retry can never fix,
    # so it gets its own action. Only the MOST RECENT run block, never a fixed
    # tail: a window of lines spans several runs, so a failure that had since
    # been fixed kept reporting itself.
    block = []
    try:
        for line in conf.log.read_text(errors="replace").splitlines():
            if re.match(r"^--- .* collect ", line):
                block = []
            block.append(line)
    except OSError:
        pass
    if block and re.search(r"error|ENOTFOUND", block[-1], re.I):
        msg = block[-1][:90]
        if "ENOTFOUND" in msg:
            msg = "No network when it ran. Nothing was collected that hour."
        elif msg == "Execution error":
            msg = "The run stopped part-way. Usually the API was unreachable."
        problems.append(msg)
    if re.search(r"Not logged in|Please run /login|Invalid API key"
                 r"|authentication_error", "\n".join(block), re.I):
        problems = ["Your chats were collected, but signing in failed so they "
                    "were not written up. A scheduled run cannot read the "
                    "keychain and needs its own token."]
        fix = "login"

    # The digest keeps only the 20 busiest sessions on a very long day. Loud,
    # because past that line chats really are being dropped.
    if dg.exists():
        for l in dg.read_text(errors="replace").splitlines():
            if l.startswith("Showing the "):
                problems.append("%s The rest were left out of today's digest." % l)
                break

    bad = len(problems)
    out.append("5/15 collection: %s" % ("NEEDS ATTENTION" if bad else "healthy"))
    out.append("---")
    out.append("Checked just now: %s" % datetime.now().strftime("%a %d %b, %H:%M"))
    out.append("")
    out.append("What this does: every run reads your configured chats, including")
    out.append("closed ones, and writes what each was about into the daily log.")
    out.append("Friday's run turns the week of those into your 5/15 report.")
    out.append("")

    if conf.on("daily_enabled"):
        d_when = "every %dh, %02d:%02d to %02d:%02d" % (
            every_h, start_h, minute, end_h, minute)
        if final:
            d_when += ", plus %s" % final
        if weekdays:
            d_when += ", weekdays only"
    else:
        d_when = "OFF"
    w_when = ("%s %s" % (DAYNAMES.get(conf.num("weekly_day", 5), "Sunday"), wtime)
              if conf.on("weekly_enabled") else "when you press the button")

    # When the next collection actually happens. After the last fire of the day
    # there is nothing more until morning, and saying so is the difference
    # between "finished" and "did it stop working?".
    nextrun = ""
    if conf.on("daily_enabled"):
        if not (weekdays and dow > 5):
            for h in range(start_h, end_h + 1, every_h):
                if fire_epoch(today, h, minute) > now:
                    nextrun = "today at %02d:%02d" % (h, minute)
                    break
        if not nextrun:
            for ahead in (1, 2, 3):
                nxt = date.today() + timedelta(days=ahead)
                if weekdays and nxt.isoweekday() > 5:
                    continue
                when = "tomorrow" if ahead == 1 else nxt.strftime("%A")
                nextrun = "%s at %02d:%02d" % (when, start_h, minute)
                break

    out.append("Daily digest    %s" % daily)
    out.append("  runs          %s" % d_when)
    if nextrun:
        out.append("  next run      %s" % nextrun)
    out.append("  last run      %s" % ("FAILED (%s)" % last_trigger if d_failed
                                       else "finished (%s)" % (last_trigger or "none")))
    out.append("")
    out.append("Weekly 5/15     %s" % weekly)
    out.append("  runs          %s" % w_when)
    out.append("  scheduled     Friday, on its own")

    if fix:
        out.append("FIX|%s" % fix)
    for p in problems:
        out.append("")
        out.append("PROBLEM: %s" % p)
    if outside:
        out.append("")
        out.append("NOTE: %d chat(s) today in folders outside %s. Not collected, "
                   "by design." % (outside, conf.workdir))

    # How much has changed since the last run. Counted from the chat list, not
    # raw transcript files: the raw count included the collector's own headless
    # runs, so the panel said "8 of 18" while the Chats window said "8 of 8".
    lastiso = (row[5] if len(row) > 5 and row[5] else (row[0] if row else ""))
    lastep = iso_to_epoch(lastiso) if lastiso else 0
    rows = chats(conf, every=True)
    newn = 0
    if lastep:
        for r in rows:
            sid = r.split("|")[0]
            if sid.startswith(("codex:", "cursor:")):
                continue
            for d in conf.project_dirs():
                f = d / ("%s.jsonl" % sid)
                if f.exists():
                    if f.stat().st_mtime > lastep:
                        newn += 1
                    break
        newn += extra_changed(conf, lastep)
    out.append("CHANGED|%d|%d" % (newn, len(rows)))

    todayfile = conf.five / week / ("%s.md" % today)
    out.append("")
    if todayfile.exists():
        text = todayfile.read_text(errors="replace")
        kb = max(1, (todayfile.stat().st_size + 1023) // 1024)
        out.append("Today's file    %s.md  (%dK, %d entries)" % (
            today, kb, sum(1 for l in text.splitlines() if l.startswith("- "))))
    else:
        out.append("Today's file    not written yet")

    print("\n".join(out))
    return 1 if (check and bad) else 0


# --------------------------------------------------------------------------
# collect
# --------------------------------------------------------------------------

def run_digest(conf: "Conf", day: str, prog: Path = None) -> str:
    """The digest's stdout, captured. Callers log it and read SESSIONS|N out of
    it; nothing reads the file back, because a re-read returns the last good
    value exactly when the step has just failed."""
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        digest(conf, day, progress=prog)
    return buf.getvalue()


def say(prog: Path, line: str):
    try:
        prog.write_text(line + "\n", encoding="utf-8")
    except OSError:
        pass


def append(path: Path, line: str):
    try:
        with path.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def token_is_locked(p: Path) -> bool:
    """The token is a long-lived credential in plaintext, so it is refused
    unless the file is locked to its owner. One forgotten chmod must not leave
    it readable to everything running as this user."""
    if not WINDOWS:
        return oct(p.stat().st_mode & 0o777) == "0o600"
    # Windows has no mode bits. Owner-only means no inherited ACEs and no
    # entry for Users/Everyone/Authenticated Users.
    try:
        acl = subprocess.run(["icacls", str(p)], capture_output=True,
                             text=True).stdout
    except OSError:
        return False
    bad = ("BUILTIN\\Users", "Everyone", "AUTHENTICATED USERS", "(I)")
    return not any(b.lower() in acl.lower() for b in bad)


def pid_alive(pid: int) -> bool:
    if WINDOWS:
        try:
            out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid],
                                 capture_output=True, text=True).stdout
            return str(pid) in out
        except OSError:
            return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def collect(conf: Conf, trigger: str = "manual") -> int:
    log, prog = conf.log, conf.prog
    today = date.today().isoformat()

    if not WINDOWS:
        os.environ["PATH"] = ("/opt/homebrew/bin:%s/.local/bin:/usr/local/bin:"
                              "/usr/bin:/bin:/usr/sbin:/sbin" % conf.home)
    # A scheduled run has no login keychain, where the agent CLI normally keeps
    # its credentials, so the write-up fails with "Not logged in" while the same
    # command works from a terminal. Supply a long-lived token instead:
    # `claude setup-token`, stored in ~/.beatbar/oauth_token.
    tok = conf.home / ".beatbar/oauth_token"
    if tok.is_file():
        if token_is_locked(tok):
            os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = tok.read_text().strip()
        else:
            append(log, "collect: refusing oauth_token, it is readable by more "
                        "than its owner (lock it to you to use it)")

    # Only one collection at a time. Two runs racing both rebuild the same
    # digest and both hand the same daily log to an agent, and the agents then
    # overwrite each other. mkdir is the atomic part; the pid file only tells a
    # live holder from a stale one left behind by a kill -9.
    lock = conf.logdir / "collect.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        holder = 0
        try:
            holder = int((lock / "pid").read_text().strip())
        except (OSError, ValueError):
            pass
        if holder and pid_alive(holder):
            append(log, "collect (%s): skipped, run %d is still going" % (trigger, holder))
            say(prog, "Already running|a collection started at %s is still going||"
                % datetime.fromtimestamp(lock.stat().st_mtime).strftime("%H:%M"))
            return 0
        _rmdir(lock)
        try:
            lock.mkdir()
        except OSError:
            return 0
    (lock / "pid").write_text(str(os.getpid()))

    started = utc_now_iso()
    chats_n, newn, outcome = 0, 0, "fail"

    def finish():
        # start|chats|trigger|outcome|new|end. Both times, because they answer
        # different questions: the start is what a human reads, and the END is
        # what "changed since the last run" measures from, or anything that
        # moved while the run was working gets counted again next time.
        append(conf.hist, "%s|%s|%s|%s|%s|%s" % (
            started, chats_n, trigger, outcome, newn, utc_now_iso()))
        _rmdir(lock)

    try:
        say(prog, "Looking for today's chats|||")

        # Folder names only, for the "preparing" line. The chat COUNT is
        # deliberately not computed here: this used to count project folders and
        # label them "chats", reading 6 when there were 8. The digest owns the
        # count, so there is one definition.
        names = sorted({conf.proj_name(d) or "work (general)"
                        for d in conf.project_dirs()
                        if any(touched_on(f, today) for f in d.glob("*.jsonl"))})

        # Chats touched since the previous SUCCESSFUL run, not simply the last
        # row: measuring from a failed run would drop every chat that moved
        # during the failure, and those were never collected, so they are still
        # new. Field 6 is when it finished; older rows only have field 1.
        ok = last_ok_row(conf)
        prev_ep = iso_to_epoch(ok[5] if len(ok) > 5 and ok[5] else
                               (ok[0] if ok else "")) if ok else 0
        rows = chats(conf, every=True)
        if prev_ep:
            for r in rows:
                sid = r.split("|")[0]
                if sid.startswith(("codex:", "cursor:")):
                    continue
                for d in conf.project_dirs():
                    f = d / ("%s.jsonl" % sid)
                    if f.exists():
                        if f.stat().st_mtime > prev_ep:
                            newn += 1
                        break

            newn += extra_changed(conf, prev_ep)

        say(prog, "Preparing|%d projects: %s||" % (len(names), ", ".join(names)))
        append(log, "--- %s collect %s ---" % (
            trigger, datetime.now().strftime("%Y-%m-%d %H:%M:%S")))

        # Days the collector never ran on. The digest window is one day wide and
        # nothing else goes back for them. Yesterday is ALWAYS rebuilt, because
        # collection stops at the end of the working day and anything typed
        # after the last run was never digested; the rebuild is safe because a
        # past day can only gain sessions. The other six are only built when
        # they have no digest at all, which covers a weekend or a Mac that was
        # off.
        for back in range(1, 8):
            d = (date.today() - timedelta(days=back)).isoformat()
            if back > 1 and (conf.five / week_of(d) / ("%s-context.md" % d)).exists():
                continue
            append(log, "--- catching up %s ---" % d)
            append(log, run_digest(conf, d).rstrip())

        # Deterministic and offline-safe, so this still succeeds when the API is
        # down. Its result is CHECKED. It used not to be, and for 12 runs on
        # 2026-08-11 the digest crashed on every one while the run still recorded
        # "ok": the outcome came from the write-up step alone, so a dead
        # collector was invisible.
        try:
            dout = run_digest(conf, today, prog)
        except Exception as exc:  # noqa: BLE001 - any failure is a failed run
            append(log, "collect (%s): FAILED, the digest could not read your "
                        "chats (%s)" % (trigger, exc))
            say(prog, "Failed|could not read your chats, nothing was collected||")
            return 1
        append(log, dout.rstrip())
        m = re.search(r"^SESSIONS\|(\d+)", dout, re.M)
        chats_n = int(m.group(1)) if m else 0

        # How many of those are still open, so the panel can show "9 today ·
        # 7 open" rather than a 9 that reads as "9 open" and is not.
        opennow = len(chats(conf, every=False))
        say(prog, "Writing into %s.md|starting|%s||%s" % (today, chats_n, opennow))

        cmd = conf["DAILY_COMMAND"]
        # The write-up step is optional and configurable. It used to hardcode a
        # skill that exists in one person's setup, so on anyone else's machine
        # every hourly run failed here. Left blank, the collection still does
        # its job: the digest is deterministic and needs no agent at all.
        if not cmd:
            append(log, "collect (%s): digest only, no write-up command set" % trigger)
            outcome = "ok"
            say(prog, "Done|%s chats collected||" % chats_n)
            return 0

        argv = [conf.agent_cli, "-p"] + conf["AGENT_FLAGS"].split() + [cmd]
        kw = {"cwd": str(conf.workdir), "stdout": None, "stderr": subprocess.STDOUT}
        if WINDOWS:
            # never flash a console for a scheduled run
            kw["creationflags"] = 0x08000000  # CREATE_NO_WINDOW
        with conf.log.open("a", encoding="utf-8") as fh:
            kw["stdout"] = fh
            proc = subprocess.Popen(argv, **kw)
            # Tick the progress file while it works. It used to be written ONCE
            # for a step that takes minutes, so the panel looked dead. The clock
            # lives here rather than in the app, so what the app renders is live
            # data rather than a timer of its own guessing at it.
            t0 = time.time()
            while proc.poll() is None:
                el = int(time.time() - t0)
                say(prog, "Writing into %s.md|%d:%02d|%s||%s" % (
                    today, el // 60, el % 60, chats_n, opennow))
                time.sleep(2)
        if proc.returncode == 0:
            append(log, "collect (%s): ok" % trigger)
            outcome = "ok"
            say(prog, "Done|%s chats collected||" % chats_n)
            return 0
        append(log, "collect (%s): FAILED, the write-up step could not finish" % trigger)
        say(prog, "Failed|the daily log step could not finish||")
        return 1
    finally:
        # One exit path for the record, so a run cannot finish without leaving
        # one. Three runs on 2026-08-11 were killed mid-write-up and left no row
        # at all, one after it had already appended to the daily log.
        finish()


def _rmdir(d: Path):
    try:
        for f in d.iterdir():
            f.unlink()
        d.rmdir()
    except OSError:
        pass


# --------------------------------------------------------------------------
# probe: the stage-0 Windows findings note, so it is one command not a morning
# --------------------------------------------------------------------------

def probe(conf: Conf) -> int:
    print("platform        %s, python %s" % (sys.platform, sys.version.split()[0]))
    print("home            %s" % conf.home)
    print("workdir         %s" % conf.workdir)
    print("projects        %s  (exists: %s)" % (conf.projects, conf.projects.is_dir()))
    print("computed prefix %s" % conf.prefix)
    try:
        dirs = sorted(d.name for d in conf.projects.iterdir() if d.is_dir())
    except OSError:
        dirs = []
    hit = [d for d in dirs if d.startswith(conf.prefix)]
    print("folders total   %d, matching the prefix: %d" % (len(dirs), len(hit)))
    if not hit and dirs:
        print("MISMATCH. encode_cwd() is wrong on this machine. Real names:")
        for d in dirs[:8]:
            print("                %s" % d)
    jsonl = [f for d in conf.project_dirs() for f in d.glob("*.jsonl")]
    print("transcripts     %d under the prefix" % len(jsonl))
    typed = sum(1 for f in jsonl[:40] if last_typed_day(f))
    print("typed field     found in %d of the first %d" % (typed, min(40, len(jsonl))))
    if ZoneInfo is None:
        print("timezone        zoneinfo MISSING")
    else:
        try:
            ZoneInfo(conf["TZ_NAME"])
            print("timezone        %s resolves" % conf["TZ_NAME"])
        except Exception:
            print("timezone        %s FAILED, install tzdata" % conf["TZ_NAME"])
    if WINDOWS:
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "Get-CimInstance Win32_Process -Filter \"Name like '%claude%' "
                 "or Name like '%node%'\" | Select-Object -First 5 "
                 "Name,ProcessId,CommandLine | Format-List"],
                capture_output=True, text=True, timeout=30).stdout.strip()
            print("agent processes\n%s" % (out or "                none found"))
        except (OSError, subprocess.SubprocessError) as exc:
            print("agent processes FAILED: %s" % exc)
    else:
        print("open chats      %d (pgrep/lsof path)" % len(chats(conf, every=False)))
    print("chats today     %d" % len(chats(conf, every=True)))
    return 0


def agents(conf):
    """One line per agent the collector can read: name|available (1/0)."""
    codex = Path(conf["CODEX_SESSIONS"] or conf.home / ".codex/sessions").expanduser()
    cursor = Path(conf["CURSOR_DB"] or conf.home / "Library/Application Support/Cursor/User/globalStorage/state.vscdb").expanduser()
    grok = conf.home / "Library/Application Support/Grok Bot"
    claude = conf.projects.is_dir() and any(conf.project_dirs())
    for name, ok in (("claude", claude), ("codex", codex.is_dir()), ("cursor", cursor.is_file()),
                     ("grok", grok.is_dir())):
        print("%s|%d" % (name, 1 if ok else 0))
    return 0


def summary_status(conf):
    try:
        from summary import resolve_cli, synthesizer_label
    except ImportError:
        from .summary import resolve_cli, synthesizer_label
    cli, _ = resolve_cli(conf.v)
    enabled = str(conf["SUMMARY_ENABLED"]).lower() == "true"
    print(json.dumps(dict(enabled=enabled, model=synthesizer_label(conf.v),
                          cli=cli, ready=bool(cli and Path(cli).is_file()))))
    return 0


# --------------------------------------------------------------------------

def main(argv) -> int:
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    conf = Conf()
    if cmd == "extra-changed":
        print(extra_changed(conf, float(rest[0])))
        return 0
    if cmd == "extra-chats":
        print("\n".join(extra_chats(conf, date.today().isoformat())))
        return 0
    if cmd == "extra-sections":
        sections = extra_sections(conf, rest[0])
        target = Path(rest[1])
        for i, (ntools, stamp, sid, text) in enumerate(sections):
            # Match the shell digest sorting contract without trusting IDs as paths.
            stamp = stamp.split(".")[0].rstrip("Z")
            (target / ("sec.%06d.%s.extra-%d" % (ntools, stamp, i))).write_text(
                text, encoding="utf-8")
        print(len(sections))
        return 0
    if cmd == "probe":
        return probe(conf)
    if cmd == "agents":
        return agents(conf)
    if cmd == "summary-status":
        return summary_status(conf)
    if cmd == "digest":
        return digest(conf, rest[0] if rest else "",
                      Path(os.environ["BEAT_PROGRESS"])
                      if os.environ.get("BEAT_PROGRESS") else None)
    if cmd == "chats":
        every = bool(os.environ.get("BEAT_ALL")) or "--all" in rest
        print("\n".join(chats(conf, every=every)))
        return 0
    if cmd == "projects":
        print("\n".join(projects(conf)))
        return 0
    if cmd == "history":
        print("\n".join(history(conf, int(rest[0]) if rest else 7)))
        return 0
    if cmd == "status":
        return status(conf, "--check" in rest)
    if cmd == "collect":
        return collect(conf, rest[0] if rest else "manual")
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
