#!/usr/bin/env zsh
# The single collection runner, used by BOTH the launchd schedule and the
# button. $1 is the trigger ("scheduled" or "manual", default manual).
#
# It records its own outcome in history.log, which is what scroll_status.sh reads.
# launchd's LastExitStatus was the wrong signal: it persists until the next
# scheduled fire, so a successful manual retry could never clear it and the
# menu bar stayed red after the problem was fixed.
#
# Also writes live progress to collect-progress.txt, one line per phase, which
# Scrollback polls while its Try again button is spinning. Format is
# "phase|detail" so the UI never has to parse prose.
set -uo pipefail
source "${0:A:h}/paths.sh"

# launchd starts jobs with a minimal environment and no login keychain, where
# the agent CLI normally keeps its credentials, so a scheduled write-up fails
# with "Not logged in" while the same command works from a terminal. Supply a
# long-lived token instead: `claude setup-token`, stored in
# ~/.beatbar/oauth_token. The PATH covers homebrew (jq) and the CLI itself.
#
# The token is a long-lived credential in plaintext, so it is refused unless
# the file is locked to its owner: one forgotten chmod must not leave it
# readable to everything running as this user.
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ "${BEATBAR_LOCAL_ONLY:-}" != "1" && -r "$HOME/.beatbar/oauth_token" ]]; then
  tokperm=$(stat -f '%Lp' "$HOME/.beatbar/oauth_token" 2>/dev/null)
  if [[ "$tokperm" == "600" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$(< "$HOME/.beatbar/oauth_token")"
  else
    print -r -- "collect: refusing oauth_token, mode ${tokperm:-unknown} (chmod 600 to use it)" >> "$LOG"
  fi
fi

TRIGGER="${1:-manual}"
HIST=${FIVE}/.beats/history.log
LOG=${LOGDIR}/daily-auto.log
PROG=${LOGDIR}/collect-progress.txt
CLAUDE_BIN=${AGENT_CLI}
PROJ=${PROJECTS}

say() { print -r -- "$1" > "$PROG"; }

# Only one collection at a time. Two runs racing both rebuild the same digest and
# both hand the same daily log to an agent, and the agents then overwrite each
# other: today's job log has a run reporting "another /update_daily_auto session
# was writing the same two files while this one ran". Pressing the button twice,
# or the schedule firing during a manual run, was enough to cause it.
#
# mkdir is the atomic part. The pid file only tells a live holder from a stale
# one left behind by a kill -9.
LOCK=${LOGDIR}/collect.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null)"
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    print -r -- "collect ($TRIGGER): skipped, run $holder is still going" >> "$LOG"
    say "Already running|a collection started at $(date -r "$LOCK" +%H:%M) is still going||"
    exit 0
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0   # stale lock from a kill -9
fi
print -r -- $$ > "$LOCK/pid"

# What this run is actually picking up: chats touched since the previous run.
# Recorded alongside the total so the audit list can say "8 scanned, +4 new"
# rather than repeating the same total every hour.
# The last SUCCESSFUL run, not simply the last row. Failed runs record a row now
# too, and measuring from one of those would silently drop every chat that moved
# during the failure: they were never collected, so they are still new.
# Field 6 is when the last good run FINISHED; older rows only have field 1.
prev_row="$(grep '|ok|' "$HIST" 2>/dev/null | tail -1)"
prev_iso="$(print -r -- "$prev_row" | cut -d'|' -f6)"
[[ -z "$prev_iso" ]] && prev_iso="$(print -r -- "$prev_row" | cut -d'|' -f1)"
prev_ep=""
[[ -n "$prev_iso" ]] && prev_ep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$prev_iso" +%s 2>/dev/null)
newn=0
chats=0
outcome=fail
# When this run STARTED. That is what the panel and the audit list show, because
# a row stamped 09:03 for a run that began at 09:00 reads as a late schedule.
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# One exit path for the record, so a run cannot finish without leaving one.
# Three runs on 2026-08-11 were killed mid-write-up (the app restarting takes
# its children with it) and left no row at all, one of them after it had already
# appended to the daily log. The audit list showed 15 runs where 18 had happened.
finish() {
  # start|chats|trigger|outcome|new|end. Both times, because they answer
  # different questions: the start is what a human reads, and the END is what
  # "changed since the last run" has to measure from, or anything that moved
  # while the run was working gets counted again on the next one.
  print -r -- "${started}|${chats}|${TRIGGER}|${outcome}|${newn}|$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HIST"
  rm -rf "$LOCK"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

say "Looking for today's chats|||"

# Folder names only, for the "preparing" line. The chat COUNT deliberately is
# not computed here: this used to count unique project folders and label them
# "chats", which read as 6 when there were 8. The digest owns the count, both
# for its live progress and for the final total, so there is one definition.
today="$(date +%F)"
names=()
for f in "$PROJ"/${PROJ_PREFIX}*/*.jsonl(N.md-1); do
  [[ "$(stat -f '%Sm' -t '%F' "$f")" == "$today" ]] || continue
  d="${${f:h}:t}"
  n="${d#${PROJ_PREFIX}}"; n="${n#-}"
  [[ -z "$n" ]] && n="work (general)"
  names+=("$n")
done
names=(${(ou)names})

# Chats touched since the previous run. Counted from the chat list, not from
# raw files in the folder: the collector spawns its own agent session on every
# run, so those transcripts were being counted as new chats and inflated this to
# 9 on a day when three had actually moved.
if [[ -n "$prev_ep" ]]; then
  chat_rows=$(BEAT_ALL=1 "${BEAT_HOME}/chats_list.sh") || exit 1
  while IFS='|' read -r csid _ _ _ _; do
    [[ -z "$csid" ]] && continue
    [[ "$csid" == codex:* || "$csid" == cursor:* ]] && continue
    cf=$(print -r -- "$PROJ"/${PROJ_PREFIX}*/"${csid}.jsonl"(N) | head -1)
    [[ -n "$cf" && "$(stat -f '%m' "$cf")" -gt "$prev_ep" ]] && newn=$((newn + 1))
  done <<< "$chat_rows"
  if [[ "$EXTRA_SOURCES" == true ]]; then
    extra_new=$(python3 "${BEAT_HOME}/core/scroll.py" extra-changed "$prev_ep") || exit 1
    newn=$((newn + extra_new))
  fi
fi

say "Preparing|${#names} projects: ${(j:, :)names}||"
print -r -- "--- ${TRIGGER} collect $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$LOG"

# Days the collector never ran on. Skipping weekends, or a Mac that was off,
# leaves a day with no digest at all and nothing later goes back for it: the
# digest window is one day wide. Only days with NO context file are built, so
# this can never overwrite one. That guard is the whole difference: rebuilding a
# day that already has a file reads it from today's transcript mtimes, and mtimes
# move, so a chat touched again later drops out and a good digest gets thinner.
# Yesterday is ALWAYS rebuilt, not just when its file is missing: collection stops
# at the end of the working day, so anything typed after the last run was never
# digested. The rebuild is safe because a past day can only gain sessions
# (digest.sh refuses to write a thinner file over a fatter one).
# The other six days are only built if they have no digest at all, which covers a
# weekend or a Mac that was off.
for back in 1 2 3 4 5 6 7; do
  d=$(date -j -v-${back}d +%F 2>/dev/null) || break
  dw="week_$(date -j -f '%Y-%m-%d' "$d" +%V 2>/dev/null)"
  (( back > 1 )) && [[ -f "${FIVE}/${dw}/${d}-context.md" ]] && continue
  print -r -- "--- catching up ${d} ---" >> "$LOG"
  zsh ${BEAT_HOME}/digest.sh "$d" >> "$LOG" 2>&1
done

# Deterministic and offline-safe, so this still succeeds when the API is down.
# Its exit code is CHECKED. It used not to be, and for 12 runs on 2026-08-11 the
# digest crashed on every one while the run still recorded "ok": the outcome was
# taken from the write-up step alone, so a dead collector was invisible.
dout=$(BEAT_TRIGGER="$TRIGGER" BEAT_PROGRESS="$PROG" zsh ${BEAT_HOME}/digest.sh 2>&1)
drc=$?
print -r -- "$dout" >> "$LOG"

if (( drc != 0 )); then
  print -r -- "collect ($TRIGGER): FAILED, the digest could not read your chats (exit $drc)" >> "$LOG"
  say "Failed|could not read your chats, nothing was collected||"
  exit 1
fi

# The count comes from the digest's own output, never from grepping the file it
# writes. Reading it back returned the previous run's number whenever the digest
# had failed, and that stale figure was reported as this run's result.
chats=$(print -r -- "$dout" | grep -oE '^SESSIONS\|[0-9]+' | tail -1 | cut -d'|' -f2)
[[ -z "$chats" ]] && chats=0

# How many of those chats are still open, so the panel can show "9 today · 7
# open" rather than a 9 that reads as "9 open" and is not. Counted once: it
# shells out per project folder.
opennow=$("${BEAT_HOME}/chats_list.sh" 2>/dev/null | grep -c . || print 0)
say "Writing into ${today}.md|starting|${chats}||${opennow}"
cd ${WORKDIR} || exit 1
# The write-up step is optional and configurable. It used to hardcode a skill
# that only exists in one person's setup, so on anyone else's machine every
# hourly run failed here. Left blank, the collection still does its job: the
# digest is deterministic and needs no agent at all.
: ${DAILY_COMMAND=/update_daily_auto}

# The row itself is written by the EXIT trap; these branches only set the verdict.
if [[ -z "$DAILY_COMMAND" ]]; then
  print -r -- "collect ($TRIGGER): digest only, no write-up command set" >> "$LOG"
  outcome=ok
  say "Done|${chats} chats collected||"
  exit 0
fi

# Run it in the background and keep ticking the progress file while it works.
# It used to run in the foreground, so this file was written ONCE for a step that
# takes minutes: nothing on screen changed and the panel looked dead. The clock
# lives here rather than in the app, so what the app renders is always live data
# rather than a timer of its own guessing at it.
# AGENT_FLAGS (paths.conf, default empty) passes extra CLI flags to the
# write-up call. See the README before setting a permission mode here.
"$CLAUDE_BIN" -p ${=AGENT_FLAGS:-} "$DAILY_COMMAND" >> "$LOG" 2>&1 &
apid=$!
t0=$SECONDS
while kill -0 $apid 2>/dev/null; do
  el=$(( SECONDS - t0 ))
  say "Writing into ${today}.md|$(printf '%d:%02d' $((el / 60)) $((el % 60)))|${chats}||${opennow}"
  sleep 2
done
wait $apid
if (( $? == 0 )); then
  print -r -- "collect ($TRIGGER): ok" >> "$LOG"
  outcome=ok
  say "Done|${chats} chats collected||"
  exit 0
else
  print -r -- "collect ($TRIGGER): FAILED, the write-up step could not finish" >> "$LOG"
  say "Failed|the daily log step could not finish||"
  exit 1
fi
