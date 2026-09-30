#!/usr/bin/env zsh
# Reads schedule.conf and rewrites only the StartCalendarInterval of the two
# launchd jobs, then reloads. Everything else in each plist (what it runs,
# where it logs) is left alone, so a stale template here cannot break the jobs.
# A disabled job is unloaded rather than rescheduled.
set -euo pipefail
source "${0:A:h}/paths.sh"

HERE="${0:A:h}"

# Migration off the com.bassam.* labels used up to 1.2.0. A shipped tool should
# not put one person's name in every user's LaunchAgents. Unload before removing,
# or the job keeps running with no plist behind it.
A="$HOME/Library/LaunchAgents"
for old in com.bassam.claude-daily-log com.bassam.claude-weekly-515; do
  if [[ -f "$A/$old.plist" ]]; then
    launchctl unload "$A/$old.plist" 2>/dev/null
    rm -f "$A/$old.plist"
    print -r -- "  migrated away from $old"
  fi
done
for old in com.beatbar.daily com.beatbar.weekly; do
  new="${old/beatbar/scrollback}"
  if [[ -f "$A/$old.plist" && ! -f "$A/$new.plist" ]]; then
    launchctl unload "$A/$old.plist" 2>/dev/null
    mv "$A/$old.plist" "$A/$new.plist"
    /usr/bin/plutil -replace Label -string "$new" "$A/$new.plist" 2>/dev/null || true
    print -r -- "  migrated $old → $new"
  fi
done
# BEAT_INSTALLING stops the recursion: install_jobs.sh ends by calling this.
if [[ ! -f "$A/com.scrollback.daily.plist" && -z "${BEAT_INSTALLING:-}" ]]; then
  BEAT_INSTALLING=1 "${HERE}/install_jobs.sh"
  exit 0
fi
# Values come in already parsed by paths.sh, which sources the file. Parsing it
# a second time here by hand is what broke when the values became quoted.
export daily_enabled daily_start daily_end daily_every daily_minute daily_final daily_weekdays_only
export weekly_enabled weekly_day weekly_time
python3 <<'PY'
import plistlib, subprocess, os, pathlib

conf = os.environ
on = lambda k: conf.get(k, 'true').lower() == 'true'
minute = int(conf['daily_minute'])
start, end = int(conf['daily_start']), int(conf['daily_end'])
every = max(1, int(conf['daily_every']))
daily = [{'Hour': h, 'Minute': minute} for h in range(start, end + 1, every)]

# One optional last sweep, e.g. 17:59. The write-up command can refuse to run
# outside its own window (/update_daily_auto gates on H < 18), so a fire exactly
# on the boundary collects the digest and then has its write-up refused: the last
# hour of the day never reaches that day's log. This lands just inside it.
final = conf.get('daily_final', '').strip()
if final:
    fh, fm = (int(x) for x in final.split(':'))
    daily.append({'Hour': fh, 'Minute': fm})

# Weekdays only: launchd has no "not at the weekend", so each time is expanded
# into one entry per weekday. Mon=1 .. Fri=5.
weekdays = on('daily_weekdays_only')
if weekdays:
    daily = [dict(e, Weekday=d) for d in range(1, 6) for e in daily]

wh, wm = (int(x) for x in conf['weekly_time'].split(':'))
weekly = {'Weekday': int(conf['weekly_day']), 'Hour': wh, 'Minute': wm}

jobs = [
    ('com.scrollback.daily', daily, on('daily_enabled'),
     f'{start:02d}:{minute:02d} to {end:02d}:{minute:02d} every {every}h'
     + (f' plus {final}' if final else '') + (', weekdays only' if weekdays else '') + f', {len(daily)} runs'),
    ('com.scrollback.weekly', weekly, on('weekly_enabled'),
     f'day {weekly["Weekday"]} at {wh:02d}:{wm:02d}'),
]

agents = pathlib.Path.home() / 'Library/LaunchAgents'
for label, interval, enabled, human in jobs:
    p = agents / f'{label}.plist'
    if not p.exists():
        print(f'  skip  {label}: no plist'); continue
    subprocess.run(['launchctl', 'unload', str(p)], capture_output=True)
    if not enabled:
        print(f'  off   {label}'); continue
    d = plistlib.loads(p.read_bytes())
    d['StartCalendarInterval'] = interval
    p.write_bytes(plistlib.dumps(d))
    r = subprocess.run(['launchctl', 'load', str(p)], capture_output=True, text=True)
    print(f'  {"on " if r.returncode == 0 else "FAIL"}   {label}: {human}')
PY
