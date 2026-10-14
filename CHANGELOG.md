# Changelog

All notable changes to Data Syncer (Keep a Changelog style; dates are when the change was made).

## [0.9.5] — 2026-10-14 — the professional look

A visual pass modelled on what current Mac utilities do (System Settings, Carbon Copy Cloner, Arq,
CleanShot) and Apple's Human Interface Guidelines. Nothing about what the app does, its settings or
its records changed.

### Changed
- One type scale, in `Design.swift`: title 24 bold, headings 17 semibold, section headings 14
  semibold title-case (no more tracked uppercase), body 14, secondary 13, logs 12.5 monospaced, big
  numbers 22 — five sizes instead of nine. Paths in lists use the normal typeface; only logs and
  backup folder names stay monospaced.
- Surfaces: cards are white with a hairline edge and a faint shadow in light mode; in dark mode they
  are a lifted grey with no shadow (surfaces come forward by getting lighter, as Apple does). Panels
  (the run screen's left column) are sunken instead of tinted. A theme's card tint still shows,
  more quietly.
- The job page: the source and each destination carry an icon tile (a rounded square with the
  symbol, like System Settings rows); destinations are one grouped card with inset hairlines
  instead of separate floating cards; recent runs are a grouped list with a status dot, a hover
  highlight and a chevron.
- Sidebar rows: the folder symbol in the accent colour, a touch more height.
- The accent and the good / attention / problem colours have a brighter twin in dark mode (as Apple's
  blue goes from #007AFF to #0A84FF), so links, icon tiles and status text read on a dark ground. Your
  chosen colour is unchanged in the light look.
- Empty states use the same icon tiles. Check marks are the filled circle symbols.
- Run and restore screens use the shared cards and stat tiles.


### Fixed
- "Delete theme", "Delete job", "Remove destination", "Delete backup", "Sign out" and "Clear
  history" were red text on a red button in their confirmation dialogs (macOS draws a destructive
  button that way, in both looks). They now read like Cancel, and Cancel is the default button, so
  Enter and Esc both back out.

## [0.9.3] — 2026-10-14 — Matt's first look: eight UI changes

### Added
- **What goes into the folder**, per destination: *what is inside the source folder* (as before) or
  *the source folder itself* — the destination gets a folder named after the source with everything
  in it; backups and restores carry the name too (`Destination.includeSourceFolder`, `Scanner.Result.nested`;
  three tests).
- **Remove destination…** at the bottom of the destination editor (asks first; nothing at the
  destination is touched).
- Dev hook `DATASYNCER_AUTOSHEET=editDestination[:n]`.

### Changed
- **Appearance** is one **Theme** list: Light, Dark, Follow the system, then your own themes (click
  a line to use it; Edit… and a trash icon on each of yours), with **New…** at the bottom. The accent
  colour section stays below.
- **Check destinations / Restore… / Run…** are real buttons at the top of the job's page instead of
  toolbar items, which macOS draws greyed out in both looks.
- Text is larger throughout: the base size is 14 (was 13) and the small notes went from 11–12.5 to
  12.5–14.
- The destination editor has no "On — runs with the job" switch any more: a new destination starts
  on, and the switch on the job's page is where it is turned off.
- "Most incrementals per chain": the number sits right-justified beside the arrows, in line with
  the other fields.

### Fixed
- Typing a space in a name, a backup title or a path didn't show until the next character: inside
  the app's window SwiftUI's text field dropped the trailing space from view (reproduced with a
  probe that sends key events into the sheet). The editors now use `PlainTextField`, an
  NSTextField the app owns, which keeps its text while you type.

## [0.9.2] — 2026-10-13 — the second review: 47 verified fixes

Every item below was reproduced by a verifier (a throwaway test, probe or screenshot) before it was fixed.

### Fixed (data safety)
- SSH uploads could install a truncated file on cancel or a dropped connection (the remote `cat`
  sees end-of-file and exits 0): the server now checks the byte count before moving the file into
  place, and the part file is removed on every failure path.
- Network shares: an IP address matched another address with the same first octet; addresses now
  only match themselves. Cancelling while a share was still mounting hung the app forever.
- Read-only (0555) source folders made the destination unwritable and backups undeletable: folders
  keep owner rwx.
- Switching a destination from backups to Sync deleted its backups: dated backup folders are never
  extras (the preview says so).
- A source root that could be opened but not listed (Desktop/Documents without Full Disk Access,
  a 0444 folder) scanned as empty and an incremental recorded every file as deleted: the scan fails.
- S3 crashed on a bucket or region with a space; OneDrive listed a destination as empty when the
  typed folder's case differed, and on a delta 404; Dropbox and OneDrive accepted a file as the
  destination folder.
- Dropbox/OneDrive chunk retries after a lost reply (409 incorrect_offset / 416) failed the file:
  they resume from the service's offset. A revoked sign-in made one token request and one identical
  problem per file: the refusal is remembered and the destination stops after one.
- Removing a destination and adding a new one on the same folder was refused forever; renaming a
  job orphaned its backups; a case-only rename with deletions off re-copied every run; restore
  refused to remove a deleted link; records could be written through a planted `.datasyncer` link;
  the wipe warning counted folders against files; a foreign error during a cancel read as "failed";
  240-byte file names failed; the runner's default for other jobs was open.
- Closing one SSH client cut another's command to the same server; the askpass script was
  rewritten on every call (a parallel client found none); `!` failed on csh/tcsh login shells;
  download deleted the local file before transferring; a 0755 control folder was refused.

### Fixed (app)
- The sync preview no longer appears only on the run screen; Return means Skip when a wipe is
  flagged; a duplicated job starts with its destinations off and says why; sheets and alerts raised
  from Settings show there; Run… no longer runs a full Preflight per destination; the theme editor
  previews the Look; a finished restore is kept, recorded in history and notified; the SSH sign-in
  method is stored, not inferred; Edit… no longer reads the secret (no Keychain prompt); a job can't
  be deleted while its restore runs; whole-row recent runs and history double-click; theme colours
  survive the picker; and the wording/accessibility items from the list.

### Fixed (scripts and docs)
- A relative `--to` resolved against the repo; a failed signature left a half-made app; `--to
  build` deleted the app it just built; compile errors were invisible after a failed test run;
  `--check` exited 0 on an unsupported macOS; `-o` help; the red-suite sentence; "two targets";
  the `http://` limits of local networking; the user guide's missing items.

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
