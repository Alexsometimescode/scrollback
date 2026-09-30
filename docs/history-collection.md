# On-demand chat collection

Requested flow: a button opens a date-range picker with Claude, Codex and Cursor
switches. Find chats opens a separate window with per-chat selection, Collect
selected and Collect all. Both range endpoints are included in local time.

Discovery is read-only. Collection writes a uniquely named Markdown file beneath
the configured output folder's collections directory. It never overwrites daily
notes or changes source exclusions, schedules, transcripts or databases.

Validation covers empty agent selection, inverted dates, a maximum 366-day range,
empty chat selection, stale/missing selected chats, async errors, no results,
and repeated collection without overwriting existing files.
