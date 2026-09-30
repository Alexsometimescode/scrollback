# Hackathon: simplify collect + instant panel

## Demo script (3 clicks)

1. **Menu bar icon** — open Scrollback. Panel should appear immediately with warm stats (7-day strip, last update time) without a spinner on first paint.
2. **Collect chats now** — confirm sheet shows last collected time (e.g. `Today 2:15 PM` or `2h ago`) and a short list of today's threads. Click **Yes, collect**.
3. **Overview window** — when the run finishes, Summary/Categories open (local draft if AI is off or fails). File is written under this week's folder as `YYYY-MM-DD-scrollback-overview.md`. Use **Open file now** or **This week folder** from the panel to show it.

## What changed

- Panel reuses one hosting view (hide/show, no rebuild each click); store refreshes on launch and on open in the background.
- Collect path is a confirm sheet (gap collect → summarizer → week folder); heavy date/chat-picker flow removed from the panel.
- Preview always renders Summary + Categories (Swift fallbacks + shorter Python local draft).
- Compact overview UI (truncated lines, Done/Blockers/Next bullets).

## Verify quickly

```bash
cd /Users/Bassam/Work/repos/scrollback
python3 core/test_summary.py
python3 core/test_history_collect.py
Scrollback/build.sh
```
