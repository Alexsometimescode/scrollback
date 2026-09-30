#!/usr/bin/env zsh
# Emits one line per day for the last N days (default 7):
#
#   YYYY-MM-DD|collected
#
# collected = chats the digest wrote up that day, read from that day's context
# file. This is the same number the panel and the Chats window show, so there is
# one definition of "a chat" everywhere.
#
# There used to be a second series, "chats that existed that day", drawn as a
# faint backdrop. It was removed because it cannot be computed honestly after
# the fact: a transcript's mtime is only its LAST write, so a chat worked on
# across several days counts only on the final one, which made past days read
# as zero while the collected count for the same day was two.
set -uo pipefail
source "${0:A:h}/paths.sh"

DAYS="${1:-7}"

typeset -A got
for ctx in "$FIVE"/week_*/*-context.md(N); do
  day="${${ctx:t}%-context.md}"
  n=$(grep -oE 'Sessions: [0-9]+' "$ctx" 2>/dev/null | head -1 | grep -oE '[0-9]+')
  [[ -n "$n" ]] && got[$day]=$n
done

for i in $(seq $((DAYS - 1)) -1 0); do
  day="$(date -v-${i}d +%F)"
  print -r -- "${day}|${got[$day]:-0}"
done
