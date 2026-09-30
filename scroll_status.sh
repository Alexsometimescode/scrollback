#!/usr/bin/env zsh
# scroll_status.sh - plain-language health of the 5/15 collection.
#
# Reads real artifacts, not a ledger, because a ledger can say "success" while
# nothing was written. Line 1 is the summary (Scrollback's menu-bar text); the
# rest is the menu.
#
#   ./scroll_status.sh          human output
#   ./scroll_status.sh --check  exit 1 if anything is unhealthy

set -uo pipefail
source "${0:A:h}/paths.sh"

HERE="${0:A:h}"
FIVE="${FIVE}"
# No local config parser: paths.sh sourced schedule.conf and defaulted every key.
week="week_$(date +%V)"
today="$(date +%Y-%m-%d)"
friday="$(date -v-fri +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
# Every unhealthy condition goes in here and nowhere else. `bad` is derived from
# it at the end, so the headline and the PROBLEM lines cannot disagree.
# They used to: the app turns the menu bar red and notifies off PROBLEM lines
# alone, while three conditions set `bad` silently, including a FAILED RUN. A
# failure set the headline and never reached the icon or the notification.
problems=()

cfg() { print -r -- "${(P)1}"; }   # the value paths.sh already sourced

# --- Daily: the per-chat digest is the artifact it always writes.
digest="${FIVE}/${week}/${today}-context.md"
if [[ -f "$digest" ]]; then
  sessions="$(grep -c '^## ' "$digest" 2>/dev/null || print 0)"
  daily="collected ${sessions} chat(s) at $(date -r "$digest" +%H:%M)"
elif [[ "$daily_enabled" != "true" ]]; then
  daily="collection is off"
elif [[ "$daily_weekdays_only" == "true" && "$(date +%u)" -gt 5 ]]; then
  daily="not scheduled today"          # weekend, nothing is due
elif (( $(date +%s) < $(date -j -f '%Y-%m-%d %H:%M:%S' "${today} $(printf '%02d:%02d' $daily_start $daily_minute):00" +%s 2>/dev/null || print 0) + 900 )); then
  # Before the first fire of the day nothing has failed. Saying NOTHING
  # COLLECTED at 02:00 turned the bar red for seven hours every morning, which
  # is the same false alarm the Friday check had.
  daily="first run at $(printf '%02d:%02d' $daily_start $daily_minute)"
else
  daily="NOTHING COLLECTED TODAY"
  problems+=("No chats have been collected today. The digest file was never written.")
fi

# --- Weekly: the 5/15 for the most recent Friday.
# Matched by the date, not by a name. It used to look for one specific person's
# filename, so on anyone else's machine the weekly check could never pass.
# The folder comes from that Friday's own week number, not today's. On a Monday
# the two differ, and it used to look for last Friday's report inside this
# week's folder, then call it "not due" and forget it. A missed 5/15 stayed
# missed and the bar went green again.
fweek="week_$(date -j -f '%Y-%m-%d' "$friday" +%V 2>/dev/null || date +%V)"
report=""
for f in ${FIVE}/${fweek}/*${friday}*.md(N); do
  b="${f:t}"
  [[ "$b" == *5-15* || "$b" == *5_15* || "$b" == *515* ]] && { report="$f"; break; }
done
if [[ -n "$report" && -f "$report" ]]; then
  weekly="written $(date -r "$report" '+%a %d %b %H:%M')"
elif [[ ! -d "${FIVE}/${fweek}" ]]; then
  weekly="no work logged that week"     # nothing to report on; a fresh install
elif [[ "$weekly_enabled" != "true" ]]; then
  # Nothing is going to write it on its own, so it cannot be late.
  weekly="not written for ${friday}"
elif (( $(date +%s) < $(date -j -f '%Y-%m-%d %H:%M:%S' "${friday} ${weekly_time}:00" +%s 2>/dev/null || print 0) + 900 )); then
  # Not late, just not due. The weekly job runs at weekly_time, so calling the
  # report missing before then turned the menu bar red from midnight every
  # Friday for something nothing could have done yet.
  weekly="due today at ${weekly_time}"
else
  weekly="MISSING for ${friday}"
  problems+=("No 5/15 written for ${friday}. Open Scrollback and use the weekly button.")
fi

# The last recorded run outcome, whoever triggered it. launchd's LastExitStatus
# is deliberately not used: it sticks until the next scheduled fire, so a
# successful manual retry could never clear it.
HIST=${FIVE}/.beats/history.log
last_outcome="$(tail -1 "$HIST" 2>/dev/null | cut -d'|' -f4)"
last_trigger="$(tail -1 "$HIST" 2>/dev/null | cut -d'|' -f3)"
d_exit=0
[[ "$last_outcome" == "fail" ]] && { d_exit=1; problems+=("The last run (${last_trigger:-manual}) failed. Nothing was collected that time."); }
w_exit=0

wd=$(cfg weekly_day)
case "$wd" in 1) wdn=Monday;; 2) wdn=Tuesday;; 3) wdn=Wednesday;; 4) wdn=Thursday;; 5) wdn=Friday;; 6) wdn=Saturday;; *) wdn=Sunday;; esac

# --- Runs that never happened. A crashed run leaves a fail row; a run that never
# fired leaves nothing at all, and "nothing" used to read as healthy. The Mac
# asleep, the job unloaded, the laptop shut: all silent until now.
missed=0
# Nothing is expected on a day it does not run, so a weekend must not report ten
# missed runs. dow: 1=Mon .. 7=Sun.
dow=$(date +%u)
if [[ "$daily_enabled" == "true" && ! ( "$daily_weekdays_only" == "true" && "$dow" -gt 5 ) ]]; then
  now=$(date +%s)
  last_ok_ep=0
  li="$(grep '|ok|' "$HIST" 2>/dev/null | tail -1 | cut -d'|' -f1)"
  [[ -n "$li" ]] && last_ok_ep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$li" +%s 2>/dev/null || print 0)
  h=$daily_start
  while (( h <= daily_end )); do
    fe=$(date -j -f '%Y-%m-%d %H:%M:%S' "${today} $(printf '%02d:%02d' $h $daily_minute):00" +%s 2>/dev/null || print 0)
    # 15 minutes of grace: a run takes minutes, so the newest fire may still be going.
    (( fe > 0 && now - fe > 900 && last_ok_ep < fe )) && missed=$((missed + 1))
    h=$(( h + daily_every ))
  done
  # The optional last sweep is a fire like any other; missing it loses the tail
  # of the day, which is the whole reason it exists.
  if [[ -n "$daily_final" ]]; then
    fe=$(date -j -f '%Y-%m-%d %H:%M:%S' "${today} ${daily_final}:00" +%s 2>/dev/null || print 0)
    (( fe > 0 && now - fe > 900 && last_ok_ep < fe )) && missed=$((missed + 1))
  fi
  (( missed )) && problems+=("${missed} scheduled run(s) did not happen today. The Mac was probably asleep or off at the time.")
fi

# --- Chats this tool does not look at. Not an error, but never silent: a
# collector that quietly ignores where the work happened is the bug this whole
# tool exists to catch.
outside=0
for pd in "$PROJECTS"/*/; do
  b="${${pd:A}:t}"
  [[ "$b" == ${PROJ_PREFIX}* ]] && continue
  n=$(find "$pd" -maxdepth 1 -name '*.jsonl' -newermt "${today} 00:00:00" 2>/dev/null | wc -l | tr -d ' ')
  outside=$((outside + n))
done

logf=${LOGDIR}/daily-auto.log
lastrun_bad=0
lasterr=""
if [[ -f "$logf" ]] && tail -1 "$logf" | grep -qiE "error|ENOTFOUND"; then
  lastrun_bad=1
  lasterr="$(tail -1 "$logf" | cut -c1-90)"
  case "$lasterr" in
    *ENOTFOUND*) lasterr="No network when it ran. Nothing was collected that hour." ;;
    "Execution error") lasterr="The run stopped part-way. Usually the API was unreachable." ;;
  esac
  problems+=("$lasterr")
fi

# The digest keeps only the 20 busiest sessions if a day runs very long. Loud,
# because past that line chats really are being dropped.
if [[ -f "$digest" ]] && grep -q '^Showing the ' "$digest"; then
  problems+=("$(grep -m1 '^Showing the ' "$digest") The rest were left out of today's digest.")
fi

bad=${#problems}

(( bad )) && print -r -- "5/15 collection: NEEDS ATTENTION" || print -r -- "5/15 collection: healthy"
print -r -- "---"
print -r -- "Checked just now: $(date '+%a %d %b, %H:%M')"
print -r -- ""
print -r -- "What this does: every run reads your configured chats, including"
print -r -- "closed ones, and writes what each was about into the daily log."
print -r -- "Friday's run turns the week of those into your 5/15 report."
print -r -- ""
if [[ "$(cfg daily_enabled)" == "true" ]]; then
  ev="$(cfg daily_every)"; [[ -z "$ev" ]] && ev=1
  d_when="every ${ev}h, $(printf '%02d:%02d' "$(cfg daily_start)" "$(cfg daily_minute)") to $(printf '%02d:%02d' "$(cfg daily_end)" "$(cfg daily_minute)")"
  [[ -n "$daily_final" ]] && d_when="${d_when}, plus ${daily_final}"
  [[ "$daily_weekdays_only" == "true" ]] && d_when="${d_when}, weekdays only"
else
  d_when="OFF"
fi
[[ "$(cfg weekly_enabled)" == "true" ]] && w_when="${wdn} $(cfg weekly_time)" || w_when="when you press the button"

# When the next collection actually happens. After the last fire of the day there
# is nothing more until the morning, and saying so is the difference between
# "finished" and "did it stop working?".
nextrun=""
if [[ "$daily_enabled" == "true" ]]; then
  nowep=$(date +%s)
  h=$daily_start
  while (( h <= daily_end )); do
    fe=$(date -j -f '%Y-%m-%d %H:%M:%S' "${today} $(printf '%02d:%02d' $h $daily_minute):00" +%s 2>/dev/null || print 0)
    if (( fe > nowep )) && [[ ! ( "$daily_weekdays_only" == "true" && "$(date +%u)" -gt 5 ) ]]; then
      nextrun="today at $(printf '%02d:%02d' $h $daily_minute)"; break
    fi
    h=$(( h + daily_every ))
  done
  if [[ -z "$nextrun" ]]; then
    # Nothing left today. Find the next day it runs at all.
    for ahead in 1 2 3; do
      wd=$(date -j -v+${ahead}d +%u)
      [[ "$daily_weekdays_only" == "true" && "$wd" -gt 5 ]] && continue
      when=$(date -j -v+${ahead}d '+%A')
      (( ahead == 1 )) && when="tomorrow"
      nextrun="${when} at $(printf '%02d:%02d' $daily_start $daily_minute)"
      break
    done
  fi
fi

print -r -- "Daily digest    ${daily}"
print -r -- "  runs          ${d_when}"
[[ -n "$nextrun" ]] && print -r -- "  next run      ${nextrun}"
print -r -- "  last run      $([[ "$d_exit" == "0" ]] && print "finished (${last_trigger:-none})" || print "FAILED (${last_trigger})")"
print -r -- ""
print -r -- "Weekly 5/15     ${weekly}"
print -r -- "  runs          ${w_when}"
print -r -- "  scheduled     Friday, on its own"



for prob in "${problems[@]}"; do
  print -r -- ""
  print -r -- "PROBLEM: ${prob}"
done
(( outside )) && { print -r -- ""; print -r -- "NOTE: ${outside} chat(s) today in folders outside ${WORKDIR}. Not collected, by design."; }

# How much has changed since the last run: chats touched after that moment,
# out of today's chats. Zero means the last run is still current.
lastrow="$(tail -1 "$HIST" 2>/dev/null)"
lastiso="$(print -r -- "$lastrow" | cut -d'|' -f6)"          # finished-at
[[ -z "$lastiso" ]] && lastiso="$(print -r -- "$lastrow" | cut -d'|' -f1)"
# Count the same chats the Chats window lists, not raw transcript files. The
# raw count included the collector's own headless runs, so the panel said
# "8 of 18" while the Chats window said "8 of 8" for the same day.
newn=0; totn=0
lastep=""
[[ -n "$lastiso" ]] && lastep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$lastiso" +%s 2>/dev/null)
chat_rows=$(BEAT_ALL=1 "${BEAT_HOME}/chats_list.sh") || exit 1
while IFS='|' read -r sid proj title tm inc; do
  [[ -z "$sid" ]] && continue
  totn=$((totn + 1))
  [[ "$sid" == codex:* || "$sid" == cursor:* ]] && continue
  f=$(print -r -- "$PROJECTS"/${PROJ_PREFIX}*/"${sid}.jsonl"(N) | head -1)
  [[ -n "$lastep" && -n "$f" && "$(stat -f '%m' "$f")" -gt "$lastep" ]] && newn=$((newn + 1))
done <<< "$chat_rows"   # counts must match what was collected
if [[ -n "$lastep" && "$EXTRA_SOURCES" == true ]]; then
  extra_new=$(python3 "${BEAT_HOME}/core/scroll.py" extra-changed "$lastep") || exit 1
  newn=$((newn + extra_new))
fi
print -r -- "CHANGED|${newn}|${totn}"

todayfile="${FIVE}/${week}/${today}.md"
print -r -- ""
if [[ -f "$todayfile" ]]; then
  print -r -- "Today's file    ${today}.md  ($(du -h "$todayfile" | cut -f1), $(grep -c '^- ' "$todayfile" 2>/dev/null) entries)"
else
  print -r -- "Today's file    not written yet"
fi

[[ "${1:-}" == "--check" ]] && exit $(( bad ? 1 : 0 ))
exit 0
