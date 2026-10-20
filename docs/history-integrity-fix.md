# History integrity and public updates

Bassam requested fixing Scrollback so the existing product works before sharing it publicly.

## Acceptance

- Ordinary panel history displays only recorded CLI history. Empty history stays empty; zero counts stay zero; failed runs stay failed. Never create or read a synthetic history cache in normal operation.
- Explicit --demo provides clearly labelled sample history without changing real records or sharing evidence.
- Public update checks and updates use only the Scrollback repository on github.com, even if the process inherits an enterprise GH_HOST. Never contact archived employer hosts or unapproved Git remotes.
- Local-only mode exits before config scripts or provider commands run. Local commits ahead of the remote are not a new downloadable update. An unsuccessful check must not offer an empty version.
- Source updates do not claim to update the executable unless it was rebuilt successfully.
- Preserve existing uncommitted UI work, source/chat configuration, notes and schedules.
- Verify at the actual Swift history loader and updater CLI using synthetic records and fake command adapters; then build and launch the native app locally.

## Implementation record

The history regression test initially failed with: empty real history must have no successful runs. History parsing now lives in Foundation-only History.swift, so the same loaders used by the panel compile in an isolated fixture harness. The only sample-history path is explicit --demo; demo runs are labelled demo.

No private agent chats or provider calls are needed for these regressions. The existing integration suite independently compares the shell and Python collectors on synthetic records. Live provider behavior is outside this repair's claim.
