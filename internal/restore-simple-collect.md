# Restore simple Collect + Quit (2026-09-30)

## Goal

Undo hackathon Collect simplification (`69a2416`) for pitch demo while keeping panel warm-open, multi-agent collect, cursor empty-window fixes, and Scrollback rebrand work in flight.

## Changes

### Quit

- `Scrollback/main.swift`: `installQuitMenu()` adds a minimal app menu with **Quit Scrollback** (Cmd+Q when Scrollback is key).
- Right-click the menu bar icon opens the same **Quit Scrollback** item.

### Collect flow

- `Scrollback/Collection.swift` restored from `f9dbb4c` (pre-`69a2416`): dates → agents → chat list → **Just see it** / **Collect**.
- Removed gap-only sheet (`CollectionConfirmView`, `warmGapPlan`, `confirmGapCollect`, auto week-folder save on gap).
- Kept empty-summary fallbacks in `applyPreview` so previews still show Summary/Categories when synthesis is off or fails.

### Panel

- Restored pre-hackathon home layout: spacing 10, padding 14, no prominent **Collect chats now** button.
- **Collect chats…** back in the headline row with Today file / week folder.
- Kept instant panel reuse (`panelHost`, persistent `KeyPanel`, global click monitor not torn down on close).

## Build / run

```bash
cd Scrollback && ./build.sh
pkill -f 'Scrollback.app/Contents/MacOS' || true
open Scrollback/Scrollback.app
```

## Verify (manual)

1. Menu bar → **Collect chats…** opens date/agent picker, not gap confirm.
2. Right-click icon → **Quit Scrollback** exits; Cmd+Q when panel focused also quits.
3. `./scroll_status.sh | head -1` still healthy after a collect (post-rename script name).

## Coordinated with

- Staged rename `BeatBar/` → `Scrollback/`, `beat_status.sh` → `scroll_status.sh`, `core/beat.py` → `core/scroll.py` (bc-afd887da).
