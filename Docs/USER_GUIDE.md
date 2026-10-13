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
  **Restore…**, **Run…**.

## Making a job

**New job** asks for a name and the source folder. Then **+ Add destination** on the job's page:

- **Name** — what you'll call it ("Backup drive", "Second copy").
- **Where** —
  - a **folder on this Mac** (which includes drives and shares that are already connected) or a
    folder in **iCloud Drive**;
  - a **USB drive** by name: the drive is found under its name whenever you run, so it can be
    plugged into any port;
  - a **network share** (`smb://server/share`, or `afp://` for older Macs) with a folder inside it.
    If the share is already connected in Finder it is used as it is; otherwise Data Syncer connects
    it when you run, with the user name and password you give (the password goes in your Keychain).
    Leave the user name empty for a guest share;
  - an **SSH server (SFTP)**: server, port, user name and the folder on the server (absolute, or
    relative to the user's home). Sign in *like Terminal* (whatever `ssh` would use: keys in
    ssh-agent, `~/.ssh/config`, the default keys), with *a key file* (pick one of the keys in
    `~/.ssh`, with its passphrase if it has one), or with *a password*. "From ~/.ssh/config" fills
    the fields from a config entry. Settings → Accounts shows what this Mac has. The first time a
    server is used its identity is remembered in `~/.ssh/known_hosts`, as Terminal would;
  - Amazon S3, Google Drive, Dropbox and OneDrive: the next step.

  Every folder must already exist — Data Syncer never creates a destination folder.
  **Test connection** tries the share or server with what you've typed, without copying anything.
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

## Restoring

**Restore…** (toolbar or Job menu) works with the job's Full only and Full + incremental
destinations — a Sync destination is a plain copy you can open in Finder.

1. **From** — pick the destination. Data Syncer looks there and lists its backups, newest first:
   kind, date, how many files it holds, and for an incremental which backup it is measured since.
   A folder named like a backup whose record is missing or damaged is listed as such and can't be
   restored.
2. Click the **restore point**. The line under the options says what will be applied — for an
   incremental, the chain's full backup and then each incremental up to and including the point. If
   a link in the chain is gone, it says which, and Restore stays off.
3. **Restore into** — a folder on this Mac; an empty one is best. Existing files with the same names
   are replaced; nothing else there is touched.
4. **Remove files the backups recorded as deleted** — on, the result matches the source as it was at
   the restore point; off, those files are left for you to look at.
5. **Restore**. The restore screen shows the checks (free space), the backups as they are applied,
   progress and the file-by-file log; **Back to jobs** leaves it running with a strip, like a run.
   When it finishes, **Show in Finder** opens the folder.

**Deleting old backups:** the trash icon on a row (or right-click → Delete this backup…). Data Syncer
says which incrementals depend on the backup and could no longer be restored, and asks before
deleting. It never deletes a backup on its own.

## Settings (the gear, or ⌘,)

- **General** — where the jobs and settings live, and a shortcut to Full Disk Access (needed when a
  source is in Desktop, Documents, Downloads or another folder macOS protects and a run says it can't
  be read).
- **Appearance** — Light, Dark, or follow the system. Accent colours and your own themes come in a
  later step.
- **Accounts** — what this Mac has for SSH (the keys in `~/.ssh`, what ssh-agent has loaded, the
  hosts in `~/.ssh/config`, how many servers `known_hosts` remembers — read only, with a button to
  open the folder), and the sign-ins Data Syncer keeps in your Keychain, each with **Forget**.
- **Notifications** — the notification when a run finishes.
- **Run history** — every run, newest first; **Clear history…** forgets them (nothing at any
  destination is touched).

## Deleting things

Data Syncer never deletes a backup. Delete old dated folders yourself in Finder; the next run just
sees they are gone (an incremental restore that depended on a deleted backup says so). Deleting a job
or a destination in the app removes only the entry — the copies stay where they are.
