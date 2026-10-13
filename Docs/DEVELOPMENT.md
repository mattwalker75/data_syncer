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
| `CloudTests.swift` | `FakeHTTP` (a URLProtocol answering from memory) and `FakeBucket` (enough S3 for the engines): SigV4 against Amazon's published example, list parsing and URL encoding, a full sync + backup + restore + delete through S3 (multipart included), DeleteObjects errors, numeric entities, address validation, dotted buckets, folder-missing and bad-key messages; token refresh and save-back, refresh failure wording, Google Drive (whole-tree listing, `+` encoding, duplicate names), Dropbox (ASCII header, 401 retry), OneDrive (delta listing) stat and missing-folder messages; retries on 429 and cancellation mapping; accounts and secrets round trip, PKCE |
| `SSHTests.swift` | parsing (GNU/BSD find output, ssh config incl. tabs and `=`, keys, share matching by remount URL incl. IPv6, error wording, secrets) and **real round trips against a private sshd** the test starts itself (`TestSSHServer`: `/usr/sbin/sshd` on a random high port with its own host and client keys, `StrictModes no`; skipped if it can't start): storage basics, a sync + incremental backup + restore over SSH, a failed remote write (no SIGPIPE), a linked root / trailing slash / `~/` / partial listing, awkward file names through real ssh, a passphrase key through askpass, a wrong key's message |
| `SafetyTests.swift` | the data-safety rules, each with the scenario that would have lost data: an unreadable source subfolder is never treated as deleted (sync and incremental); a failed backup copy is caught up by the next incremental and reported by restore; writes never escape through a link (sync and restore); a case-only rename keeps the file; the old copy survives a failed copy; cancel mid-sync keeps the old file and saves the record; a cancelled backup leaves no half folder (deterministic, via `GatedStorage`); file↔folder type changes; an obvious wipe is refused without a preview; a folder used by another job is refused; the catalog is filtered by title; a cancelled run lists every destination; folders keep dates and permissions; the check leaves no trace and reports a corrupt record |
| `RunnerTests.swift` (BackupDeletionTests) | which backups depend on which; deleting a backup from the app strands only its dependents; the restore's free-space check |
| `RunnerTests.swift` (HistoryAndPreviewTests) | a declined sync preview leaves the destination alone and reports it as skipped; the history keeps the newest first, capped, and "last result" ignores skipped runs |
| `RunnerTests.swift` | real runs: a sync mirrors the source with records, dates and permissions kept and links made; deleting is per destination; a tampered copy is put right; a missing destination folder fails that destination and the run carries on; a USB drive that isn't connected; full + incremental chains, the per-chain limit, "since the last full", full-only folders, same-minute refusal, cancel leaves no half folder; restore with and without removing deleted files, a deleted full breaks only what depends on it; the pre-run checks; jobs save and load |

Tests never touch real user folders or Application Support (`JobStore(url:)` points at a scratch file).

## Trying the app without touching your real jobs

```bash
DATASYNCER_HOME=/tmp/ds-home "build/Data Syncer.app/Contents/MacOS/Data Syncer"
```

`DATASYNCER_HOME` points the jobs, history and settings files at another folder. Two more hooks exist
for looking at screens: `DATASYNCER_AUTOSTART="<job name>"` runs that job as soon as the window is
up, `DATASYNCER_AUTOSHEET=newJob|newDestination|check|run|settings[:tab[:provider]]` opens that sheet
or Settings tab (and the add-account sheet for a provider), `DATASYNCER_AUTORESTORE="<job name>"` opens Restore… for it (or
`"<job name>|<destination name>|<folder>"` restores the newest backup there straight away), and
`DATASYNCER_WINDOW=100,100,1120,760` puts the window at that place on the main display (handy for
`screencapture -l <window id>`). All are for development only and do nothing when unset. The jobs file format is plain JSON (`JobsFile`), so a test home can be written by hand.

## What has not been tried against the real services

The cloud code is written against the services' documented APIs and tested against fakes. Nothing
here has talked to a real Google, Dropbox, Microsoft or Amazon account yet. Expect the first real
sign-in and the first real run to each service to need a look (query details, consent screens,
redirect-URI registration). The SSH code *has* been run for real, against a private sshd.

## Conventions

- **Messages are sentences for a person**; every error is a `DSError` with the message the user sees.
- **Nothing is deleted on a hunch**: the only deletions are a sync's extras (per-destination switch, previewed), a restore's recorded deletions (switch), and a backup folder that did not finish.
- **The core never knows about screens**; it reports `RunEvent`s and returns a `RunReport`.
- **Dates** in records are ISO-8601 with milliseconds; file modified times are seconds since 1970.
- **Commits:** one per feature with a dated CHANGELOG entry; never push — Matt pushes.
