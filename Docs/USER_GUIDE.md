# Using Data Syncer

Data Syncer copies a folder on your Mac to one or more places, when you tell it to. Nothing happens
on its own: open the app, pick a job, press **Run…**.

## The main window

- **Jobs** are down the left. Click one to see it. Under each name: how many destinations it has and
  when it last ran; an orange dot means the last run had problems. Right-click a job to rename it or
  change its source, duplicate it, run it or delete it (Delete key works too). Renaming a job keeps its
  backups going under their old title. A duplicate starts with its destinations turned off: they still
  point at the original's folders, which two jobs can't share — give each a folder of its own, then
  turn it on.

  **Keyboard:** ⌘N new job · ⌘D duplicate · ⌘R run · ⌘K check destinations · ⌘L show the last run ·
  ⌘. cancel · ⌘, settings.
- **+ New job** and the **gear** (Settings) are at the bottom of the list.
- The selected job's page shows its **source** (the folder it copies from, with its size and a
  button to show it in Finder), its **destinations** in the order they run, and its **recent runs**.
  Each destination row has an **Edit…** link (double-click works too); right-click for more: turn it
  off, move it up or down, show its folder in Finder, remove it. The switch on the right turns a
  destination off without removing it — a paused destination is skipped until you turn it on again.
  Click a recent run to see everything that happened (and copy the report).
- At the top of the page: **Check destinations** (is everything reachable and writable? — copies
  nothing), **Restore…**, **Run…**.

## The menu bar item

While Data Syncer is open there is a small symbol by the clock. Click it for a panel that shows
whether a job is running and how far it is (with **Cancel**), how the last run went, a **Run** list
(click a job to start it now — a Full + incremental destination gets an incremental when its chain
allows one, otherwise a full; a sync destination still shows its preview in the app, which comes
forward for it), **Open Data Syncer**, and **Quit**. There are no logs and no settings in the panel;
**Open Data Syncer** is one click away for those. The symbol turns into a sync arrow while a job runs
and carries a mark after a run with problems.

Closing the window does not quit: the app stays in the Dock and the menu bar, and a run that is
going carries on. **Quit** (in the panel, or ⌘Q) ends everything; if a run is going it asks first.
**Settings → General → Open Data Syncer at login** puts the item there from the moment you sign in
(macOS may ask you to allow it under Login Items). Nothing runs on its own either way.

## Making a job

**New job** asks for a name and the source folder (it must exist and be readable). Then
**+ Add destination** on the job's page:

- **Name** — what you'll call it ("Backup drive", "Second copy").
- **Where** —
  - a **folder on this Mac** (which includes drives and shares that are already connected) or a
    folder in **iCloud Drive**;
  - a **USB drive** by name, with a folder on it: the drive is found under its name whenever you run,
    so it can be plugged into any port. A whole drive is never a destination — always a folder on it;
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
  - **Amazon S3** (or an S3-compatible service such as Backblaze B2, Wasabi or MinIO): an account
    (access key ID + secret key, saved once under Settings → Accounts or with **Add account…**), the
    bucket, its region, the service's address for non-Amazon services (`https://…`; plain `http://`
    only works for a server on your own network named by IP address, a bare name or a `.local` name),
    and a folder in the bucket. Data Syncer never creates buckets.
  - **Google Drive, Dropbox, OneDrive**: an account you sign in to once (the service's own sign-in
    page opens in your browser; Data Syncer never sees your password; tokens go in your Keychain)
    and a folder path in the service. The first time, **Add account…** shows a short one-time setup
    guide: each service only lets an app in through a "client" or "app" you register yourself in its
    developer console — a few minutes, free — and the guide walks through it. One account can serve
    many destinations. Google Drive is asked only for the `drive.file` permission, so it sees only
    the folders and files Data Syncer makes itself.

  Every folder must already exist — Data Syncer never creates a destination folder on its own. For
  the cloud services, **Make this folder** in the editor creates it when you ask (for Google Drive
  it is the only way, since the app can't see folders it didn't make). **Test connection** tries the
  share, server or service with what you've typed, without copying anything.

  **One folder, one destination.** A folder that another destination (of this job or another) already
  uses is refused — two jobs mirroring one folder would erase each other's files. A folder left behind
  by a job that no longer exists is simply taken over.

- **What goes into the folder** — *what is inside the source folder* (the destination folder holds
  the source's files and folders directly; this is how Data Syncer always worked) or *the source
  folder itself* (the destination gets a folder with the source's name, and everything inside that:
  `Backups/Work documents/…`, and each dated backup holds `Work documents/…`). Pick the second when
  one destination folder is shared by several jobs' backups, or when you want the copy to look
  exactly like the original in Finder. A restore gives the folder back under its own name. Changing
  this on a destination that already has copies makes the old layout look like extra files: a sync
  will offer to delete them (the preview shows it), and a backup chain starts over with a full.

  Links (aliases made with `ln -s`) can't be kept in cloud services; the run reports each one as
  skipped and carries on. Dates: Google Drive, Dropbox and OneDrive keep each file's modified date;
  S3 can't, so Data Syncer remembers what it wrote and compares against that.

- **Mode** — *Sync* (the destination is made to match the source; a switch decides whether files the
  source no longer has are deleted from the copy), *Full only* (every run makes a new dated folder
  with a complete copy), or *Full + incremental* (dated full and incremental backups; you choose
  whether incrementals are measured since the last incremental or since the last full, and how many
  incrementals a chain may have before a full is required). See [RECORDS.md](RECORDS.md) for the
  folder names and how chains work. Backups of one title never mix with another title's in the same
  folder.
- **Backup title** — the name used in the dated folders (`2026_10_20_1432_Full_<title>`); the job's
  name if left empty.

A new destination is on. The switch on the job's page turns it off (skipped until you turn it on
again) — the editor doesn't have one. **Remove destination…** at the bottom of the editor takes it
off the job (nothing at the destination is touched); so does right-click → Remove… on the job's page.

## Running

**Run…** shows the destinations in the order they'll run. For a Full + incremental destination it
says what the chain allows right now ("an incremental is possible (3 of 10)", or "the next backup
will be a full one") and you pick **Full**, **Incremental**, or **Let Data Syncer choose** (an
incremental when the chain allows one, otherwise a full). **Start** begins.

The run screen takes over the window: the checks on the left, each destination with its status, and
on the right the progress, the counts and what is happening file by file. A **Sync** destination
first shows a **preview** — what will be copied and what will be deleted — and waits for **Go ahead**
or **Skip this destination**. If the preview looks like a mistake (the source is empty, or most of
the destination would be deleted) it says so in orange first.

- **Back to jobs** returns to the main window while the run carries on; a strip at the top shows
  where it is, with **Watch** (back to the run screen) and **Cancel run**. If a preview is waiting
  for you, the strip says so and the button reads **Answer**. Run… and Restore… are unavailable until
  the running job finishes; everything else works. When the run ends the strip stays, with **See
  summary** and **Dismiss**, until you've looked (Job → Show Last Run, ⌘L, opens it too).
- **Cancel** stops as soon as it can, even part-way through a big file. Nothing half-written is ever
  left under a real file name: the old copy stays until the new one is complete (over SSH the server
  checks the size before the file is put in place). Folder dates and permissions are kept too. A backup that
  didn't finish is removed so it is never mistaken for one; a sync keeps what it already copied and
  its record is saved on the way out.
- A destination that fails does not stop the next one. When the run ends you get a summary on the
  run screen, a line in the job's recent runs, and (if turned on in Settings) a notification.
- Your Mac won't go to sleep while a run is going.

### What a run never does

- It never deletes anything at a destination that it couldn't read in the source. If a folder in the
  source can't be read (permissions, no Full Disk Access), its copies are left alone and the run says
  so ("deletions held back").
- It never writes through a link: if a link at the destination now has a real folder's name in the
  source, the link is replaced, not followed.
- A file a backup could not copy is listed as failed in that backup; the next incremental copies it,
  and a restore says it is missing rather than pretending.

## Restoring

**Restore…** (toolbar or Job menu) works with the job's Full only and Full + incremental
destinations — a Sync destination is a plain copy you can open in Finder.

1. **From** — pick the destination. Data Syncer looks there and lists its backups, newest first:
   kind, date, how many files it holds, and for an incremental which backup it is measured since.
   A folder named like a backup whose record is missing or damaged is listed as such and can't be
   restored.
2. Click the **restore point**. The line under the options says what will be applied — for an
   incremental, the chain's full backup and then each incremental up to and including the point —
   and lists any files the backups never managed to copy. If a link in the chain is gone, it says
   which, and Restore stays off.
3. **Restore into** — a folder on this Mac; an empty one is best (**Choose…** can make one).
   Existing files with the same names are replaced; nothing else there is touched. Restoring into
   the job's own source, or into the backup destination itself, is flagged in orange first.
4. **Remove files the backups recorded as deleted** — on, the result matches the source as it was at
   the restore point; off, those files are left for you to look at.
5. **Restore**. The restore screen shows the checks (free space), the backups as they are applied,
   progress and the file-by-file log; **Back to jobs** leaves it running with a strip, like a run.
   When it finishes, **Show in Finder** opens the folder.

**Deleting old backups:** the trash icon on a row (or right-click → Delete this backup…). Data Syncer
says which incrementals depend on the backup and could no longer be restored, and asks before
deleting. It never deletes a backup on its own.

## Settings (the gear, or ⌘,)

- **General** — where the jobs and settings live, **Open Data Syncer at login** (the menu bar item
  from sign-in), and a shortcut to Full Disk Access. When a source is
  in Desktop, Documents or Downloads, macOS first asks with its own prompt the first time — allow it;
  only if a run still says the folder can't be read is Full Disk Access needed. (With the standard
  build, Full Disk Access has to be granted again after each rebuild — see SCRIPTS.md for a way to
  avoid that.)
- **Appearance** — one **Theme** list: **Light**, **Dark**, **Follow the system**, then your own
  themes; click a line to use it. **New…** at the bottom opens the theme editor (the look, the accent,
  the good / attention / problem colours and optional tints for the sidebar and cards — the windows
  follow along while you adjust, nothing is saved until **Save and use**); each of your themes has
  **Edit…** and a trash icon (deleting asks first). Below, the **accent colour** (nine to pick from,
  or any colour of your own) applies to Light, Dark and Follow the system; a theme brings its own.
- **Accounts** — what this Mac has for SSH (the keys in `~/.ssh`, what ssh-agent has loaded, the
  hosts in `~/.ssh/config`, how many servers `known_hosts` remembers — read only, with a button to
  open the folder); the share and SSH sign-ins Data Syncer keeps in your Keychain, each with
  **Forget**; and the cloud accounts (Google Drive, Dropbox, OneDrive, Amazon S3) with **Add
  account…** and **Sign out** (asks first). Signing out forgets the tokens; destinations that used the
  account say so until you pick another.
- **Notifications** — the notification when a run finishes. Turning it on asks macOS for permission
  right away, and the pane says whether notifications are allowed.
- **Run history** — every run and restore, newest first; double-click a row for its report;
  "See all N runs" under a job's recent runs opens it too; **Clear history…**
  asks, then forgets them (nothing at any destination is touched).

## Deleting things

Data Syncer never deletes a backup. Delete old dated folders yourself in Finder or in Restore…; the
next run just sees they are gone (an incremental restore that depended on a deleted backup says so).
Deleting a job or a destination in the app removes only the entry — the copies stay where they are.
