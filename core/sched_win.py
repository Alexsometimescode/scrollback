#!/usr/bin/env python3
"""Task Scheduler jobs, the Windows twin of apply_schedule.sh.

UNVERIFIED. Written without a Windows machine to run it on. Every claim about
Task Scheduler behaviour below is design knowledge, not something observed, and
`scroll.py probe` plus one afternoon on a real laptop settles it. Nothing here
runs on macOS: the Mac keeps launchd.

    python3 core/sched_win.py apply      write the tasks from schedule.conf
    python3 core/sched_win.py status     what Task Scheduler actually has
    python3 core/sched_win.py remove     take them away

Two shapes worth knowing, both better than launchd:

- launchd has no "every hour, weekdays only", so apply_schedule.sh expands the
  window into one StartCalendarInterval entry per hour per weekday, up to 50.
  Task Scheduler does it with ONE trigger plus a repetition.
- A disabled task stays disabled across a reboot. launchd reloads everything in
  ~/Library/LaunchAgents at login, so `launchctl unload` is not "off": the
  weekly report was switched off on 2026-08-17 and fired anyway on Friday
  2026-08-21 at 18:15. The equivalent bug cannot happen here.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scroll import Conf, WINDOWS  # noqa: E402

DAILY, WEEKLY = "Scrollback Daily", "Scrollback Weekly"


def ps(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True, text=True)


def action(conf: Conf, arg: str) -> str:
    """pythonw, never python.

    pythonw.exe has no console at all, so a scheduled run cannot flash a window
    every hour. That was the single most-complained-about thing about the
    PowerShell era of this automation, and it is why the core is Python: with
    powershell.exe the only fixes are a wscript.vbs wrapper or a hidden-window
    flag that does not reliably work for scheduled tasks.
    """
    exe = Path(sys.executable)
    pyw = exe.with_name("pythonw.exe")
    if not pyw.exists():
        pyw = exe
    script = Path(__file__).resolve().parent / "scroll.py"
    return "'%s' -Argument '\"%s\" %s' -WorkingDirectory '%s'" % (
        pyw, script, arg, conf.beat_home)


def daily_trigger(conf: Conf) -> str:
    start = conf.num("daily_start", 9)
    end = conf.num("daily_end", 18)
    every = max(1, conf.num("daily_every", 1))
    minute = conf.num("daily_minute", 7)
    hours = end - start + 1
    days = ("Monday,Tuesday,Wednesday,Thursday,Friday"
            if conf.on("daily_weekdays_only")
            else "Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday")
    # One trigger, one repetition. The whole 50-entry expansion the Mac needs.
    t = ("$t1 = New-ScheduledTaskTrigger -Weekly -DaysOfWeek %s -At %02d:%02d\n"
         "$rep = (New-ScheduledTaskTrigger -Once -At %02d:%02d "
         "-RepetitionInterval (New-TimeSpan -Hours %d) "
         "-RepetitionDuration (New-TimeSpan -Hours %d)).Repetition\n"
         "$t1.Repetition = $rep\n"
         "$trig = @($t1)\n" % (days, start, minute, start, minute, every, hours))
    # The optional last sweep. A write-up command can refuse to run outside its
    # own window (/update_daily_auto gates on H < 18), so a fire exactly on the
    # boundary collects the digest and then has its write-up refused: the last
    # hour of the day never reaches that day's log. This lands just inside it.
    final = conf["daily_final"].strip()
    if final:
        fh, fm = (int(x) for x in final.split(":"))
        t += ("$trig += New-ScheduledTaskTrigger -Weekly -DaysOfWeek %s "
              "-At %02d:%02d\n" % (days, fh, fm))
    return t


def weekly_trigger(conf: Conf) -> str:
    day = {1: "Monday", 2: "Tuesday", 3: "Wednesday", 4: "Thursday",
           5: "Friday", 6: "Saturday", 7: "Sunday"}.get(conf.num("weekly_day", 5),
                                                        "Friday")
    hh, mm = (int(x) for x in (conf["weekly_time"] or "18:15").split(":"))
    return ("$trig = @(New-ScheduledTaskTrigger -Weekly -DaysOfWeek %s "
            "-At %02d:%02d)\n" % (day, hh, mm))


SETTINGS = (
    # Task Scheduler defaults BOTH of these to true. On a laptop that means
    # scheduled runs silently do not fire whenever it is unplugged, and silence
    # reading as health is the exact bug this tool exists to catch. The
    # missed-run detector in `scroll.py status` is the backstop if a Windows
    # update ever resets them.
    "$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries "
    "-DontStopIfGoingOnBatteries -StartWhenAvailable "
    "-ExecutionTimeLimit (New-TimeSpan -Hours 2) "
    "-MultipleInstances IgnoreNew\n"
    # Interactive, so the task runs in the user's own session: it needs to see
    # %USERPROFILE%\.claude and the agent's credentials, and session 0 sees
    # neither. No stored password, and no admin rights to register it.
    "$pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME "
    "-LogonType Interactive -RunLevel Limited\n"
)


def register(conf: Conf, name: str, arg: str, trigger: str, enabled: bool):
    script = (
        "$ErrorActionPreference = 'Stop'\n"
        "$act = New-ScheduledTaskAction -Execute %s\n"
        "%s%s"
        "Register-ScheduledTask -TaskName '%s' -Action $act -Trigger $trig "
        "-Settings $set -Principal $pri -Force | Out-Null\n"
        % (action(conf, arg), trigger, SETTINGS, name))
    if not enabled:
        # Disabled, not deleted. It survives a reboot as disabled, and the
        # settings stay put for whenever it is switched back on.
        script += "Disable-ScheduledTask -TaskName '%s' | Out-Null\n" % name
    r = ps(script)
    print("  %-14s %s" % (name, "on" if enabled else "off (disabled)"
                          if r.returncode == 0 else "FAILED"))
    if r.returncode != 0:
        print("    %s" % (r.stderr.strip().splitlines() or ["unknown error"])[0])
    return r.returncode


def apply(conf: Conf) -> int:
    rc = register(conf, DAILY, "collect scheduled", daily_trigger(conf),
                  conf.on("daily_enabled"))
    rc |= register(conf, WEEKLY, "weekly", weekly_trigger(conf),
                   conf.on("weekly_enabled"))
    return rc


def status(conf: Conf) -> int:
    """What Task Scheduler HAS, not what the config says it should have.

    scroll_status.sh distrusts ledgers for the same reason: a config saying a job
    is on proves nothing about whether anything is registered to run it.
    """
    r = ps("Get-ScheduledTask -TaskName 'Scrollback *' -ErrorAction SilentlyContinue"
           " | Select-Object TaskName,State | Format-Table -AutoSize | Out-String")
    print(r.stdout.strip() or "  no Scrollback tasks registered")
    return 0


def remove(conf: Conf) -> int:
    for n in (DAILY, WEEKLY):
        ps("Unregister-ScheduledTask -TaskName '%s' -Confirm:$false "
           "-ErrorAction SilentlyContinue" % n)
        print("  removed %s" % n)
    return 0


if __name__ == "__main__":
    if not WINDOWS:
        sys.exit("sched_win.py is for Windows. The Mac uses apply_schedule.sh.")
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    fn = {"apply": apply, "status": status, "remove": remove}.get(cmd)
    if not fn:
        sys.exit(__doc__)
    sys.exit(fn(Conf()))
