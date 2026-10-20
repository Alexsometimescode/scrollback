# Scrollback

Recover useful context from saved AI chats, then turn selected conversations into a Markdown note.

Scrollback is a macOS menu bar app for saved **Claude Code, Codex and Cursor** conversations. It reads local chat records, lets you choose the evidence to collect, and previews a draft before you save it. Optional AI summaries and scheduled daily or weekly write-ups sit on top of that local collection workflow.

Built at the [Cursor hackathon](https://cursor.com). MIT licensed.

## What you can do

- Browse saved conversations by date, agent and project, using saved titles where available.
- Select individual chats and preview their messages and recorded activity.
- Read a local evidence draft, or request an optional AI overview with Summary and Categories views.
- Copy or edit the current draft, save it as a new Markdown file, or append it to an existing note.
- Collect a daily digest on a configurable schedule and inspect recorded collection runs.
- Enable daily or weekly write-ups with editable prompts and a selected summary provider.

Saving a preview is explicit. **Save new** will not overwrite an existing file. **Append** preserves the note and avoids adding an identical draft again. Scheduled collection and enabled write-ups are separate actions that can write their configured outputs automatically.

## Supported conversation sources

| Source | What Scrollback reads |
|---|---|
| Claude Code | Saved local conversation records with human input and activity timestamps. |
| Codex | Saved local session records, with optional local title/project metadata. |
| Cursor | Saved transcripts and supported local database records, opened read-only. |

A conversation must exist in a supported local format. Scrollback cannot recover unsaved messages or guarantee compatibility with future changes to another application's storage. Date selection depends on timestamps in those records. The Grok hook is a placeholder and currently returns no conversations.

## Collection and optional AI

Collection reads local source records. AI overview is a separate choice: selected chat evidence is passed through an installed provider CLI when overview is enabled.

| Summary choice | Processing |
|---|---|
| AI overview off | Local evidence excerpts and a checklist draft, without an AI-provider request. |
| Claude Code, Codex or Cursor CLI | Selected evidence is passed to that CLI. Its account, remote processing and usage charges apply. |
| Local model through Ollama | Requires Ollama and an exact model already installed locally. The adapter requires a loopback endpoint and rejects model metadata identifying a remote model. |

Choose the provider in **Write-ups**. With `auto`, an explicit configured CLI takes priority; otherwise provider discovery tries Claude Code, Cursor and Codex in that order. The checked-in configuration currently enables AI overview with a Codex CLI path. Turn off **AI overview in Collect preview** before selecting private conversations if you want local-only previews.

In Collect preview, a missing or failed summarizer falls back to a labelled local evidence draft. It is not presented as a completed AI summary. Scheduled write-ups report synthesis failure without replacing an existing output. Scrollback does not install provider CLIs, sign in for you, install Ollama or download models. Live provider behavior has not been fully verified in this release.

## Privacy and saved notes

Source chat stores are read-only inputs. Generated notes, digests, history, settings and schedules are separate local outputs. Settings are shared by the app and its collector scripts; configured source folders and exclusions determine what the daily collector sees.

Current masking uses local text patterns for token-like strings and some displayed paths. It is limited, not a complete PII detector or a guarantee that selected text is safe to send. Review the evidence before enabling a remote summarizer. No verified Core ML redaction integration is claimed.

Daily and weekly write-ups use separate app-owned files, leaving original daily context notes intact. Those generated write-up files may be replaced on a later run for the same period. Review any legacy custom write-up commands before enabling them.

Machine-specific paths belong in `paths.conf`, which Git ignores. Do not commit chat records, notes, tokens or screenshots containing private project names.

## Build and run on macOS

Requirements:

- macOS and Xcode Command Line Tools, including `swiftc`.
- Python 3 for the collector, plus the system `zsh`.
- Saved local records from at least one supported conversation source.
- For optional AI summaries, an installed provider CLI or an installed local Ollama model.

```sh
git clone https://github.com/Alexsometimescode/scrollback.git
cd scrollback
./Scrollback/build.sh
open Scrollback/Scrollback.app
```

The build script compiles the Swift app, stamps the version from `VERSION`, bundles the shell/Python collector and signs the local build with the available local identity or an ad-hoc signature. Python remains a runtime requirement. This is a source build, not a notarized download. The bundle declares macOS 13 as its minimum; compatibility with older macOS releases has not been independently verified.

## First use

1. Open Scrollback from the menu bar and complete **Set up Scrollback** with your source folders and output locations.
2. Review source exclusions, automatic collection, AI overview and write-up settings before collecting.
3. Choose **Collect chats**, select a date range and the conversations you want, then preview the selected evidence.
4. Review the draft. Use **Save new** or **Append** and choose the Markdown destination in the file picker.
5. Inspect the saved note. For automatic digests, use the panel's collection status and recorded run history to check what happened.

The manual selection workflow and scheduled daily digest have different source-scope options, including unassigned Cursor chats. Compare counts only for the same dates and inclusion rules.

## History and updates

Version 1.8.1 removes sample history from normal operation. Empty history stays empty, zero counts stay zero, and failed runs stay failed. Sample history requires an explicit `--demo` launch and sample runs are labelled `demo`; a demo is not proof that collection occurred.

Updates use the public Scrollback repository on github.com. A packaged install can check for a published release. Source checkouts report that a source update and local rebuild are required; pulling scripts alone does not update a compiled app. Keep local changes before updating a checkout.

## Verification and limits

The current repair passed synthetic source/selection/note tests, shell/Python collector parity, failure and run-lock checks, the actual Swift history-loader regression, and updater CLI fixtures. The native app compiled, and an isolated panel showed seven zero days with empty sources. The updater suite includes failed lookups, failed copies and a successful replacement using fake external commands.

```sh
python3 -B core/integration_test.py
python3 -B core/test_note_store.py
python3 -B core/test_summary.py
python3 -B core/test_panel_history.py
python3 -B core/test_update.py
python3 -B -m unittest core.test_writeups
```

These checks do not establish a complete live-provider, downloaded-update or user-chat workflow. Windows helpers are experimental; the desktop app described here is for macOS. Use labelled synthetic conversations for public demos. Older development screenshots are excluded from the source tree.

## Source layout

| Path | Purpose |
|---|---|
| `Scrollback/` | Swift menu bar app, collection UI and history loaders. |
| `core/` | Python parsers, selection, summaries, note saving, write-ups and tests. |
| Root shell scripts | Daily collection, scheduling, status and updates. |
| `docs/` | Collector contracts and verification notes. |
| `CLAUDE.md` | Contributor conventions and collection contracts. |

## License

[MIT](LICENSE).
