# Scrollback GitHub rename (public repo)

- **Remote:** `github` → https://github.com/Alexsometimescode/scrollback.git
- **Branch:** `main`
- **Primary rename commit:** `65765132ccfdd9f46cb53930cca3a0b3f34214f3`
- **Follow-up (BeatBar comment cleanup):** see latest `git log -1` on `main` after push

## What changed

| Before | After |
|--------|--------|
| `BeatBar/` | `Scrollback/` |
| `core/beat.py` | `core/scroll.py` |
| `beat_status.sh` | `scroll_status.sh` |
| `BeatBar.icns` | `Scrollback.icns` |
| App binary / `CFBundleExecutable` | `Scrollback` |
| Built app | `Scrollback/Scrollback.app` |

`git ls-files` has **no** paths matching `beat` / `BeatBar` (verified after rename).

## Env / local compat (not in filenames)

- `paths.sh`: `SCROLLBACK_HOME` with `BEAT_HOME` alias
- Existing installs: `~/.beatbar/paths.conf`, `com.beatbar.login` launch agent, migration from `com.beatbar.daily` → `com.scrollback.daily`
- `CFBundleIdentifier` remains `com.beatbar.app` (upgrade continuity)

## Verify (2026-09-30)

- `./Scrollback/build.sh` → OK
- `python3 core/test_history_collect.py` → passed
- `pkill -x Scrollback`; `open Scrollback/Scrollback.app` → PID `Scrollback`
