# Changelog

All notable changes to Data Syncer (Keep a Changelog style; dates are when the change was made).

## [Unreleased]

### Added
- 2026-10-13: **Step 4 — network shares and SSH.** Network share destinations (`smb://` / `afp://`):
  used where Finder already mounted them, otherwise connected by the app with the Keychain password
  (NetFS, no window). SSH (SFTP) destinations through the Mac's own `ssh`: sign in like Terminal
  (agent, ~/.ssh/config, default keys), with a chosen key file (+ passphrase) or a password; one
  shared connection per server; listing in one remote `find`; uploads keep dates and permissions;
  plain-English messages for refused sign-ins, unknown hosts, changed host keys. Destination editor
  forms for both with "Test connection" and "From ~/.ssh/config". Settings → Accounts: keys in ~/.ssh,
  ssh-agent, config hosts, known_hosts count, and the sign-ins kept in the Keychain (Forget). Core:
  `SecretStore` (Keychain / memory), `Shell`, `SSHClient`/`SSHStorage`, `SSHInfo`, `NetworkShare`,
  `Storage.walk` overridable. 38 tests, including real round trips against a private sshd.
- 2026-10-13: **Step 3 — restore.** Restore… (toolbar, Job menu): pick one of the job's backup
  destinations, see its backups (kind, date, files, size, what each incremental is measured since,
  unreadable records flagged), choose the restore point, the folder to restore into and whether files
  recorded as deleted are removed; the chain to apply is shown, and a broken chain says which link is
  missing. The restore screen (checks incl. free space, the backups as they are applied, progress,
  counts, log, Show in Finder), Back to jobs with a restoring strip, cancel. Delete a backup from the
  list, after a warning that names the incrementals that depend on it. Core: `BackupCatalog.dependents`,
  `RestoreEngine.delete`, a free-space check and `.check` events in `RestoreEngine.restore`. 27 tests.
- 2026-10-13: **Step 2 — the windows.** The main window (Theme 1: jobs down the left with their last
  run, the selected job's page with its source and size, destinations with mode badges, last-run
  lines and on/off switches, recent runs; New job and the Settings gear at the bottom of the sidebar;
  Check destinations / Restore… / Run… in the toolbar). Job and destination editors (folders on this
  Mac, iCloud Drive, USB drives by name with a drive picker; all three modes with their options). The
  Run… sheet (full / incremental / let Data Syncer choose, per destination), the run screen (checks,
  destinations, progress, counts, file-by-file log, summary), the sync preview (go ahead / skip),
  Back to jobs with the running strip (Watch / Cancel run) and Run… disabled meanwhile, cancel,
  no-sleep during a run, a notification with a summary when a run finishes. Settings: General (files,
  Full Disk Access shortcut), Appearance (light / dark / system), Accounts and the rest of Appearance
  as placeholders, Notifications, Run history (table + clear). Core: `confirmSync` preview hook,
  `RunHistory` (runs.json, newest first, capped at 500), `RunProgress` (renamed from `Progress`),
  `DATASYNCER_HOME`. 25 tests. User guide in Docs/USER_GUIDE.md.
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
