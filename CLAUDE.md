# CLAUDE.md — Scrollback

## What this is

A menu bar app that shows how much of your AI chat work is actually being
captured into the daily logs. Swift, no Xcode project, no dependencies. Shipped
privately at `github.groupondev.com/Alexsometimescode/scrollback`.

## The rule that matters most

**One definition of "a chat", everywhere.** A chat counts when something was
typed in it. The digest, the panel headline, the 7-day chart, the audit list and
the Chats window must all report the same number for the same day.

Most bugs here have been two surfaces counting differently: raw transcript files
versus real chats, the collector's own headless sessions counted as work, a
folder count computed separately from the chat list. Before changing anything
that counts, run these and confirm the last two agree:

```
./scroll_status.sh | head -1              # 5/15 collection: healthy
./chats_list.sh | wc -l                 # the sessions open right now
BEAT_ALL=1 ./chats_list.sh | wc -l      # every chat today; must equal the digest
grep -m1 -oE 'Sessions: [0-9]+' <five_15>/week_$(date +%V)/$(date +%F)-context.md
```

## The second rule: a run must not be able to lie about itself

Every step's exit code is checked, and the history row is written by an `EXIT`
trap so no path can skip it. Both exist because on 2026-08-11 the digest crashed
on 12 consecutive runs and every one recorded `ok`, with a chat count grepped
out of the previous hour's file. Three more runs were killed and left no row.

Corollaries, do not undo:

- Counts come from a step's own output (`digest.sh` prints `SESSIONS|N`), never
  from re-reading the file it wrote. A re-read returns the last good value when
  the step just failed.
- **There is one digest.** `~/.claude/scripts/daily_context_digest.sh` is a shim
  that execs this one. It used to be a second copy that `/update_daily_auto` ran
  after ours, over the same file, with no exclusion support and hardcoded paths,
  so every exclusion set in the app was silently written back.

## Layout

- **The scripts decide, the app renders.** Every judgement, including what counts
  as healthy, lives in a shell script. Changing it must never require rebuilding
  the app.
- `paths.conf` holds locations, written once at setup. `schedule.conf` holds
  everything Settings controls. Both are sourced, so both must be valid shell.
  Values are single-quoted (`shQuote`/`shUnquote` in `main.swift`) because the
  two command fields hold sentences; unquoted, a space ended the value and the
  rest of the line ran as a command. Keys still take no spaces around the `=`.
- The write-up fields take **a slash command or plain words**. A skill is already
  a slash command under its own name, so no router file in `~/.claude/commands/`
  is needed to reach one; `/5-15 create the weekly 5/15 for` invokes the skill
  directly and the week folder is appended to it.
- `chats_list.sh` is the single source for what a chat is. `projects_list.sh` and
  `scroll_status.sh` derive from it rather than counting separately, and pass
  `BEAT_ALL=1` when the number has to match what was collected.
- The app resolves its scripts by walking up from the executable, preferring a dev
  checkout over the copy bundled in the `.app`, so editing a script takes effect
  without a rebuild. `Bundle.main.bundleURL` is not dependable: it points at
  `Contents/MacOS` when the binary is launched directly rather than via `open`.

## AppKit traps already paid for

Do not undo these:

- The panel is a hand-positioned `NSPanel`, not an `NSPopover`. `preferredEdge` is
  a hint and gets flipped above the menu bar on a laptop screen.
- It must `canBecomeKey` or text fields are read-only, and `canBecomeMain` or
  tooltips never fire.
- Never `launchctl unload` the login agent to switch it off; that kills the app.
  Write or remove the plist.

## Working on it

- Invoke the `ponytail` skill, per the global rule.
- Rebuild with `Scrollback/build.sh`; it stamps `VERSION` into the bundle and copies
  the scripts into `Contents/Resources/scripts`.
- Screenshots for the README are captured from the real app:
  `SCROLLBACK_SHOT=settings|sources|runs` opens a section on launch (also accepts legacy `BEATBAR_SHOT`).
- Releasing: bump `VERSION`, rebuild, `gh release create vX.Y.Z Scrollback.app.zip`.
  Every user's Check for updates picks it up.

## The shared core (`core/`)

`core/scroll.py` is the same collector in Python, for machines the zsh cannot run
on. It is stdlib only: the Windows build ships the embeddable Python
distribution, and anything needing pip would need a wheel, a compiler, or an IT
conversation.

It is not a rewrite of the judgements, it is the same judgements behind the same
stdout contracts, because those contracts are the product: `SESSIONS|N`,
`sid|proj|title|HH:MM|inc`, `phase|detail|done|total`, and the history row
`start|chats|trigger|outcome|new|end`. The app parses those and nothing else, so
either implementation can serve it.

Two gates, both of which must pass before anything here changes:

```
zsh core/parity.sh          the Python says the same as the zsh, today
python3 core/selftest.py    what a RUN writes: one row always, fail recorded
                            as fail, no second run on top of a live one
```

`parity.sh` is this project's own second-derivation rule turned on itself: two
independent implementations, and the number only ships when they agree. The zsh
stays until parity holds for a week; until then it is what actually runs.

Windows-only and **unverified**, written without a machine to run them on:
`core/sched_win.py` (Task Scheduler, the twin of `apply_schedule.sh`) and
`core/install.ps1`. `python3 core/scroll.py probe` is the half-day of checking
that settles them, and `encode_cwd()` is the single line the whole port rests
on.
