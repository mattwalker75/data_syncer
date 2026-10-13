# Records, folder names and chains

## What is written beside your copies

Every destination folder Data Syncer has used holds a hidden `.datasyncer` folder:

| File | What it is |
| --- | --- |
| `.datasyncer/README.txt` | A note for anyone who finds the folder: *This is metadata used by the Data Syncer tool that is used to run adhoc backups and syncing of data from a source to one or more destinations. Seeing this means this is or was a destination used by the Data Syncer tool.* |
| `.datasyncer/destination.json` | Which job and destination use this folder, its mode, and since when. Checked at every run: a folder another destination (of this or another existing job) already uses is refused — two jobs mirroring one folder would erase each other's files. A record from a job that no longer exists is taken over. |
| `.datasyncer/sync-state.json` | (Sync) Each file as it was written here last time — size and modified date at the destination, and the source file it came from. The next sync compares the source with this record *and* checks the copies still match it, so a copy changed or removed at the destination is put right. |

Each dated backup folder holds its own record, `<backup>/.datasyncer/manifest.json`:

| Field | Meaning |
| --- | --- |
| `kind` | `full` or `incremental` |
| `createdAt`, `jobName`, `title` | when, which job, the title used in the folder name |
| `basedOn` | the folder name of the backup this incremental is measured against (none for a full) |
| `snapshot` | the **whole source** as it was at this backup: every file, folder and link with size and modified date |
| `copied` | what this folder actually contains — a full: everything; an incremental: only what changed |
| `failed` | files this backup could not copy (unreadable, locked); they are left out of `snapshot`, so the next incremental copies them, and a restore lists them as missing rather than pretending |
| `deleted` | gone from the source since `basedOn` (empty for a full); never includes anything under a source folder the scan could not read |

Because every manifest carries the whole snapshot, the next incremental is planned from it alone,
and a restore knows every folder to recreate. Nothing is kept only on the Mac that made the backup:
another Mac, or a fresh install, can continue a chain and restore from it.

The records are small (a line per file). Leave them in place. If you delete a whole backup folder,
its record goes with it, which is what you want.

## Backup folder names

`2026_10_20_1432_Full_Work_documents` and `2026_10_20_1432_Incremental_Work_documents`:

- year, month, day, hour and minute, so Finder sorts them in order;
- `Full` or `Incremental`;
- the title: the destination's *Backup title*, or the job's name, with anything that is not a
  letter, digit, `-` or `_` turned into `_` (runs of `_` collapsed to one; an empty title becomes
  `backup`) so the name works on every drive and service. Backups of one title are a family of
  their own: another title's backups in the same folder are never part of its chains.

Two backups to the same destination in the same minute are refused ("wait a minute and run again").

## Chains

A **chain** is a full backup and the incrementals that depend on it. Which backup an incremental is
measured against is set per destination:

- **since the last incremental** — the newest backup in the current chain (an increment of increments; the smallest backups);
- **since the last full** — the chain's full backup (each incremental is complete on its own).

Each destination also sets the **most incrementals per chain**. When the chain reaches it, the next
backup must be a full one: asked for an incremental, the run says so and stops; left to choose, it
makes a full. The pre-run check reports where a chain stands ("7 of 10").

## Deleting backups

Data Syncer never deletes a backup on its own. Delete a dated folder in Finder (or in the app).
The catalog is read fresh at every run, so a deleted backup breaks nothing — except restores of
the incrementals that depended on it, which say so: *"The backup … is missing at the destination,
so backups that depend on it cannot be restored."* Deleting a full ends its chain; the next
incremental is measured against the newest full that is still there, and if none is, the next
backup is a full.

A backup-named folder without a readable record (made by hand, or damaged) is listed as such and
never used as part of a chain.

## Restore

A restore point is any full or incremental backup. Data Syncer puts back the chain's full backup,
then each incremental up to and including the point, into the folder you choose. **Remove files
that were deleted** decides what happens to a file an incremental recorded as deleted: with it on,
the file is gone at the end (as it was in the source then); with it off, the file is left for you
to sort out. Restores are whole backups; restoring one file or folder may come later.
