#!/usr/bin/env zsh
# Per-chat context digest for the work profile. Deterministic, no LLM.
# Rebuilds 5_15/week_NN/YYYY-MM-DD-context.md from today's session transcripts.
set -uo pipefail
source "${0:A:h}/paths.sh"

# $1 optionally names the day (YYYY-MM-DD), so a day the collector never ran on
# can be built afterwards into its own week folder. Defaults to today.
today=${1:-$(date +%F)}
week=week_$(date -j -f '%Y-%m-%d' "$today" +%V 2>/dev/null || date +%V)
out=${FIVE}/$week/$today-context.md
mkdir -p "$(dirname "$out")"

proj=${PROJECTS}
# Every project root under the work directory, not just the top one. One session
# per project is normal (<prefix>-metric-watchdog, <prefix>-bq-msa, ...) and a
# hardcoded list saw none of them, so the digest reported 2 of 10 sessions and
# the weekly report built from it understated the week badly. Roots outside the
# work directory are deliberately NOT matched.
dirs=()
for d in "$proj"/${PROJ_PREFIX}*(N/); do
  [ -d "$d" ] && dirs+=("$d")
done

# user turns that are machinery, not the user. The "You are ..." / "Base
# directory" / "Skill /" lines are skill-body expansions, which arrive as user
# turns in the transcript. "You are handling a /" is anchored on the slash so
# an ordinary typed sentence starting the same way is not swallowed.
noise='^(Auto daily-log|<task-notification|<scheduled-task|<command-message|<command-name|<local-command|<system-reminder|/update_daily|/loop|reply with exactly|Caveat:|You are handling a /|You are the time-gated|Base directory for this skill|Skill /)'

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# strip anything token-shaped before it reaches the file
redact() { sed -E 's/(sk-|ghp_|gho_|ghs_|glpat-|xox[abprs]-|eyJ)[A-Za-z0-9._~+/-]{8,}=*/[redacted]/g; s/[A-Za-z0-9_-]{40,}/[redacted]/g'; }

clock() { # $1 = iso8601 utc, $2 = strftime format
  TZ=Europe/Prague date -j -f '%Y-%m-%dT%H:%M:%S %z' "${1%%.*} +0000" "+$2" 2>/dev/null
}

total=0
for d in "${dirs[@]}"; do
  # Skip anything the user excluded in the app.
  dname="${${d:A:t}#${PROJ_PREFIX}}"; dname="${dname#-}"
  [[ -z "$dname" ]] && dname="${WORKDIR:t}"
  [[ ",${EXCLUDED:-}," == *",${dname},"* ]] && continue
  total=$((total + $(find "$d" -maxdepth 1 -name '*.jsonl' -newermt "$today 00:00:00" ! -newermt "$today 23:59:59" 2>/dev/null | wc -l)))
done
seen=0

kept=0
for d in "${dirs[@]}"; do
  # Skip anything the user excluded in the app.
  dname="${${d:A:t}#${PROJ_PREFIX}}"; dname="${dname#-}"
  [[ -z "$dname" ]] && dname="${WORKDIR:t}"
  [[ ",${EXCLUDED:-}," == *",${dname},"* ]] && continue
  while IFS= read -r f; do
    sid=$(basename "$f" .jsonl)
    # Individually excluded in the app.
    [[ ",${EXCLUDED_CHATS:-}," == *",${sid},"* ]] && continue

    # Was anything actually SAID in this chat today? Selecting by file timestamp
    # alone is not the same question: transcripts get rewritten in bulk without
    # gaining content - measured 2026-08-19, five in the same second, and 21 files
    # touched that day against 3 anyone had typed in. Eight of the eleven sessions
    # in that day's context were files that had merely been rewritten, one of them
    # last spoken to six weeks earlier. The write-up reads this file, so the noise
    # is not free: it arrives as material to be judged.
    #
    # An interactive message carries promptSource "typed" (older builds:
    # origin.kind "human"); a headless run has neither, which is also how the
    # collector's own write-up sessions stop appearing as work.
    #
    # ONLY for today. A past day is rebuilt from transcripts that have since moved
    # on, so applying this there would drop sessions that were real at the time -
    # exactly what the "a past day may only gain" guard below exists to prevent.
    if [[ "$today" == "$(date +%F)" ]]; then
      spoken=$(tail -400 "$f" 2>/dev/null \
               | grep -E '"(promptSource":"typed|kind":"human)"' | tail -1 \
               | grep -oE '"timestamp":"[^"]+"' | head -1 | cut -d'"' -f4)
      [[ "${spoken%%T*}" == "$today" ]] || continue
    fi

    seen=$((seen + 1))
    jq -Rr 'fromjson? | (
      (select(.timestamp) | "TS\t" + .timestamp),
      (select(.type=="user" and (.isSidechain|not) and ((.message.content|type)=="string")) | "U\t" + (.message.content|gsub("[\r\n\t]+";" "))),
      (select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | "TOOL\t" + (.name//"?") + "\t" + (.input.file_path // .input.notebook_path // "")),
      (select(.type=="assistant" and (.isSidechain|not)) | ([.message.content[]? | select(.type=="text") | .text] | join(" ")) | select(length>0) | "A\t" + (gsub("[\r\n\t]+";" ")))
    )' "$f" 2>/dev/null >"$tmp/raw" || continue

    task=$(grep '^U	' "$tmp/raw" | cut -f2- | grep -vE "$noise" | head -1)

    # Named after the chat, not the folder it lives in. Emitted here rather than
    # before the parse because the name only exists once the transcript is read:
    # the session's own title if it has been renamed, else what was asked of it.
    # Field order is phase|detail|done|total and every writer must match it.
    if [ -n "${BEAT_PROGRESS:-}" ]; then
      label=$(grep -ho '"customTitle":"[^"]*"' "$f" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//')
      if [ -z "$label" ]; then
        pname="$(basename "$d")"; pname="${pname#${PROJ_PREFIX}}"; pname="${pname#-}"
        [ -z "$pname" ] && pname="work (general)"
        label=$(printf '%.44s' "${task:-$pname}")
      fi
      printf 'Reading transcripts|%s|%s|%s\n' "$label" "$seen" "$total" > "$BEAT_PROGRESS"
    fi

    [ -z "$task" ] && continue   # automated or empty session

    first_ts=$(grep '^TS	' "$tmp/raw" | head -1 | cut -f2)
    last_ts=$(grep '^TS	' "$tmp/raw" | tail -1 | cut -f2)
    ended=$(grep '^A	' "$tmp/raw" | tail -1 | cut -f2-)
    tools=$(grep -c '^TOOL	' "$tmp/raw")
    files=$(awk -F'\t' '$1=="TOOL" && ($2=="Edit"||$2=="Write"||$2=="NotebookEdit") && $3!="" {print $3}' "$tmp/raw" | awk '!seen[$0]++' | head -10)

    start=$(clock "$first_ts" '%H:%M'); [ "$(clock "$first_ts" '%F')" = "$today" ] || start="$(clock "$first_ts" '%m-%d') $start"
    end=$(clock "$last_ts" '%H:%M')

    {
      printf '## %s  (%s - %s)\n\n' "${sid:0:8}" "${start:-?}" "${end:-?}"
      printf -- '- Task: %s\n' "$(printf '%.200s' "$task")"
      printf -- '- Ended: %s\n' "$(printf '%.300s' "${ended:-(no assistant text)}")"
      printf -- '- Tool calls: %s\n' "$tools"
      if [ -n "$files" ]; then
        printf -- '- Files touched:\n'
        printf '%s\n' "$files" | while IFS= read -r p; do printf '  - %s\n' "$p"; done
      fi
      printf '\n'
    } | redact >"$tmp/sec.$(printf '%06d' "$tools").$first_ts.$sid"
    # Appended after redaction: a project dir name is one long [A-Za-z0-9_-]
    # segment and the token scrubber would eat it. The full path lets a
    # write-up agent open the transcript itself and extract real outcomes
    # instead of paraphrasing the two lines above, which state intent, not
    # what actually happened.
    printf -- '- Transcript: %s\n\n' "$f" >>"$tmp/sec.$(printf '%06d' "$tools").$first_ts.$sid"
    kept=$((kept + 1))
  done < <(find "$d" -maxdepth 1 -name '*.jsonl' -newermt "$today 00:00:00" ! -newermt "$today 23:59:59")
done

if [[ "$EXTRA_SOURCES" == true ]]; then
  extra_count=$(python3 "${BEAT_HOME}/core/scroll.py" extra-sections "$today" "$tmp") || exit 1
  kept=$((kept + extra_count))
fi

# bound the file: 20 busiest sessions, then back to chronological order
capped=""
if [ "$kept" -gt 20 ]; then
  # Ties broken by start time, newest first. Without the second key the order
  # of equal tool counts is whatever sort happens to produce, so the same day
  # rebuilt twice kept a different 20 and the gain-only guard, which compares
  # counts rather than contents, could not see the swap.
  ls "$tmp" | grep '^sec\.' | sort -t. -k2,2nr -k3,3r | tail -n +21 | while read -r x; do rm -f "$tmp/$x"; done
  capped="Showing the 20 busiest sessions of $kept (ranked by tool calls)."
  kept=20
fi

# A past day may only GAIN sessions, never lose them. Rebuilding an earlier day
# selects transcripts by file mtime, and mtimes move: a chat worked on Monday and
# touched again Tuesday no longer looks like Monday's, so a naive rebuild writes
# a thinner file over a good one. (Measured once at 6 sessions down to 1.) The
# morning rebuild that picks up last night's work relies on this guard.
if [[ "$today" != "$(date +%F)" && -f "$out" ]]; then
  had=$(grep -m1 -oE 'Sessions: [0-9]+' "$out" 2>/dev/null | grep -oE '[0-9]+')
  if [[ -n "$had" ]] && (( had > kept )); then
    printf 'SESSIONS|%s\n' "$had"
    exit 0
  fi
fi

{
  printf '# Chat context, %s\n\n' "$today"
  printf 'Generated %s (Europe/Prague). Sessions: %s.\n' "$(TZ=Europe/Prague date '+%Y-%m-%d %H:%M')" "$kept"
  [ -n "$capped" ] && printf '%s\n' "$capped"
  printf '\n'
  ls "$tmp" | grep '^sec\.' | sort -t. -k3 | while read -r x; do cat "$tmp/$x"; done
  printf -- '---\nGenerated by Scrollback (digest.sh), rebuilt hourly.\n'
} >"$out"

echo "$out"
# The count this run actually produced. Callers used to grep it back out of the
# file, which silently returned the PREVIOUS run's number whenever this script
# had crashed, and that stale figure was then recorded as the run's result.
printf 'SESSIONS|%s\n' "$kept"
