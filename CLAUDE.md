# CLAUDE.md — working on Data Syncer

Read this before changing anything. `Docs/` has the detail.

## What it is
A Mac app (Swift + SwiftUI, macOS 14+, no Xcode project — SwiftPM + `BUILD_APP.sh`) that copies a
local source folder to one or more destinations **only when the user presses Run**: a sync (mirror),
a dated full backup, or full + incremental backups with restore. Never a service, never automatic.
The person using it is not a developer — every message is a plain sentence.

## Map
- `Sources/DataSyncerCore/` — everything that copies, compares, records and restores; no UI, tested on its own.
  - `Models.swift` — Job, Destination (kind + mode + folder), FileMeta, Snapshot, DSError (the only error type).
  - `Storage.swift` — the `Storage` protocol every destination kind implements, and `LocalStorage`.
  - `Scanner.swift` — a source folder → Snapshot (everything; nothing skipped except a `.datasyncer` at its top).
  - `Records.swift` — the `.datasyncer` records (README, destination, sync-state, manifests), backup folder names, `BackupCatalog` and chains.
  - `Planner.swift` — pure planning: what a sync or backup will do, before anything is copied.
  - `Runner.swift` — `JobRunner`: checks → plan → copy, one destination after another, with events and cancellation; `StorageFactory`.
  - `Restore.swift`, `Preflight.swift` (Check destinations), `JobStore.swift` (jobs.json in Application Support).
- `Sources/DataSyncer/` — the SwiftUI app (step 2). Thin: drives the core, shows its events.
- `Tests/DataSyncerCoreTests/` — XCTest against throwaway folders (`Scratch`), a fixed clock for folder names.
- `BUILD_APP.sh` assembles the .app (+ `icon/DataSyncer.icns`, ad-hoc signed); `INSTALL_APP.sh` checks tools, tests, builds, copies to /Applications.

## Rules that exist for a reason (Matt's decisions, Oct 2026)
1. **One way, on demand.** The source is always local and is the truth. Nothing runs unless the user runs it; no scheduling, no watching.
2. **Three modes per destination:** `sync(deleteExtras:)` (preview first; deleting is a per-destination switch), `fullOnly`, `fullIncremental(chainStart:maxIncrementals:)`. A job maps one source to many destinations; the run goes **one destination at a time**, carries on after a failure, and reports everything at the end.
3. **Folder names** `yyyy_MM_dd_HHmm_Full_<title>` / `…_Incremental_<title>` (year first so Finder sorts; time so two a day don't clash). Two backups in one minute are refused.
4. **The records travel with the data** (`Docs/RECORDS.md`): `<dest>/.datasyncer/{README.txt,destination.json,sync-state.json}` and `<backup>/.datasyncer/manifest.json`. The README text is Matt's wording — keep it. Each manifest holds the whole source snapshot as of that backup, what it copied, and what was deleted since its parent, so chains and restores need nothing from the Mac that made them.
5. **The app never deletes backups** (no retention): the user does, in Finder or in the app. Deleting a backup must break nothing except restores of incrementals that depend on it; the catalog is re-read at every run.
6. **The destination folder must already exist.** Data Syncer never creates it; a missing folder fails the check with a plain message. USB drives are found by name under `/Volumes`; every destination has a configured folder inside its location.
7. **Change detection = size + modified date** with a 2-second tolerance (FAT drives). A sync also checks the destination against the `sync-state` record, so a tampered or vanished copy is put right. No fingerprints, no skip patterns, no compression, no encryption (plain copies, by decision).
8. **Restore rebuilds the chain**: the full, then each incremental up to the chosen point, into a folder the user picks; `removeDeleted` decides whether files recorded as deleted are removed or left. Whole-backup restores only (partial restores later).
9. **Incrementals:** `chainStart` is `lastIncremental` (increments of increments) or `lastFull`; `maxIncrementals` per chain, after which the next backup must be a full. An incremental that is not allowed is refused with the reason when asked for explicitly, and becomes a full when the choice was left open.
10. **Cancelling** stops mid-file; a backup that did not finish is removed so it is never mistaken for one. A sync saves its record on the way out.
11. **Cloud services through their own APIs** (Google Drive, Dropbox, OneDrive, S3): no desktop apps; each gets an in-app step-by-step setup guide. Secrets go in the Keychain, never in jobs.json. (Steps 4–5.)
12. **Scripts**: `-x`/`--long` options + `-h`; idempotent; plain-spoken. **Commits:** one per feature with a dated CHANGELOG entry; explicit `git add <paths>`; never push — Matt pushes.
13. **Testing:** `swift test`; every engine rule has a test against throwaway folders; never touch the user's real folders or Application Support in tests (`Scratch` + `JobStore(url:)`).
14. **Design:** Theme 1 "Sidebar" from the mockups (jobs down the left, the selected job's details on the right, Run/Check/Restore in the toolbar, gear + New job at the bottom of the sidebar; a strip on the main window while a job runs with Watch / Cancel run; Settings opens from the gear: General, Appearance (Light/Dark/System, accent, custom themes), Accounts, Notifications, Run history). Icon D.
