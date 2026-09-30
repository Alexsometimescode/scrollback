#!/usr/bin/env python3
"""The invariants a run must not be able to break, checked in a scratch tree.

parity.sh covers what the core READS by diffing it against the zsh. This covers
what a run WRITES, which parity cannot reach without actually collecting: that a
run always leaves a history row, that a failure is recorded as a failure, and
that a second run cannot start on top of a live one. All three were real bugs.

    python3 core/selftest.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCROLL = HERE / "scroll.py"
fails = []


def check(name, cond, detail=""):
    print("  %-42s %s" % (name, "ok" if cond else "FAILED  " + detail))
    if not cond:
        fails.append(name)


def run(root, *args, command="", agent="/bin/echo", extra=None):
    conf = root / "paths.conf"
    conf.write_text("WORKDIR=%s\nPROJECTS=%s\nLOGDIR=%s\nAGENT_CLI=%s\n" % (
        Path.home() / "Work", Path.home() / ".claude/projects",
        root / "logs", agent))
    (root / "home").mkdir(exist_ok=True)
    (root / "schedule.conf").write_text("DAILY_COMMAND='%s'\n" % command)
    env = dict(os.environ)
    env.update({"BEAT_CONF": str(conf), "BEAT_HOME": str(root),
                "FIVE": str(root / "five"),
                "HIST": str(root / "five/.beats/history.log")})
    env.update(extra or {})
    return subprocess.run([sys.executable, str(SCROLL)] + list(args),
                          capture_output=True, text=True, env=env)


def rows(root):
    h = root / "five/.beats/history.log"
    return [r for r in h.read_text().splitlines() if r] if h.exists() else []


def main():
    print("selftest")
    today = date.today().isoformat()

    # 1. a good run: one row, six fields, outcome ok, lock released
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        # schedule.conf must exist before Conf reads it
        (root / "schedule.conf").write_text("DAILY_COMMAND=''\n")
        r = run(root, "collect", "scheduled")
        rs = rows(root)
        check("good run exits 0", r.returncode == 0, r.stderr[-200:])
        check("good run writes exactly one row", len(rs) == 1, str(rs))
        f = rs[0].split("|") if rs else []
        check("row has six fields", len(f) == 6, str(f))
        check("row records ok", len(f) > 3 and f[3] == "ok", str(f))
        check("row start is not its end", len(f) > 5 and f[0] <= f[5], str(f))
        check("lock released", not (root / "logs/collect.lock").exists())
        check("today's context written",
              (root / "five" / ("week_%02d" % date.today().isocalendar()[1])
               / ("%s-context.md" % today)).exists())

    # 2. a write-up that fails must be recorded as a failure, not as ok. The
    #    outcome used to come from the write-up step alone while the digest
    #    crashed silently; now every step's result reaches the row.
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        (root / "schedule.conf").write_text("DAILY_COMMAND='x'\n")
        r = run(root, "collect", "manual", command="x", agent="/usr/bin/false")
        rs = rows(root)
        check("failed write-up exits 1", r.returncode == 1, r.stdout[-200:])
        check("failed write-up records fail",
              len(rs) == 1 and rs[0].split("|")[3] == "fail", str(rs))
        check("lock released after failure",
              not (root / "logs/collect.lock").exists())

    # 3. a second run must not start on top of a live one, and must not write a
    #    row for work it did not do
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        (root / "schedule.conf").write_text("DAILY_COMMAND=''\n")
        lock = root / "logs/collect.lock"
        lock.mkdir(parents=True)
        (lock / "pid").write_text(str(os.getpid()))   # this process is alive
        r = run(root, "collect", "scheduled")
        check("run skipped while one is live", r.returncode == 0)
        check("skipped run writes no row", rows(root) == [], str(rows(root)))
        check("live lock left alone", lock.exists())
        shutil.rmtree(lock)

    # 4. a stale lock from a kill -9 must not block the next run forever
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        (root / "schedule.conf").write_text("DAILY_COMMAND=''\n")
        lock = root / "logs/collect.lock"
        lock.mkdir(parents=True)
        (lock / "pid").write_text("999999")           # nothing is running as this
        r = run(root, "collect", "scheduled")
        check("stale lock is taken over", r.returncode == 0 and len(rows(root)) == 1,
              str(rows(root)))

    # 5. the token is refused unless it is locked to its owner
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        (root / "schedule.conf").write_text("DAILY_COMMAND=''\n")
        home = root / "fakehome"
        (home / ".beatbar").mkdir(parents=True)
        tok = home / ".beatbar/oauth_token"
        tok.write_text("not-a-real-token")
        tok.chmod(0o644)
        r = run(root, "collect", "scheduled", extra={"HOME": str(home)})
        log = (root / "logs/daily-auto.log").read_text()
        check("world-readable token is refused", "refusing oauth_token" in log,
              log[-200:])
        tok.chmod(0o600)
        r = run(root, "collect", "manual", extra={"HOME": str(home)})
        log = (root / "logs/daily-auto.log").read_text()
        check("locked token is accepted",
              log.count("refusing oauth_token") == 1, log[-200:])

    print("")
    print("%d check(s) failed" % len(fails) if fails else "all checks passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
