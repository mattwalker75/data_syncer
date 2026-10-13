# Changelog

All notable changes to Data Syncer (Keep a Changelog style; dates are when the change was made).

## [Unreleased]

### Added
- 2026-10-13: **Step 1 — the core.** Jobs (one local source, many destinations) and destinations
  with three modes: Sync (preview first; deleting files the source no longer has is a per-destination
  switch), Full only (a new dated folder every run) and Full + incremental (chains measured since the
  last incremental or the last full, with a limit per chain). The scanner reads everything; change
  detection is size + modified date with a 2-second tolerance, and a sync also checks the copies
  against its record so a tampered copy is put right. Records travel with the data in `.datasyncer`
  folders (README in Matt's wording, destination record, sync state, a manifest per backup holding
  the whole snapshot, what was copied and what was deleted). Restore rebuilds a chain up to the chosen
  point with a "remove files that were deleted" switch. Pre-run checks (reachable, folder present,
  writable, free space, what backups are there, whether an incremental is allowed). Runs go one
  destination at a time with live events, cancellation mid-file, and a report; a failed destination
  does not stop the next. Local folders and USB drives (by name) for now. 23 tests.
- 2026-10-13: `BUILD_APP.sh` (assembles and signs Data Syncer.app with icon D), `INSTALL_APP.sh`
  (checks for Swift, tests, builds, copies to /Applications), `icon/make_icns.sh`, and the docs.
- 2026-10-13: `INSTALL_APP.sh --to DIR` puts the finished app somewhere other than /Applications
  (e.g. the Desktop); docs on copying the app to another Mac.
