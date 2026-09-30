# Panel polish + pitch demo notes

**SHA:** `c8a636906eb573619af72d043e3027bde66a4167`  
**Remote:** `github` `main` (`c955af8..c8a6369`)  
**Build:** `/Users/Bassam/Work/repos/scrollback/Scrollback/Scrollback.app` (`./Scrollback/build.sh`)  
**Relaunch:** `pkill -x Scrollback`; `open Scrollback/Scrollback.app` (PID 39210 after this run)

## Execution (rubric ×2)

| Check | Status |
|-------|--------|
| **Update today** → list → Summary tab with text | Primary CTA restored on panel; Swift fallbacks if AI preview fails |
| **Collect chats…** → dates/agents → Collect | Unchanged; `history_collect.py` list OK on this machine |
| **7-day chart / Recent runs** non-zero | `Day.loadForPanel()` / `Run.loadForPanel()` seed when digest + history chats are all 0 |
| **This week folder** | Opens `FIVE/week_NN` with live `shellValue("FIVE")`; falls back to parent if missing |

## Clarity

- Card corner radius **20pt**; padding inside single `ScrollView` (About + Check for updates scroll with settings)
- Accordions **closed by default**; full-row tap + `easeInOut` expand (respects Reduce Motion)
- Fixed panel height cap; no `relayoutPanel` observer

## Usefulness (judges)

- **Hide sensitive info** under Sources & privacy (default ON)
- **Summarizer** picker: Cursor / Grok (`SUMMARY_MODEL`)

## Demo script (30s)

1. Open menubar panel → point at chart + recent runs  
2. **Update today** → Summary  
3. Expand **Sources & privacy** → toggle redaction  
4. **This week folder** → Finder  
