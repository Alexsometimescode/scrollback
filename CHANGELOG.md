# Changelog

What changed in each release, and why. Newest first.

A bug is only listed here once it was reproduced, and where a number is quoted it
was measured rather than estimated.

---

## 1.8.0 — 2026-08-18

### Added
- **It tells you when there is a release.** Nothing did before: the only way to
  find out was to open Settings and press a button, so people sat on old versions
  without knowing. It checks shortly after launch and every six hours, and offers
  the update in a card that hangs off the menu bar icon rather than a system
  alert in the middle of the screen.
- **Later means later.** Declining records that version and stays quiet until a
  newer one appears, instead of asking again tomorrow.
- The card names the versions and what changed: `1.8.0 from 1.7.1 · 3 fixes ·
  2 added`. The counts are read from this file's newest block, so they cannot
  drift from the release.
- `update.sh --check` answers "is there a newer one" and installs nothing, and
  `--summary` prints the counts. The app renders what they say, as with every
  other judgement in this tool.

## 1.7.1 — 2026-08-17

### Fixed
- **Runs were stamped with the time they finished.** A run starting at 09:00 and
  taking three minutes showed as 09:03, which reads as a schedule firing late.
  The row now carries both times, `start|chats|trigger|outcome|new|end`: the
  start is what you see, the end is what "+N new" measures from, or anything
  touched while a run is working gets counted again on the next one. Rows written
  before this have five fields and fall back to the start time.

## 1.7.0 — 2026-08-17

### Fixed
- **A terminal opened by itself on Friday evening.** The weekly report was a
  background job firing at 18:15 whether anyone was there or not. Off by default
  now; it starts only from the button. `weekly_enabled='true'` restores it.
- **The last run of the day threw its write-up away.** A write-up command gating
  on "before 18:00" refused the 18:00 run, so the digest was collected and the
  write-up discarded. The final hour of every day never reached that day's log.
- **The panel cried wolf twice.** It read `NOTHING COLLECTED TODAY` from midnight
  until the first run, and would have reported ten missed runs every Saturday.

### Added
- **`daily_weekdays_only`**, skipping Saturday and Sunday. launchd has no "not at
  the weekend", so each hour is expanded into one entry per weekday.
- **Catch-up for days the collector never ran.** The digest window is one day
  wide and nothing ever went back, so stopping overnight or over a weekend meant
  that work was never digested at all. The first run of the next working day
  rebuilds yesterday, plus any of the last seven days with no digest.
- **A past day may only gain sessions, never lose them.** Rebuilding selects
  transcripts by modification time and those move, so a chat touched again later
  drops out and a good digest gets written thinner. Measured at six sessions down
  to one. This guard is what makes the catch-up safe.
- The panel says when the next collection is: `today at 14:00`, `tomorrow at
  09:00` once the day's last fire has passed, `Monday at 09:00` on a Friday
  evening with weekends off.

## 1.6.1 — 2026-08-14

### Fixed
- **The menu bar went red from midnight every Friday**, saying no 5/15 had been
  written, about eighteen hours before the weekly job could have written one.
  Introduced in 1.5.0 by making a missed report stay flagged instead of going
  green on Monday, which removed the "not due yet" case without replacing it.

## 1.6.0 — 2026-08-13

### Fixed
- **It asked for the same permissions on every release.** Not what the app
  requests: how it was signed. An ad-hoc signature's designated requirement is
  the binary's own hash, so macOS saw each version as a different app and forgot
  every grant. Signed with a stable certificate, the requirement is the
  certificate instead and holds across versions. Only the build machine needs it;
  the signature travels in the zip.
- **Notification permission was requested at every launch**, whether or not you
  wanted alerts. Asked for now only when a run has actually failed.
- **A cloned install updated only its binary.** The release path replaced the
  `.app` while the app prefers a checkout's scripts, so a clone ended up on a new
  binary running the old scripts, which is the half that decides everything. A
  checkout pulls; only a zip install downloads.

## 1.5.0 — 2026-08-13

### Added
- **`daily_final`**, one optional extra fire, for write-up commands that refuse
  to run past a certain hour. A fire exactly on that boundary collected the
  digest and had its write-up refused.

## 1.4.0 — 2026-08-12

### Added
- **From @pcernik**: scheduled write-ups work without a login keychain (#4),
  digest sections carry the transcript path so a write-up can verify a claim
  rather than paraphrase two lines (#2), and a fork updates from itself (#3).
- The reading step names the **chat**, by the title you gave it, rather than the
  folder it lives in. The write-up step names the **file** it writes into.

### Fixed
- **Three spinners turned for one operation.** One in the panel now, plus the
  menu bar.
- The panel showed one number where two were needed. `9 today · 7 open`: today is
  everything worked on since midnight, closed tabs included, which is what
  reaches your log; open is what is on screen.

## 1.3.0 — 2026-08-12

### Fixed
- **Every user's Mac got background jobs named after one person.** Renamed to
  `com.beatbar.daily`, `com.beatbar.weekly`, `com.beatbar.login`. Existing
  installs migrate on the next settings change rather than silently losing their
  schedule.
- **Every screenshot was wrong.** All five predated the settings sections, the
  exclusions and the chart, and one showed a command that no longer existed.

## 1.2.0 — 2026-08-12

### Fixed
- **The collection was invisible while it happened.** Ten scheduled runs a day
  with nothing in the menu bar, and a panel that wrote its progress once for a
  step taking minutes, so a working run looked frozen. The icon spins while any
  collection runs, whoever started it, and the write-up ticks every two seconds.
- **The progress bar never worked.** The digest wrote `phase|done|total|name`
  while the app parsed `phase|detail|done|total`, so it read the project name as
  the total, got nothing, and fell back to a bare spinner.
- A run that just finished repaints within a second instead of up to five
  minutes.

## 1.1.0 — 2026-08-11

An audit of every run in one day. The health signal could not be trusted.

### Fixed
- **The digest crashed on 12 consecutive runs and all 12 recorded `ok`.** Its
  exit code was never read, so the outcome came from the write-up step alone and
  a dead collector was invisible.
- **Three runs were killed mid-write-up and left no record at all**, one after it
  had already written to the daily log. The history row is written from an `EXIT`
  trap now, so no path can skip it.
- **The chat count was read back out of the file the digest writes**, so a failed
  run reported the previous hour's number as its own. Counts come from a step's
  own output.
- **Two digests existed.** The write-up step ran an older copy over the same
  file, with no exclusion support and hardcoded paths, so folders and chats
  switched off in the app were written straight back.
- **A failed run turned the headline red but never reached the menu bar icon or
  the notification**, which read a different signal. Every unhealthy condition
  goes in one list that the icon reads.
- **A run that never fired left no trace**, and nothing read as healthy. Missed
  runs are detected.
- **The weekly report was matched by one person's filename**, so no one else's
  check could ever pass, and it was looked for in the wrong week's folder.
- **The weekly report had never once fired on its own.** Warp resolves a launch
  config by its internal name, not the file name, and a miss is silent. The
  Terminal fallback was broken too, by an apostrophe in the default prompt.
- Only one collection runs at a time. Two triggers could hand the same daily log
  to two agents.

## 1.0.0 — 2026-08-11

First release.

### Added
- Menu bar app, no Xcode project and no dependencies, with a prebuilt app in the
  repo so no toolchain is needed.
- Hourly collection and a weekly write-up as background jobs, installed by the
  app.
- A deterministic digest that reads transcripts and needs no agent at all.
- 7-day chart, an audit trail of every run, per-folder and per-chat exclusion.
- In-app updates from GitHub Releases.

### The bug it was built to find
- **The collector was scanning one project folder out of eight.** For three days
  it wrote up 2 chats out of 10, and the weekly report built from those logs
  understated the week badly. Nothing surfaced it, because a collector that runs
  successfully and collects almost nothing looks exactly like a quiet week. Those
  three days are still visible in the chart: 2, 2, 2 against 7 and 8 either side.
