#!/usr/bin/env zsh
# Creates the two launchd jobs from scratch, pointing at this checkout, then
# applies the schedule from schedule.conf. Called by the app's first-run setup,
# so a new user never opens a terminal.
set -uo pipefail
source "${0:A:h}/paths.sh"

agents="$HOME/Library/LaunchAgents"
mkdir -p "$agents"

mk() {  # $1 label, $2 script, $3 extra arg
  local plist="$agents/$1.plist"
  /usr/bin/python3 - "$plist" "$1" "$2" "${3:-}" "$LOGDIR" <<'PY'
import plistlib, sys, pathlib
plist, label, script, arg, logdir = sys.argv[1:6]
args = ["/bin/zsh", script] + ([arg] if arg else [])
d = {"Label": label, "ProgramArguments": args, "RunAtLoad": False,
     "StandardOutPath": f"{logdir}/{label}.log",
     "StandardErrorPath": f"{logdir}/{label}.log",
     "StartCalendarInterval": {"Hour": 9, "Minute": 7}}
pathlib.Path(plist).write_bytes(plistlib.dumps(d))
PY
  launchctl unload "$plist" 2>/dev/null
  launchctl load "$plist" 2>/dev/null && print -r -- "  installed $1"
}

mk com.scrollback.daily  "${BEAT_HOME}/collect_now.sh" scheduled
mk com.scrollback.weekly "${BEAT_HOME}/make_515.sh"

BEAT_INSTALLING=1 "${BEAT_HOME}/apply_schedule.sh"
print -r -- "jobs installed"
