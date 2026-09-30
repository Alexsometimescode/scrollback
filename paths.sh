#!/usr/bin/env zsh
# Sourced by every script. Defaults are sensible; paths.conf overrides them.
: ${SCROLLBACK_HOME:="${BEAT_HOME:-${${(%):-%x}:A:h}}"}
: ${BEAT_HOME:="$SCROLLBACK_HOME"}   # legacy alias; %x is this file when sourced
export SCROLLBACK_HOME BEAT_HOME
# Config lives in the user's home, never inside the app bundle: a bundle in
# /Applications is not reliably writable and gets replaced on upgrade.
: ${BEAT_CONF:="$HOME/.beatbar/paths.conf"}
[[ -f "$BEAT_CONF" ]] && source "$BEAT_CONF"
[[ -f "${BEAT_HOME}/paths.conf" ]] && source "${BEAT_HOME}/paths.conf"

# The app writes everything it owns to schedule.conf: the window and interval,
# but also EXCLUDED, EXCLUDED_CHATS and the two commands. Only the schedule keys
# were ever read back, so exclusions and commands set in the UI never reached
# the scripts at all. Sourced here so there is one config namespace.
[[ -f "${BEAT_HOME}/schedule.conf" ]] && source "${BEAT_HOME}/schedule.conf" 2>/dev/null

# Defaults for everything Settings owns, so no consumer has to invent its own.
# This sourcing is the ONLY parser for schedule.conf. Two scripts used to parse
# it again by hand, and when the values became quoted (the command fields hold
# sentences) both broke silently: the status read every schedule as OFF while it
# was running, and apply_schedule.sh read every job as disabled, which would have
# unloaded the lot had an int() not crashed first.
: ${daily_enabled:=true}
: ${daily_start:=9}
: ${daily_end:=18}
: ${daily_every:=1}
: ${daily_minute:=7}
: ${daily_weekdays_only:=false}   # skip Saturday and Sunday
: ${daily_final:=}          # optional last sweep, HH:MM, before a write-up gate closes
: ${weekly_enabled:=true}
: ${weekly_day:=5}
: ${weekly_time:=18:15}
: ${notify_on_failure:=true}
: ${WORKDIR:="$HOME/Work"}
: ${PROJECTS:="$HOME/.claude/projects"}
: ${AGENT_CLI:="$HOME/.local/bin/claude"}
: ${LOGDIR:="$HOME/.claude/logs"}
: ${DAILY_COMMAND="/update_daily_auto"}   # no colon: an empty value means "digest only"
: ${FIVE:="${WORKDIR}/5_15"}
# Agents name a session folder after the working directory with / turned into -,
# so /Users/jane/Work becomes -Users-jane-Work. Derived, never hardcoded.
: ${PROJ_PREFIX:="${WORKDIR//\//-}"}
: ${HIST:="${FIVE}/.beats/history.log"}
: ${PROG:="${LOGDIR}/collect-progress.txt"}
: ${LOG:="${LOGDIR}/daily-auto.log"}
mkdir -p "$LOGDIR" "$(dirname "$HIST")" 2>/dev/null

# Additional local transcripts are opt-in because the digest is sent to the
# configured write-up agent when collection runs.
: ${EXTRA_SOURCES:=true}
: ${CODEX_SESSIONS:="$HOME/.codex/sessions"}
: ${CURSOR_PROJECTS:="$HOME/.cursor/projects"}
export EXTRA_SOURCES CODEX_SESSIONS CURSOR_PROJECTS

: ${CURSOR_DB:="$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"}
: ${CURSOR_INCLUDE_UNSCOPED:=true}
export CURSOR_DB CURSOR_INCLUDE_UNSCOPED
