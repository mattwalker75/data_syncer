# Using Data Syncer

Data Syncer copies a folder on your Mac to one or more places, when you tell it to. Nothing happens
on its own: open the app, pick a job, press **Run…**.

## The main window

- **Jobs** are down the left. Click one to see it. Under each name: how many destinations it has and
  when it last ran; an orange dot means the last run needs a look.
- **+ New job** and the **gear** (Settings) are at the bottom of the list.
- The selected job's page shows its **source** (the folder it copies from, with its size), its
  **destinations**, and its **recent runs**. Double-click a destination to change it; right-click for
  more. The switch on the right turns a destination off without removing it — a paused destination
  is skipped until you turn it on again.
- The toolbar: **Check destinations** (is everything reachable and writable? — copies nothing),
  **Restore…** (coming in the next step), **Run…**.

## Making a job

**New job** asks for a name and the source folder. Then **+ Add destination** on the job's page:

- **Name** — what you'll call it ("Backup drive", "Second copy").
- **Where** — a folder on this Mac (which includes drives and shares that are already connected,
  and iCloud Drive), or a **USB drive** by name: the drive is found under its name whenever you run,
  so it can be plugged into any port. The folder inside it must already exist — Data Syncer never
  creates a destination folder. Network shares, SSH, S3, Google Drive, Dropbox and OneDrive arrive
  in later steps.
- **Mode** — *Sync* (the destination is made to match the source; a switch decides whether files the
  source no longer has are deleted from the copy), *Full only* (every run makes a new dated folder
  with a complete copy), or *Full + incremental* (dated full and incremental backups; you choose
  whether incrementals are measured since the last incremental or since the last full, and how many
  incrementals a chain may have before a full is required). See [RECORDS.md](RECORDS.md) for the
  folder names and how chains work.
- **Backup title** — the name used in the dated folders (`2026_10_20_1432_Full_<title>`); the job's
  name if left empty.

## Running

**Run…** shows the destinations in the order they'll run. For a Full + incremental destination you
pick **Full**, **Incremental**, or **Let Data Syncer choose** (an incremental when the chain allows
one, otherwise a full). **Start** begins.

The run screen takes over the window: the checks on the left, each destination with its status, and
on the right the progress, the counts and what is happening file by file. A **Sync** destination
first shows a **preview** — what will be copied and what will be deleted — and waits for **Go ahead**
or **Skip this destination**.

- **Back to jobs** returns to the main window while the run carries on; a strip at the top shows
  where it is, with **Watch** (back to the run screen) and **Cancel run**. Run… is unavailable until
  the running job finishes; everything else works.
- **Cancel** stops after the file in progress. A backup that didn't finish is removed so it is never
  mistaken for a real one; a sync keeps what it already copied.
- A destination that fails does not stop the next one. When the run ends you get a summary on the
  run screen, a line in the job's recent runs, and (if turned on in Settings) a notification.
- Your Mac won't go to sleep while a run is going.

## Settings (the gear, or ⌘,)

- **General** — where the jobs and settings live, and a shortcut to Full Disk Access (needed when a
  source is in Desktop, Documents, Downloads or another folder macOS protects and a run says it can't
  be read).
- **Appearance** — Light, Dark, or follow the system. Accent colours and your own themes come in a
  later step.
- **Accounts** — cloud and server sign-ins (later step).
- **Notifications** — the notification when a run finishes.
- **Run history** — every run, newest first; **Clear history…** forgets them (nothing at any
  destination is touched).

## Deleting things

Data Syncer never deletes a backup. Delete old dated folders yourself in Finder; the next run just
sees they are gone (an incremental restore that depended on a deleted backup says so). Deleting a job
or a destination in the app removes only the entry — the copies stay where they are.
