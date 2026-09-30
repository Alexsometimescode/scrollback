#!/usr/bin/env zsh
# Lists active chats individually, one per line:
#
#   session_id|project|title|HH:MM|included
#
# "Active" means a session that is open right now. The agent does not keep its
# transcript file open, so a process cannot be mapped to a session id directly.
# What is knowable: how many agents are running in each folder, and which of
# that folder's transcripts were written most recently. Taking that many newest
# transcripts per folder is exact whenever the open sessions are the ones you
# last typed in, which is the normal case.
#
# BEAT_ALL=1 falls back to everything touched today, for the collector itself.
#
# Title is the session's own name when you have renamed it (customTitle, the
# same string Warp shows on the tab), otherwise the first thing you typed.
# "included" is 0 when the session id is in EXCLUDED_CHATS or its whole folder
# is in EXCLUDED.
set -uo pipefail
source "${0:A:h}/paths.sh"

[[ "${1:-}" == "--all" ]] && export BEAT_ALL=1
today="$(date +%F)"

# The panel calls this three times per refresh: directly for the Chats window,
# and again inside scroll_status.sh and projects_list.sh. Each pass shells out to
# lsof per running agent, so it cost ~1s x3. A few seconds of cache makes a
# refresh run it once, and is far shorter than anything a user would notice.
cache="${LOGDIR}/.chats-${BEAT_ALL:-active}-${EXTRA_SOURCES}.cache"
if [[ -f "$cache" ]]; then
  age=$(( $(date +%s) - $(stat -f '%m' "$cache") ))
  (( age < 5 )) && { cat "$cache"; exit 0; }
fi
# Parse before emitting or caching any rows; a parser failure must fail the run.
extra_rows=""
if [[ -n "${BEAT_ALL:-}" && "$EXTRA_SOURCES" == true ]]; then
  extra_rows=$(python3 "${BEAT_HOME}/core/scroll.py" extra-chats) || exit 1
fi
exec > >(tee "$cache")

# how many agents are live in each folder
typeset -A live      # per project folder: how many chats a person has open there
typeset -A exact     # session ids known to be open, no guessing involved
typeset -a cand      # pids to ask lsof about, all at once
if [[ -z "${BEAT_ALL:-}" ]]; then
  for pid in ${(f)"$(pgrep -x claude 2>/dev/null)"}; do
    [[ -z "$pid" ]] && continue
    args=$(ps -o args= -p "$pid" 2>/dev/null)

    # The desktop app names its pty socket after the session, so those are known
    # exactly rather than counted: /tmp/cc-daemon-*/pty/<id>.sock
    if [[ "$args" == *--bg-pty-host* ]]; then
      sid="${${args##*pty/}%%.sock*}"
      [[ -n "$sid" ]] && exact[$sid]=1
      continue
    fi

    # Not chats anyone has open: this app's own write-up step and any scheduled
    # job run headless, and the daemon is not a conversation at all. Counting
    # them overstates how many chats are open, and since the count decides how
    # many of today's transcripts get listed, each one pushes a CLOSED chat into
    # the list. Measured 2026-08-19: twelve processes for seven open tabs.
    [[ "$args" == *" -p "* || "$args" == *" --print "* ]] && continue
    [[ "$args" == *"daemon run"* ]] && continue

    cand+=("$pid")
  done

  # One lsof for every candidate rather than one each: it takes about a second to
  # start, so asking it seven times cost seven seconds on a window that reopens
  # constantly. -Fpn prints a p<pid> line followed by an n<path> line per process.
  if (( $#cand )); then
    typeset pid_cur=""
    for line in ${(f)"$(lsof -a -p ${(j:,:)cand} -d cwd -Fpn 2>/dev/null)"}; do
      case "$line" in
        p*) pid_cur="${line#p}" ;;
        n*) cwd="${line#n}"
            [[ "$cwd" == "$WORKDIR"* ]] || continue
            enc="${cwd//\//-}"
            live[$enc]=$(( ${live[$enc]:-0} + 1 )) ;;
      esac
    done
  fi
fi

noise='^(Auto daily-log|<task-notification|<scheduled-task|<command-message|<command-name|<local-command|<system-reminder|/update_daily|/loop|Caveat:)'

for d in "$PROJECTS"/${PROJ_PREFIX}*(N/); do
  proj="${${d:A:t}#${PROJ_PREFIX}}"; proj="${proj#-}"
  [[ -z "$proj" ]] && proj="${WORKDIR:t}"
  folder_off=0
  [[ ",${EXCLUDED:-}," == *",${proj},"* ]] && folder_off=1

  # newest first, capped at the number of agents live in this folder
  budget=999
  if [[ -z "${BEAT_ALL:-}" ]]; then
    budget=${live[${d:A:t}]:-0}
    (( budget == 0 )) && continue
  fi

  shown=0
  for f in "$d"/*.jsonl(N.om); do
    # Cheap gate first: a file untouched today cannot hold a message typed today,
    # and stat costs nothing next to reading the tail of every transcript in the
    # folder. Without it this took eleven seconds.
    [[ "$(stat -f '%Sm' -t '%F' "$f")" == "$today" ]] || continue

    # The last thing a PERSON typed, not the last line written. A transcript keeps
    # gaining records after its chat is over - a shutdown record, and bulk
    # rewrites that touch five files in one second without adding content - so
    # neither the file's timestamp nor its last line says whether anyone is there.
    # grep rather than jq: this runs over every transcript in the folder and jq
    # parsing the tail of each one took minutes.
    lastmsg=$(tail -400 "$f" 2>/dev/null | grep -E '"(promptSource":"typed|kind":"human)"' | tail -1 \
              | grep -oE '"timestamp":"[^"]+"' | head -1 | cut -d'"' -f4)
    [[ "${lastmsg%%T*}" == "$today" ]] || continue

    sid="${f:t:r}"
    # A session the desktop app is holding open is listed on its own evidence and
    # does not spend the terminal budget; everything else is still capped by how
    # many chats look open.
    if (( ${exact[${sid:0:8}]:-0} == 0 )); then
      (( shown >= budget )) && continue
      shown=$((shown + 1))
    fi

    # A chat counts only if something was actually typed in it. This is the same
    # test the digest applies, deliberately: a session that was opened and named
    # but never used has nothing to collect, and listing it here made every count
    # disagree with the digest by one.
    # Only what a person TYPED. Interactive messages carry promptSource "typed"
    # (older builds: origin.kind "human"); a headless run has neither, so this is
    # what separates a chat from a scheduled job that happens to have a
    # transcript. It also produces a better title: the first thing said, not the
    # prompt some script injected.
    first=$(head -60 "$f" 2>/dev/null | jq -Rr 'fromjson? |
              select(.type=="user" and (.isSidechain|not) and ((.message.content|type)=="string")
                     and (.promptSource=="typed" or .origin.kind=="human")) |
              .message.content | gsub("[\r\n\t]+";" ")' 2>/dev/null \
            | grep -vE "$noise" | head -1)
    [[ -z "$first" ]] && continue

    # Not the app's own runs. The write-up step and the weekly report are started
    # with the commands configured in Settings, so a session whose first message
    # IS one of those was opened by this app, not by a person. They were listed as
    # chats and could even be switched off, which would have excluded a log run
    # rather than a conversation.
    own=0
    for cmd in "${DAILY_COMMAND:-}" "${REPORT_COMMAND:-}"; do
      [[ -n "$cmd" && "$first" == "$cmd"* ]] && own=1
    done
    (( own )) && continue

    # Prefer the name you gave the session; fall back to what you first typed.
    title=$(grep -ho '"customTitle":"[^"]*"' "$f" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//')
    [[ -z "$title" ]] && title=$(print -r -- "$first" | cut -c1-60)
    title="${title//|/ }"

    inc=1
    (( folder_off )) && inc=0
    [[ ",${EXCLUDED_CHATS:-}," == *",${sid},"* ]] && inc=0

    print -r -- "${sid}|${proj}|${title}|$(stat -f '%Sm' -t '%H:%M' "$f")|${inc}"
  done
done

[[ -n "$extra_rows" ]] && print -r -- "$extra_rows"
exit 0
