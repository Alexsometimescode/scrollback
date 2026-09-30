#!/usr/bin/env zsh
# Lists the folders worth showing a switch for, one per line:
#
#   name|chats_today|included
#
# Derived from chats_list.sh rather than counted separately. Counting files here
# gave a different answer to the Chats window for the same folder: 14 against 2,
# because it included the collector's own headless runs. One source, one number.
#
# A folder only appears if it has chats today, or if it is excluded: an excluded
# folder must stay visible or you could never switch it back on.
set -uo pipefail
source "${0:A:h}/paths.sh"

typeset -A n
while IFS='|' read -r sid proj title tm inc; do
  [[ -z "$proj" ]] && continue
  n[$proj]=$(( ${n[$proj]:-0} + 1 ))
done < <(BEAT_ALL=1 "${BEAT_HOME}/chats_list.sh")   # folders reflect the day, not the moment

# excluded folders are listed even with nothing today
for e in ${(s:,:)EXCLUDED:-}; do
  [[ -n "$e" ]] && : ${n[$e]:=0}
done

for name in ${(ok)n}; do
  inc=1
  [[ ",${EXCLUDED:-}," == *",${name},"* ]] && inc=0
  print -r -- "${name}|${n[$name]}|${inc}"
done
