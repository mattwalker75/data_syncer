# Architecture

## Stack

Swift 5 language mode on a current toolchain, SwiftPM (no Xcode project), macOS 14 or newer.
Two targets plus the tests: `DataSyncerCore` (a library: everything that copies, compares, records and restores,
with no UI) and `DataSyncer` (the SwiftUI app, which only drives the core and shows what it
reports). Tests run against the core alone. `BUILD_APP.sh` wraps the built program, the icon and
an `Info.plist` into `Data Syncer.app` and signs it — ad hoc by default, or with a Keychain certificate (`--sign`).

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
  Secrets.swift     SecretStore: KeychainSecrets (the app) / MemorySecrets (tests); one secret per destination id
  Shell.swift       running ssh & co: collect output, feed a file on stdin with progress, drain stdout to a file
  SSHStorage.swift  SSHClient (the ssh command line, ControlMaster, askpass, error wording) and SSHStorage
  SSHInfo.swift     read-only view of ~/.ssh: keys, config hosts, agent, known_hosts
  NetworkShare.swift  is smb://host/share mounted (getmntinfo)? if not, mount it (NetFS) → LocalStorage
  Cloud/HTTP.swift    URLSession wrapper (send / upload chunk / download to file), error wording, dates; tests swap the session
  Cloud/OAuth.swift   PKCE sign-in through the browser + a loopback listener on localhost:45873, token refresh, TokenProvider
  Cloud/CloudAccounts.swift  CloudProvider, CloudAccount (accounts.json), CloudSecret (Keychain "cloud:<id>"), each service's OAuth settings
  Cloud/S3Storage.swift      SigV4 signing, ListObjectsV2, multipart uploads, "key/" folder markers
  Cloud/GoogleDriveStorage.swift  Drive v3 with drive.file, path → id cache, resumable uploads
  Cloud/DropboxStorage.swift      API v2, recursive list_folder, upload sessions
  Cloud/OneDriveStorage.swift     Microsoft Graph /me/drive, path addressing, upload sessions
  Cloud/Hashing.swift  SHA-256 / HMAC (CryptoKit)
Sources/DataSyncer/
  DataSyncerApp.swift  the scenes: the main window, the Settings window, the menu commands
  AppModel.swift       the one object the views watch: jobs, history, settings, the run in progress
  RunSession.swift     a run as the views see it, built from RunEvents (throttled progress, a capped log)
  MainWindow.swift     the split view: Sidebar, the toolbar, the running/finished strips, RunDetailsSheet, the empty state
  JobDetailView.swift  the selected job: header, source card, DestinationRow list (reorder, Finder), recent runs
  Editors.swift        JobEditor, FolderPicker (NSOpenPanel, /Volumes)
  CheckSheet.swift     "Check destinations" (Preflight) and the Full Disk Access shortcut
  RunScreen.swift      RunOptionsSheet (full/incremental per destination), RunScreen, SyncPreviewSheet
  RestoreSheet.swift   Restore…: destination → BackupCatalog → point, target, removeDeleted; delete a backup
  RestoreScreen.swift  RestoreSession (from RestoreEvents) and the restore screen
  SettingsView.swift   the Settings tabs; AppearancePane.swift (look, accent, themes + ThemeEditor), AccountsPane.swift
  MenuBarPanel.swift   the menu bar item's panel (status, last run, Run list, Open, Quit), MenuBarIcon, LoginItem (SMAppService)
  Design.swift         the design tokens (type scale, surfaces, radii) and the shared views: Card, GroupedCard, IconTile, Badge, Dot, SectionLabel, CheckRow, StatTile
  Themes.swift         ThemeColor, AccentChoice, CustomTheme, and `Theme` — the colours the views read, applied from settings
  PlainTextField.swift NSTextField-backed text field (and the `Field` form row) the editors use — SwiftUI's drops a trailing space from view in this window
  CloudAccountSheet.swift  per-service setup guide + sign-in; DestinationEditor.swift  every destination kind's form
  Formatting.swift     dates/sizes/durations in words, status lines, colours, small shared views
Tests/DataSyncerCoreTests/  Helpers, PlannerTests, RunnerTests, SafetyTests, SSHTests (private sshd), CloudTests (fake HTTP)
icon/               icon.svg → make_icns.sh → DataSyncer.icns (committed)
```

## The Storage interface

Every destination kind is a `Storage`: `checkReachable`, `exists`, `stat`, `list`, `makeDirectory`,
`remove`, `upload(localURL:to:meta:progress:)`, `download`, `readData`/`writeData`, `freeSpace`,
`makeSymlink`, and `keepsModifiedDates`. The engines never know what is behind it, so a sync to a
USB drive and a sync to S3 run the same code. Paths are relative to the destination's configured
folder. `walk()` lists everything under a folder, leaving out the `.datasyncer` records at the root.

`StorageFactory` turns a `Destination` into a `Storage`; `DefaultStorageFactory` covers local
folders, USB drives (found by name under `/Volumes`), network shares (used where Finder mounted
them, else mounted with NetFS and the Keychain password → `LocalStorage`) and SSH servers
(`SSHStorage`). It takes a `SecretStore`; secrets are looked up by destination id.

**Cloud services** are plain HTTPS through `HTTP` (no SDKs). Each `Storage` reports sizes and dates
*consistently* between `walk`/`list` and `stat`, which is all the sync planner needs (it compares the
destination with what it recorded after writing). Google Drive, Dropbox and OneDrive set the file's
modified date on upload; S3 can't, so its "date" is the upload time everywhere. Folders: S3 uses
"key/" marker objects; the others have real folders. Links throw from `makeSymlink` and are reported
as skipped. Uploads over 8 MB go in chunks (S3 multipart, Drive resumable, Dropbox and OneDrive
upload sessions) so progress and cancellation work. Every provider has `makeRootFolder()` — the
destination folder is created only when the user presses "Make this folder".

**Accounts and secrets:** `CloudAccount` (service, label, client ID) lives in `accounts.json`;
`CloudSecret` (OAuth tokens, Google's client secret, the S3 secret key) in the Keychain under
`cloud:<account id>`. `TokenProvider` refreshes an access token before it expires and writes the new
tokens back; a 401 invalidates it and the request is retried once. Sign-in: `OAuth.signIn` builds the
authorization URL (PKCE S256), opens the browser, and `LoopbackListener` catches the redirect on the
fixed port 45873 (Dropbox and Microsoft need the exact URI registered; Google accepts any loopback port).

**SSH uploads** go to a temporary name; the server checks the byte count (`wc -c`) against the
expected size before `mv` puts the file in place, because the remote `cat` cannot tell a finished
transfer from a cut one. Each `SSHClient` has its own master socket. The askpass script is written once.
Paths are quoted so a csh/tcsh login shell cannot expand `!`. **SSH** uses the Mac's own `/usr/bin/ssh` (owner decision: built-in tools, `~/.ssh` as Terminal
uses it). One master connection per server (`ControlMaster`, a socket under `/tmp/datasyncer-ssh-<uid>`)
and every operation is a short remote command: `find -printf` (GNU) or `find -exec stat -f` (BSD)
for listing — one command for a whole tree —, `cat >` fed from stdin for uploads (with `chmod` and
`TZ=UTC touch -t` to keep permissions and dates), `cat` drained to a file for downloads, `df -Pk`
for free space. A password or key passphrase reaches ssh through `SSH_ASKPASS` (a tiny script that
prints `$DATASYNCER_SSH_SECRET`); without one, `BatchMode=yes` so nothing ever waits for a prompt.
`StrictHostKeyChecking=accept-new` records a new server in known_hosts and refuses a changed one.

## What a run does

`JobRunner.run(job, choices:)`, for each enabled destination in order:

1. **Source** — scanned once per run (`Scanner`): every file, folder and link, nothing skipped. One
   `lstat` per entry. Folders the scan could not read are recorded as *unreadable*: nothing at or under
   them is ever treated as gone from the source (no sync deletion, no incremental "deleted" entry).
2. **Destination** — `factory.storage(for:)`, `checkReachable()` (the folder must already exist;
   Data Syncer never creates it), then `Records.ensure` writes the README and destination record
   if they are not there.
3. **Plan** — `Planner.sync` (against the `sync-state` record and what is at the destination now)
   or `Planner.backup` (full, or incremental against its parent manifest). A sync plan also lists what
   is *in the way* (a file where a folder is wanted, a link where a file is) to replace first, and
   carries a `warning` when it looks like a mistake (an empty source, most of the destination to be
   deleted) — the preview shows it; without a preview the run refuses. The plan is reported in words
   before anything is copied, then the free space is checked against it.
4. **Copy** — for a sync, deletions and replacements come first (so a rename that only changes case
   ends with the new name on every kind of disk), then folders, then files uploaded with progress
   (chunked, so a big file reports as it goes and a cancel takes effect mid-file), then links, then
   folder dates and permissions. Local and SSH copies land under a temporary name and are moved into
   place only when complete — the old copy survives any failure. Every file is reported as copied,
   linked, deleted, skipped (with the reason) or failed; a cancellation propagates as a cancellation.
5. **Records** — a sync saves its state (on the way out too, awaited and outside the cancelled task);
   a backup writes its manifest last — a file it could not copy is left out of the manifest's snapshot
   and listed under `failed`, so the next incremental copies it — and a backup that did not finish is
   removed (detached, so a cancel cannot stop the cleanup). Before any of this, `Records.ensure`
   checks `destination.json`: a folder used by another destination or another existing job is refused.

A failed destination does not stop the next one. The report lists every destination's status,
counts, problems and the backup folder it made.

## Restore

`RestoreEngine.plan` resolves the chain for a restore point (`BackupCatalog.chain`): the full,
then each incremental up to and including the point. `restore` applies them in order into the
chosen folder — files from each backup's `copied` list, folders from its snapshot — and, with
`removeDeleted`, removes what each incremental recorded as deleted — deletions first, then the
backup's folders (clearing a file or link in the way), then its files. Nothing is written or removed
outside the target folder, even through a link an earlier backup restored. A missing or unreadable
link in the chain is refused with a message naming it; files a backup failed to copy are reported as
missing. Before copying it checks the target's free space (a `.check` event). `RestoreEngine.delete`
removes a backup folder on the user's say-so and returns `BackupCatalog.dependents(of:)`.

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

A restore is the same shape: `RestoreSheet` loads the destination's `BackupCatalog` and plans with
`RestoreEngine.plan`; `AppModel.startRestore` runs `RestoreEngine.restore` in a `Task`, feeding a
`RestoreSession` shown by `RestoreScreen` and `RestoringStrip`. A run and a restore never overlap
(`isRunning` covers both).

**Development hooks** (environment variables, see DEVELOPMENT.md): `DATASYNCER_HOME` moves the
jobs/history/settings folder; `DATASYNCER_AUTOSTART=<job name>` starts a run on launch;
`DATASYNCER_AUTOSHEET` opens a sheet or Settings tab; `DATASYNCER_AUTORESTORE` opens Restore… or starts
one; `DATASYNCER_WINDOW=x,y,w,h` places the window.
