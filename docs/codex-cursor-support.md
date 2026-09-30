# Codex and Cursor saved conversations

Bassam requested launching Scrollback and adding Codex and Cursor saved chat transcript support.

- Preserve existing Claude behavior and stdout contracts.
- Additional sources are opt-in and local read-only inputs, limited to the configured work directory.
- Count real user activity on the requested day, never injected instructions or subagents.
- Keep chat listings, exclusions and digest consistent; label source IDs to avoid collisions.
- Read Cursor timestamps, tool statuses and workspace attribution from its local database in read-only mode. Undated exports remain preview-only.
- Include empty-window Cursor chats only through an explicit config option, labelled as unassigned.
- Show all three providers in today's Chats window; preserve source exclusions.
- Launch from this isolated local clone with local output, disabled schedules and no retired company update calls.
- Validate at existing CLI seams with synthetic transcripts, shell/Python parity and a local app launch.

## Recognizable chat selection

- Prefer saved application chat names over prompt fragments, and identify fallback titles.
- Group historical results in an expandable Agent > Project > Chat tree.
- Use explicit saved project metadata when available; label projectless Codex chats as No project and retain workspace paths as a fallback.
- Show short message excerpts from the selected dates and readable activity dates.
- Keep selection and Collect all independent of collapsed groups; metadata never changes eligibility or source scope.
- Optional name metadata is read-only and may fall back when missing or unavailable.

## Draft-first overviews

- Dates, agents and explicit selected chats feed a 5/15-guided overview, not a raw transcript file.
- The selection toolbar has Select all and Deselect all icons; the final action is Collect with Just see it alongside it.
- Preview uses the installed 5/15 skill for Summary and Categories without executing its filesystem or external-tool instructions.
- Both views live inside the existing chat window, selectable/read-only by default with basic plain-text editing and an accessible Copy all icon.
- Nothing is saved until an explicit Save new or Append action. A native file picker chooses the Markdown destination, including a daily, weekly or memory note.
- Save new must not overwrite; append preserves existing content and avoids repeating the identical draft. Errors preserve the unsaved draft.
- Open file now is available after saving. Discard clears the draft without deleting existing notes.

## Offline handoff recovery

- Preview defaults to a labelled local evidence draft, without provider calls. SUMMARY_ENABLED=true explicitly enables optional AI synthesis.
- Missing/failed AI synthesis falls back to the local draft and full agent handoff, never a false AI summary.
- Agent draft includes the selected evidence and installed 5/15 guidance for another agent, with no automatic transmission.
- Empty selections and vanished/no-match results return an empty state without saving or invoking a provider.
- Chats without project metadata appear directly under their agent; no placeholder workspace headings or project lines are written.
