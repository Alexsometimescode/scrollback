#!/usr/bin/env zsh
# Opens a terminal in this week's folder and runs REPORT_COMMAND there.
#
# Always external and always interactive: writing the report is a conversation,
# not a batch job, so a headless mode that produced a file nobody watched was
# the wrong shape. Available any day; refusing before Friday was a rule with no
# reason behind it.
set -uo pipefail
source "${0:A:h}/paths.sh"

# The week folder is appended to whatever this is, so it reads as one
# instruction. Plain words by default rather than a slash command: a command
# only exists if the user happens to have defined one, prose works anywhere.
: ${REPORT_COMMAND:="Write this week's 5/15 report from the daily logs and chat digests in"}

week="week_$(date +%V)"
folder="${FIVE}/${week}"
mkdir -p "$folder"

# The week folder is passed to the command, not just used as the working
# directory. A 5/15 skill resolves the week itself from today's date, which is
# wrong every time the report is written for a week other than the current one,
# and a cwd is not something a skill reads.
prompt="${REPORT_COMMAND} ${folder}"

# Everything the terminal has to run goes into one script, so neither Warp's
# YAML nor AppleScript's string ever carries a quote of its own. They each just
# execute a path. The default prompt contains an apostrophe ("this week's"),
# which broke the AppleScript path silently: the shell saw an unterminated
# quote and sat there waiting for input, with the window open and nothing in it.
runner="${LOGDIR}/weekly-report.sh"
{
  print -r -- "#!/bin/sh"
  print -r -- "cd ${(q)folder} || exit 1"
  print -r -- "exec ${(q)AGENT_CLI} ${(q)prompt}"
} > "$runner"
chmod +x "$runner"

print -r -- "Opening terminal|${week} · ${folder}||" > "$PROG"
# Warp if it is installed, Terminal otherwise. Warp has no `do script`, so it
# gets the command via a launch configuration file, which is its supported way
# of opening a tab with something already running.
if [[ -d /Applications/Warp.app ]]; then
    conf="$HOME/.warp/launch_configurations"
    mkdir -p "$conf"
    # `name` MUST equal what warp://launch/<x> asks for. Warp resolves the config
    # by this field, not by the file name, and a miss is silent: `open` still
    # returns 0, Warp comes to the front, and nothing runs. It read "Scrollback
    # weekly report" against warp://launch/scrollback-weekly, so the Friday report
    # never once ran on its own.
    cat > "$conf/scrollback-weekly.yaml" <<YAML
---
name: scrollback-weekly
windows:
  - tabs:
      - layout:
          cwd: ${folder}
          commands:
            - exec: ${runner}
YAML
    open "warp://launch/scrollback-weekly" 2>/dev/null || open -a Warp "$folder"
else
    /usr/bin/osascript <<APPLESCRIPT
tell application "Terminal"
activate
do script "${runner}"
end tell
APPLESCRIPT
fi
print -r -- "Done|${week} open in a terminal · ${folder}||" > "$PROG"
exit 0
