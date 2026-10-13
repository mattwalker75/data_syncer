# Architecture

## Stack

Swift 5 language mode on a current toolchain, SwiftPM (no Xcode project), macOS 14 or newer.
Two targets: `DataSyncerCore` (a library: everything that copies, compares, records and restores,
with no UI) and `DataSyncer` (the SwiftUI app, which only drives the core and shows what it
reports). Tests run against the core alone. `BUILD_APP.sh` wraps the built program, the icon and
an `Info.plist` into `Data Syncer.app` and signs it ad hoc.

## Folders

```
Sources/DataSyncerCore/
  Models.swift      Job, Destination (kind, mode, folder, enabled, backup title), FileMeta, Snapshot, DSError
  Storage.swift     the Storage protocol; LocalStorage (a folder on this Mac); walk(); joinPath()
  Scanner.swift     a source folder → Snapshot (size, modified date, links, permissions)
  Records.swift     the .datasyncer records, backup folder names, BackupCatalog, chains
  Planner.swift     SyncPlan / BackupPlan from snapshots — nothing touched
  Runner.swift      JobRunner (events, progress, cancellation, one destination at a time), StorageFactory
  Restore.swift     RestoreEngine: plan a chain, put it back
  Preflight.swift   "Check destinations"
  JobStore.swift    jobs.json in ~/Library/Application Support/Data Syncer/
  RunHistory.swift  runs.json: every run's report, newest first, capped
Sources/DataSyncer/
  DataSyncerApp.swift  the scenes: the main window, the Settings window, the menu commands
  AppModel.swift       the one object the views watch: jobs, history, settings, the run in progress
  RunSession.swift     a run as the views see it, built from RunEvents (throttled progress, a capped log)
  MainWindow.swift     the split view: Sidebar, the toolbar, RunningStrip, the empty state
  JobDetailView.swift  the selected job: header, source card, DestinationRow list, recent runs
  Editors.swift        JobEditor, DestinationEditor, FolderPicker (NSOpenPanel, /Volumes)
  CheckSheet.swift     "Check destinations" (Preflight) and the Full Disk Access shortcut
  RunScreen.swift      RunOptionsSheet (full/incremental per destination), RunScreen, SyncPreviewSheet
  SettingsView.swift   General, Appearance, Accounts, Notifications, Run history
  Formatting.swift     dates/sizes/durations in words, status lines, colours, small shared views
Tests/DataSyncerCoreTests/  Helpers (Scratch, makeTree, readTree, FixedClock), PlannerTests, RunnerTests
icon/               icon.svg → make_icns.sh → DataSyncer.icns (committed)
```

## The Storage interface

Every destination kind is a `Storage`: `checkReachable`, `exists`, `stat`, `list`, `makeDirectory`,
`remove`, `upload(localURL:to:meta:progress:)`, `download`, `readData`/`writeData`, `freeSpace`,
`makeSymlink`, and `keepsModifiedDates`. The engines never know what is behind it, so a sync to a
USB drive and a sync to S3 run the same code. Paths are relative to the destination's configured
folder. `walk()` lists everything under a folder, leaving out the `.datasyncer` records at the root.

`StorageFactory` turns a `Destination` into a `Storage`; `DefaultStorageFactory` covers local
folders and USB drives (found by name under `/Volumes`). Network shares, SFTP and the cloud
services add their own `Storage` in later steps.

## What a run does

`JobRunner.run(job, choices:)`, for each enabled destination in order:

1. **Source** — scanned once per run (`Scanner`): every file, folder and link, nothing skipped.
2. **Destination** — `factory.storage(for:)`, `checkReachable()` (the folder must already exist;
   Data Syncer never creates it), then `Records.ensure` writes the README and destination record
   if they are not there.
3. **Plan** — `Planner.sync` (against the `sync-state` record and what is at the destination now)
   or `Planner.backup` (full, or incremental against its parent manifest). The plan is reported in
   words before anything is copied, then the free space is checked against it.
4. **Copy** — folders made, files uploaded with progress (chunked, so a big file reports as it
   goes and a cancel takes effect mid-file), links made, extras deleted (sync). Every file is
   reported as copied, linked, deleted, skipped (with the reason) or failed.
5. **Records** — a sync saves its state (on the way out too, so a cancelled run remembers what it
   did); a backup writes its manifest last, and a backup that did not finish is removed.

A failed destination does not stop the next one. The report lists every destination's status,
counts, problems and the backup folder it made.

## Restore

`RestoreEngine.plan` resolves the chain for a restore point (`BackupCatalog.chain`): the full,
then each incremental up to and including the point. `restore` applies them in order into the
chosen folder — files from each backup's `copied` list, folders from its snapshot — and, with
`removeDeleted`, removes what each incremental recorded as deleted. A missing or unreadable link in
the chain is refused with a message naming it; other backups are unaffected.

## The app

`AppModel` (main actor) owns the jobs (`JobStore`), the history (`RunHistory`), the settings
(`settings.json`) and at most one run at a time. **Run…** → `RunOptionsSheet` → `AppModel.start`,
which makes a `RunSession`, runs a `JobRunner` in a `Task`, and feeds every `RunEvent` to the session
on the main actor (progress events are throttled to ten a second; the file log keeps the last 400
lines). The runner's `confirmSync` hook becomes the `SyncPreviewSheet`: the run waits on a
continuation until the user answers. While a run is going, `screen` can switch back to `.jobs`; the
`RunningStrip` shows the session and `canRun` is false. When the report arrives it goes into the
history, a notification is posted (bundled app only) and the sleep-prevention activity ends.

The views never touch disks: every status line ("Synced today 9:14 · 212 copied") is derived from
the history by `Formatting`. The source folder's size is counted once per job per session by a
background `Scanner.scan`.

**Development hooks** (environment variables, see DEVELOPMENT.md): `DATASYNCER_HOME` moves the
jobs/history/settings folder; `DATASYNCER_AUTOSTART=<job name>` starts a run on launch;
`DATASYNCER_WINDOW=x,y,w,h` places the window.
