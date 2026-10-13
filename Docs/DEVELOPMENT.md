# Development

## Build and test

```bash
swift build                 # the core and the app program
swift test                  # the core's tests (throwaway folders under the temp directory)
./BUILD_APP.sh -d           # a debug Data Syncer.app in build/
```

No Xcode project: `Package.swift` is the whole build. Opening the folder in Xcode works too
(File → Open the folder; it reads the package).

## Tests

`Tests/DataSyncerCoreTests/`:

| File | Covers |
| --- | --- |
| `Helpers.swift` | `Scratch` (a throwaway folder removed afterwards), `makeTree` / `readTree`, a `FixedClock` so backup folder names are predictable, `localJob` |
| `PlannerTests.swift` | folder names and titles (round trip), sync plans (first run, unchanged, changed source, tampered copy, the 2-second tolerance, extras deleted deepest first only when asked), backup plans (full, incremental with deletions) |
| `RunnerTests.swift` (HistoryAndPreviewTests) | a declined sync preview leaves the destination alone and reports it as skipped; the history keeps the newest first, capped, and "last result" ignores skipped runs |
| `RunnerTests.swift` | real runs: a sync mirrors the source with records, dates and permissions kept and links made; deleting is per destination; a tampered copy is put right; a missing destination folder fails that destination and the run carries on; a USB drive that isn't connected; full + incremental chains, the per-chain limit, "since the last full", full-only folders, same-minute refusal, cancel leaves no half folder; restore with and without removing deleted files, a deleted full breaks only what depends on it; the pre-run checks; jobs save and load |

Tests never touch real user folders or Application Support (`JobStore(url:)` points at a scratch file).

## Trying the app without touching your real jobs

```bash
DATASYNCER_HOME=/tmp/ds-home "build/Data Syncer.app/Contents/MacOS/Data Syncer"
```

`DATASYNCER_HOME` points the jobs, history and settings files at another folder. Two more hooks exist
for looking at screens: `DATASYNCER_AUTOSTART="<job name>"` runs that job as soon as the window is
up, and `DATASYNCER_WINDOW=100,100,1120,760` puts the window at that place on the main display
(handy for `screencapture -l <window id>`). All three are for development only and do nothing when
unset. The jobs file format is plain JSON (`JobsFile`), so a test home can be written by hand.

## Conventions

- **Messages are sentences for a person**; every error is a `DSError` with the message the user sees.
- **Nothing is deleted on a hunch**: the only deletions are a sync's extras (per-destination switch, previewed), a restore's recorded deletions (switch), and a backup folder that did not finish.
- **The core never knows about screens**; it reports `RunEvent`s and returns a `RunReport`.
- **Dates** in records are ISO-8601 with milliseconds; file modified times are seconds since 1970.
- **Commits:** one per feature with a dated CHANGELOG entry; never push — Matt pushes.
