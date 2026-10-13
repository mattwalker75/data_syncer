# Changelog

All notable changes to Data Syncer (Keep a Changelog style; dates are when the change was made).

## [0.9.1] — 2026-10-13 — the deep review: ~45 fixes and enhancements

### Fixed (data safety)
- An unreadable source subfolder is never treated as deleted: sync deletions under it are held
  back (and said so), incrementals record no deletions there.
- A file a backup could not copy is left out of its snapshot and listed as `failed`; the next
  incremental copies it; a restore lists it as missing instead of pretending.
- Nothing is written through a link at the destination (a link replaced by a real folder of the
  same name is removed, not followed); every local write/remove refuses a path that resolves outside
  the destination; the same in restore.
- A rename that only changes case keeps the file: deletions and replacements run before copies.
- Copies land under a temporary name and are renamed into place (local and SSH), so the old copy
  survives a failed or cancelled copy and nothing half-written sits under a real name.
- A file that became a folder (or the reverse) is replaced instead of failing every run.
- An obvious wipe (empty source, most of the destination to go) is flagged in the preview and
  refused without one.
- A folder already used by another destination or another existing job is refused
  (`destination.json` is now checked); the catalog is filtered by backup title.
- A cancelled run lists the remaining destinations; a cancellation on the last file is reported as
  Cancelled, not "finished with problems"; the sync record is saved on the way out (awaited);
  half-made backups are removed even after a cancel (local, SSH and cloud); S3 multipart and
  OneDrive sessions are aborted after a cancel.
- SSH: a remote write that fails no longer kills the app (SIGPIPE); commands run under `sh -c`
  (csh/fish logins); a root that is a link, has a trailing `/` or starts with `~/` works; a listing
  with one unreadable entry is kept; `--` before paths; the control folder's ownership is checked
  and the askpass script rewritten every time; the connection is closed after each destination.
- Network shares are matched by the volume's remount URL (host + share), never by share name
  alone; IPv6 hosts; mounting is async and cancellable.
- Cloud: Dropbox's API-Arg header is ASCII-escaped (non-ASCII names work); Google Drive encodes
  `+` and resolves duplicate names to the newest, honours the 308 Range, handles empty files, lists
  the whole tree in one request; S3 raises per-key delete errors, validates the address, uses
  path-style for dotted buckets, decodes numeric XML entities; OneDrive uses `$top=200` and delta
  listing; a cancelled request is a cancellation; 429/5xx retried with Retry-After; one token
  refresh at a time; the sign-in listener is loopback-only (no firewall prompt) and cancellable.
- App: the sync preview is a sheet on the window (it appeared only on the run screen); its answer
  is taken once (no double resume); a USB destination needs a folder; a finished run's summary
  stays reachable (strip + Show Last Run); restore rows show Failed; the theme editor previews
  without saving; the drive picker shows an unplugged drive; cloud kinds start with their first
  account; switching SSH sign-in method drops a stale secret; the restore sheet loads once, blocks
  while deleting, expands `~`, closes its connection on cancel; alerts inside sheets show in place.
- Scripts: a failed compile is never packaged; a failed copy is reported; `--to` with a missing
  folder says so; `codesign --deep` dropped; usage descriptions in Info.plist; test count parsed
  robustly; a red suite asks before installing.

### Added
- Reorder destinations (Move up/down); Edit… link on each row; Show in Finder for the source and
  local/USB/share destinations; click a recent run for its full report (Copy report); See all runs;
  Rename…/Duplicate (⌘D) in the sidebar; Delete key; Show Last Run (⌘L); the Run sheet says what
  each chain allows before starting; restoring into the source or the destination itself is
  flagged; Choose… can make the restore folder; confirmations for Clear history, theme delete and
  Sign out; notification permission asked when the setting is turned on, status shown; iCloud and
  home paths shortened; folder dates and permissions kept; accessibility labels on icon-only
  controls; `--universal`, `--sign IDENTITY`, `--skip-tests` in the scripts; docs on Open Anyway
  (macOS 15), the chip question and keeping Full Disk Access across rebuilds.
- Performance: one `lstat` per scanned entry; `walk` no longer O(n²) on folder count; the backup
  catalog is indexed; Drive and OneDrive list a whole tree in one request.
- Tests: 69, including `SafetyTests` for every data-loss scenario above and a deterministic cancel
  fixture.

## [0.9.0] — 2026-10-13 — every step built; ready for real-world testing

### Added
- 2026-10-13: **Step 6 — appearance and polish.** Settings → Appearance: the accent colour (nine
  presets or any colour), named custom themes (look, accent, good / attention / problem colours,
  sidebar and card tints) with a live preview, Use / Edit / Delete, and "System colours" to go back.
  The run screen offers "Give Data Syncer Full Disk Access…" right under a source check that needs
  it. Version 0.9.0.
- 2026-10-13: **Step 5 — the cloud services.** Amazon S3 (and S3-compatible: existing bucket, region,
  optional service address, folder in the bucket; SigV4; multipart uploads; never creates buckets),
  Google Drive (drive.file permission, resumable uploads, modified dates kept), Dropbox (upload
  sessions, client_modified kept) and OneDrive (Graph, upload sessions, dates kept). Cloud accounts
  added once and shared by destinations: a one-time setup guide per service in the app, the sign-in
  in the browser with PKCE and a loopback listener (localhost:45873), tokens in the Keychain,
  automatic refresh. "Make this folder" and "Test connection" in the destination editor; accounts
  listed under Settings → Accounts with Sign out. Links are skipped and reported on cloud
  destinations. Core: `HTTP`, `OAuth`/`TokenProvider`, `CloudAccountStore`, `CloudSecret`,
  `LayeredSecrets`; the S3 kind now carries its account. A half-finished backup folder is now
  removed before the run reports (was fire-and-forget). 48 tests (fakes for the services).
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
