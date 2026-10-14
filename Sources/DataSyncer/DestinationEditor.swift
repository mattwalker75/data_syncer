// The sheet that makes or changes a destination: where (a folder here, iCloud Drive, a USB drive by name, a
// network share, an SSH server, S3, Google Drive, Dropbox, OneDrive), how (the mode and its options), and the
// sign-in, which goes to the Keychain. "Test connection" tries the destination without copying anything.
import SwiftUI
import DataSyncerCore

struct DestinationEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job
    let destination: Destination?

    enum KindChoice: String, CaseIterable, Identifiable {
        case folder = "Folder on this Mac", iCloud = "iCloud Drive", usb = "USB drive", network = "Network share", sftp = "SSH server (SFTP)",
             s3 = "Amazon S3", googleDrive = "Google Drive", dropbox = "Dropbox", oneDrive = "OneDrive"
        var id: String { rawValue }
        var available: Bool { true }
        var provider: CloudProvider? {
            switch self { case .s3: return .s3; case .googleDrive: return .googleDrive; case .dropbox: return .dropbox; case .oneDrive: return .oneDrive; default: return nil }
        }
    }
    enum ModeChoice: String, CaseIterable, Identifiable {
        case sync = "Sync", fullOnly = "Full only", fullIncremental = "Full + incremental"
        var id: String { rawValue }
    }
    enum SSHAuth: String, CaseIterable, Identifiable {
        case terminal = "Like Terminal (ssh-agent, ~/.ssh/config, default keys)", key = "A key file", password = "A password"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var kind: KindChoice = .folder
    @State private var folder = ""
    @State private var volume = ""
    @State private var volumes: [String] = []
    // network share
    @State private var shareAddress = ""
    @State private var shareUser = ""
    // ssh
    @State private var host = ""
    @State private var port = "22"
    @State private var user = NSUserName()
    @State private var auth: SSHAuth = .terminal
    @State private var keyPath = ""
    @State private var sshKeys: [SSHKey] = []
    @State private var configHosts: [SSHConfigHost] = []
    // cloud
    @State private var accountId = ""
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var endpoint = ""
    @State private var addingAccount: CloudProvider?
    @State private var makingFolder = false
    // the sign-in (share password, SSH password or key passphrase)
    @State private var secret = ""
    @State private var hadSecret = false
    /// the sign-in method the saved secret belongs to (a password is not a passphrase)
    @State private var loadedAuth: SSHAuth = .terminal
    @State private var problem: Notice?
    // how
    @State private var mode: ModeChoice = .sync
    @State private var deleteExtras = true
    @State private var chainStart: ChainStart = .lastIncremental
    @State private var maxIncrementals = 10
    @State private var backupTitle = ""
    @State private var enabled = true
    @State private var includeSourceFolder = false
    @State private var confirmRemove = false
    // test
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(destination == nil ? "New destination" : "Edit destination").font(.title2).fontWeight(.bold)
            Form {
                Section {
                    Field("Name", $name, kind == .usb ? "Backup drive" : "Second copy")
                    Picker("Where", selection: $kind) {
                        ForEach(KindChoice.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .onChange(of: kind) { _, k in
                        testResult = nil
                        // a cloud kind starts with its first account, if there is one
                        if let p = k.provider, !model.cloudAccounts.contains(where: { $0.id.uuidString == accountId && $0.provider == p }) {
                            accountId = model.cloudAccounts.first { $0.provider == p }?.id.uuidString ?? ""
                        }
                    }
                    .onChange(of: model.cloudAccounts) { _, accounts in
                        if accountId.isEmpty, let p = kind.provider { accountId = accounts.first { $0.provider == p }?.id.uuidString ?? "" }
                    }
                    whereFields
                }
                Section("What goes into the folder") {
                    Picker("Copy", selection: $includeSourceFolder) {
                        Text("what is inside the source folder").tag(false)
                        Text("the source folder itself, “\(sourceName)”").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Text(includeSourceFolder
                         ? "The destination gets a folder named “\(sourceName)” with everything in it: \(exampleTarget)/\(sourceName)/…" + (destination?.copiesSourceFolder == true ? "" : " Changing this on a destination that already has copies makes the old layout look like extra files — a sync will offer to delete them, a backup chain starts over.")
                         : "Only the files and folders inside the source go in: \(exampleTarget)/…" + (destination?.copiesSourceFolder == true ? " Changing this on a destination that already has copies makes the old layout look like extra files — a sync will offer to delete them, a backup chain starts over." : ""))
                        .font(.system(size: 13.5)).foregroundStyle(.secondary)
                }
                Section("How") {
                    Picker("Mode", selection: $mode) { ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) } }
                    switch mode {
                    case .sync:
                        Toggle("Delete files at the destination that the source no longer has", isOn: $deleteExtras)
                        Text("The destination is made to match the source. You see a preview of what will be copied and deleted before anything happens.")
                            .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    case .fullOnly:
                        Field("Backup title", $backupTitle, job.name)
                        Text("Every run makes a new dated folder with a complete copy: \(BackupNaming.folderName(kind: .full, title: BackupNaming.sanitizeTitle(backupTitle.isEmpty ? job.name : backupTitle), date: Date())). Old backups are never deleted by Data Syncer.")
                            .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    case .fullIncremental:
                        Field("Backup title", $backupTitle, job.name)
                        Picker("Incrementals are measured", selection: $chainStart) {
                            Text("since the last incremental (smallest backups)").tag(ChainStart.lastIncremental)
                            Text("since the last full (each one complete on its own)").tag(ChainStart.lastFull)
                        }
                        LabeledContent("Most incrementals per chain") {
                            HStack(spacing: 6) {
                                Text("\(maxIncrementals)").monospacedDigit().frame(minWidth: 30, alignment: .trailing)
                                Stepper("Most incrementals per chain", value: $maxIncrementals, in: 1...365).labelsHidden()
                            }
                        }
                        Text("After \(maxIncrementals) incrementals the next backup has to be a full one. When you run, you choose full or incremental for this destination.")
                            .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let d = destination {
                    Button("Remove destination…", role: .destructive) { confirmRemove = true }
                        .help("Takes “\(d.name)” off this job. Nothing at the destination is touched.")
                }
                if kind == .network || kind == .sftp || kind.provider != nil {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.disabled(testing || !valid)
                    if kind.provider != nil {
                        Button(makingFolder ? "Making…" : "Make this folder") { Task { await makeFolder() } }.disabled(makingFolder || !valid)
                            .help("Creates the destination folder in the service — the one thing Data Syncer only does when you ask")
                    }
                    if let r = testResult {
                        HStack(spacing: 6) { Dot(color: r.ok ? Theme.good : Theme.problem); Text(r.text).font(.system(size: 13.5)).lineLimit(2) }
                            .frame(maxWidth: 360, alignment: .leading).help(r.text)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(destination == nil ? "Add destination" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 660, height: 820)
        .onAppear(perform: load)
        .sheet(item: $addingAccount) { p in
            CloudAccountSheet(provider: p) { account in accountId = account.id.uuidString }
        }
        .alert(item: $problem) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK"))) }
        .confirmationDialog("Remove the destination “\(destination?.name ?? "")” from this job?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove destination", role: .destructive) { if let d = destination { model.remove(d, from: job) }; dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing at the destination is touched: the copies and backups there stay as they are.")
        }
    }

    private var sourceName: String { job.sourceURL.lastPathComponent }
    /// where the copies land, for the sentence under the "what goes in" choice
    private var exampleTarget: String {
        switch kind {
        case .usb: return "/" + (volume.isEmpty ? "drive" : volume) + "/" + folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        case .folder, .iCloud:
            let p = Formatting.shortPath(folder.trimmingCharacters(in: .whitespaces))
            return p.isEmpty ? "the folder" : (p.count > 48 ? "…/" + (p as NSString).lastPathComponent : p)
        default: return folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty ? "the folder" : Formatting.shortPath(folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
        }
    }

    /// is the saved secret the right kind for the sign-in method chosen now?
    private var savedSecretApplies: Bool { hadSecret && (kind == .network || (kind == .sftp && auth == loadedAuth && auth != .terminal)) }

    // MARK: where

    @ViewBuilder private var whereFields: some View {
        switch kind {
        case .usb:
            Picker("Drive", selection: $volume) {
                if !volume.isEmpty, !volumes.contains(volume) { Text("\(volume) (not connected right now)").tag(volume) }
                if volumes.isEmpty && volume.isEmpty { Text("No drives connected").tag("") }
                ForEach(volumes, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                PlainTextField("backup/Work documents", text: $folder, monospaced: true, label: "Folder on the drive")
                Button("Choose…") {
                    let mount = URL(fileURLWithPath: "/Volumes/\(volume)")
                    if let url = FolderPicker.choose(title: "Choose the folder on the drive", message: "The folder on “\(volume)” that holds this destination's copies. It must already exist.", start: mount) {
                        if url.path.hasPrefix(mount.path) { folder = String(url.path.dropFirst(mount.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                        else { problem = Notice(title: "Not on that drive", message: "Choose a folder on “\(volume)”.") }
                    }
                }.disabled(volume.isEmpty)
            }
            note("The drive is found by its name whenever you run, so it can be plugged into any port. The folder on it must already exist — Data Syncer never creates it, and never uses a whole drive as a destination.")
        case .iCloud, .folder:
            HStack {
                PlainTextField("/Volumes/Backup/Work", text: $folder, monospaced: true, label: kind == .iCloud ? "Folder in iCloud Drive" : "Folder")
                Button("Choose…") {
                    let start = kind == .iCloud ? iCloudRoot : (folder.isEmpty ? nil : URL(fileURLWithPath: folder))
                    if let url = FolderPicker.choose(title: "Choose the destination folder", message: "The folder that holds this destination's copies. It must already exist.", start: start) { folder = url.path }
                }
            }
            note(kind == .iCloud
                 ? "iCloud Drive is a folder on this Mac that macOS keeps in the cloud; pick a folder inside it. Files are uploaded by macOS after Data Syncer copies them."
                 : "The folder must already exist — Data Syncer never creates it. It can be on this Mac or a drive or share that is already connected.")
        case .network:
            Field("Share address", $shareAddress, "smb://nas.local/backups", mono: true)
            Field("Folder in the share", $folder, "Work documents (leave empty for the share itself)", mono: true)
            Field("User name", $shareUser, "leave empty for a guest share")
            SecureField("Password", text: $secret, prompt: Text(savedSecretApplies ? "(saved — type to replace)" : "kept in your Keychain"))
            note("If the share is already connected in Finder it is used as it is. Otherwise Data Syncer connects it with this sign-in when you run (smb:// for Windows, NAS and Mac shares; afp:// for older Macs). The folder must already exist.")
        case .sftp:
            HStack {
                PlainTextField("nas.local or 192.168.1.5", text: $host, monospaced: true, label: "Server")
                if !configHosts.isEmpty {
                    Menu("From ~/.ssh/config") {
                        ForEach(configHosts) { h in
                            Button(h.alias + (h.hostName.map { " (\($0))" } ?? "")) { useConfig(h) }
                        }
                    }.frame(width: 170)
                }
                PlainTextField("22", text: $port, label: "Port").frame(width: 60)
            }
            Field("User name", $user)
            Field("Folder on the server", $folder, "/volume1/backups/Work (or relative to the home folder)", mono: true)
            Picker("Sign in with", selection: $auth) { ForEach(SSHAuth.allCases) { Text($0.rawValue).tag($0) } }
            switch auth {
            case .terminal:
                note("Uses whatever ssh in Terminal would: keys loaded in ssh-agent, ~/.ssh/config and the default keys in ~/.ssh. Settings → Accounts shows what this Mac has.")
            case .key:
                HStack {
                    if sshKeys.isEmpty {
                        PlainTextField("~/.ssh/id_ed25519", text: $keyPath, monospaced: true, label: "Key file")
                    } else {
                        Picker("Key file", selection: $keyPath) {
                            ForEach(sshKeys) { k in Text("\(k.name)  \(k.type) \(k.comment)").tag(k.path) }
                            if !keyPath.isEmpty, !sshKeys.contains(where: { $0.path == keyPath }) { Text(keyPath).tag(keyPath) }
                        }
                    }
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.showsHiddenFiles = true
                        p.directoryURL = SSHInfo.sshDir; p.message = "Choose the private key (not the .pub file)."
                        if p.runModal() == .OK, let u = p.url { keyPath = u.path }
                    }
                }
                SecureField("Key passphrase", text: $secret, prompt: Text(savedSecretApplies ? "(saved — type to replace)" : "leave empty if the key has none"))
            case .password:
                SecureField("Password", text: $secret, prompt: Text(savedSecretApplies ? "(saved — type to replace)" : "kept in your Keychain"))
                note("Passwords work when the server allows them; a key is safer and never asks again. The first time a server is used, its identity is remembered in ~/.ssh/known_hosts without asking.")
            }
        case .s3:
            accountPicker(.s3)
            Field("Bucket", $bucket, "my-backups", mono: true)
            Field("Region", $region, "us-east-1", mono: true)
            Field("Service address (S3-compatible only)", $endpoint, "leave empty for Amazon; e.g. https://s3.us-west-004.backblazeb2.com", mono: true)
            Field("Folder in the bucket", $folder, "work-documents (leave empty for the bucket itself)", mono: true)
            note("The bucket must already exist — Data Syncer never creates buckets. The folder must exist too; “Make this folder” below creates it in the bucket when you ask. Links in the source can't be kept in S3 and are reported as skipped.")
        case .googleDrive, .dropbox, .oneDrive:
            accountPicker(kind.provider!)
            Field("Folder in \(kind.rawValue)", $folder, "Data Syncer/Work documents", mono: true)
            note(kind == .googleDrive
                 ? "A path under My Drive. Data Syncer asks Google only for permission over files it makes itself, so the folder has to be made by Data Syncer: use “Make this folder” below. Links in the source are reported as skipped."
                 : "A path from the top of your \(kind.rawValue). The folder must already exist; “Make this folder” below creates it when you ask. Links in the source are reported as skipped.")
        }
    }

    @ViewBuilder private func accountPicker(_ p: CloudProvider) -> some View {
        let accounts = model.cloudAccounts.filter { $0.provider == p }
        HStack {
            Picker("Account", selection: $accountId) {
                if accounts.isEmpty { Text("none yet").tag("") }
                else {
                    if !accountId.isEmpty, !accounts.contains(where: { $0.id.uuidString == accountId }) { Text("(an account that was removed)").tag(accountId) }
                    ForEach(accounts) { a in Text(a.label).tag(a.id.uuidString) }
                }
            }
            Button("Add account…") { addingAccount = p }
        }
    }

    private func note(_ s: String) -> some View { Text(s).font(.system(size: 13.5)).foregroundStyle(.secondary) }

    private func useConfig(_ h: SSHConfigHost) {
        host = h.hostName ?? h.alias
        if let u = h.user { user = u }
        if let p = h.port { port = String(p) }
        if let k = h.identityFile { keyPath = (k as NSString).expandingTildeInPath; auth = .key } else { auth = .terminal }
        if name.isEmpty { name = h.alias }
    }

    private var iCloudRoot: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .usb: return !volume.isEmpty && !folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty
        case .network: return URL(string: shareAddress.trimmingCharacters(in: .whitespaces))?.host != nil
        case .sftp: return !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil && !user.trimmingCharacters(in: .whitespaces).isEmpty && !folder.trimmingCharacters(in: .whitespaces).isEmpty && (auth != .key || !keyPath.isEmpty)
        case .s3: return !accountId.isEmpty && !region.trimmingCharacters(in: .whitespaces).isEmpty && S3Storage.validate(bucket: bucket.trimmingCharacters(in: .whitespaces), endpoint: endpoint) == nil
        case .googleDrive, .dropbox, .oneDrive: return !accountId.isEmpty && !folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty
        default: return !folder.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: load / build / save

    private func load() {
        volumes = FolderPicker.volumes()
        sshKeys = SSHInfo.keys(in: SSHInfo.sshDir)
        configHosts = SSHInfo.configHosts(at: SSHInfo.sshDir.appendingPathComponent("config"))
        guard let d = destination else { volume = volumes.first ?? ""; keyPath = sshKeys.first?.path ?? ""; return }
        name = d.name; folder = d.folder; enabled = d.enabled; backupTitle = d.backupTitle; includeSourceFolder = d.copiesSourceFolder
        hadSecret = model.secrets.has(SecretAccount.destination(d.id))   // never reads it (that prompts the Keychain)
        switch d.kind {
        case .usbDrive(let v): kind = .usb; volume = v
        case .localFolder: kind = folder.contains("com~apple~CloudDocs") ? .iCloud : .folder
        case .networkShare(let urlString):
            kind = .network
            if var c = URLComponents(string: urlString) { shareUser = c.user?.removingPercentEncoding ?? ""; c.user = nil; c.password = nil; shareAddress = c.string ?? urlString } else { shareAddress = urlString }
        case .sftp(let h, let p, let u, let k):
            kind = .sftp; host = h; port = String(p); user = u
            if let k { auth = .key; keyPath = k } else { auth = d.usesPassword == true ? .password : .terminal }
            loadedAuth = auth
        case .s3(let a, let b, let r, let e): kind = .s3; accountId = a; bucket = b; region = r; endpoint = e ?? ""
        case .googleDrive(let a): kind = .googleDrive; accountId = a
        case .dropbox(let a): kind = .dropbox; accountId = a
        case .oneDrive(let a): kind = .oneDrive; accountId = a
        }
        switch d.mode {
        case .sync(let del): mode = .sync; deleteExtras = del
        case .fullOnly: mode = .fullOnly
        case .fullIncremental(let start, let max): mode = .fullIncremental; chainStart = start; maxIncrementals = max
        }
    }

    /// The destination as the fields describe it now.
    private func build() -> Destination {
        let k: DestinationKind
        switch kind {
        case .usb: k = .usbDrive(volumeName: volume)
        case .network:
            var c = URLComponents(string: shareAddress.trimmingCharacters(in: .whitespaces)) ?? URLComponents()
            let u = shareUser.trimmingCharacters(in: .whitespaces)
            c.user = u.isEmpty ? nil : u
            k = .networkShare(url: c.string ?? shareAddress)
        case .sftp: k = .sftp(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 22, user: user.trimmingCharacters(in: .whitespaces), keyPath: auth == .key ? keyPath : nil)
        case .s3:
            let e = endpoint.trimmingCharacters(in: .whitespaces)
            k = .s3(account: accountId, bucket: bucket.trimmingCharacters(in: .whitespaces), region: region.trimmingCharacters(in: .whitespaces), endpoint: e.isEmpty ? nil : e)
        case .googleDrive: k = .googleDrive(account: accountId)
        case .dropbox: k = .dropbox(account: accountId)
        case .oneDrive: k = .oneDrive(account: accountId)
        default: k = .localFolder
        }
        let m: DestinationMode
        switch mode {
        case .sync: m = .sync(deleteExtras: deleteExtras)
        case .fullOnly: m = .fullOnly
        case .fullIncremental: m = .fullIncremental(chainStart: chainStart, maxIncrementals: maxIncrementals)
        }
        return Destination(id: destination?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), kind: k,
                           folder: folder.trimmingCharacters(in: .whitespaces), mode: m, enabled: enabled, backupTitle: backupTitle,
                           usesPassword: kind == .sftp ? auth == .password : nil, includeSourceFolder: includeSourceFolder ? true : nil)
    }

    /// The secret to use: what was typed, else what is saved (when it is the right kind for the method chosen).
    private var secretForUse: String? {
        if !secret.isEmpty { return secret }
        if savedSecretApplies, let d = destination { return try? model.secrets.secret(for: SecretAccount.destination(d.id)) }
        return nil
    }

    /// A factory that uses the typed-but-unsaved secret for this destination and the Keychain for cloud accounts.
    private func factory(_ d: Destination) -> DefaultStorageFactory {
        let typed = MemorySecrets(secretForUse.map { [SecretAccount.destination(d.id): $0] } ?? [:])
        return DefaultStorageFactory(secrets: LayeredSecrets(first: typed, second: model.secrets), accounts: model.accountStore)
    }

    private func makeFolder() async {
        makingFolder = true; testResult = nil
        let d = build()
        do {
            let storage = try await factory(d).storage(for: d)
            switch storage {
            case let s as S3Storage: try await s.makeRootFolder()
            case let s as GoogleDriveStorage: try await s.makeRootFolder()
            case let s as DropboxStorage: try await s.makeRootFolder()
            case let s as OneDriveStorage: try await s.makeRootFolder()
            default: break
            }
            try await storage.checkReachable()
            testResult = (true, "The folder is there: \(storage.describe)")
            await storage.close()
        } catch let e as DSError { testResult = (false, e.message) } catch { testResult = (false, error.localizedDescription) }
        makingFolder = false
    }

    private func test() async {
        testing = true; testResult = nil
        let d = build()
        do {
            let storage = try await factory(d).storage(for: d)
            try await storage.checkReachable()
            let free = (try? await storage.freeSpace()).flatMap { $0 }.map { " · \(Formatting.bytes($0)) free" } ?? ""
            testResult = (true, "Connected: \(storage.describe)\(free)")
            await storage.close()
        } catch let e as DSError { testResult = (false, e.message) } catch { testResult = (false, error.localizedDescription) }
        testing = false
    }

    private func save() {
        let d = build()
        let account = SecretAccount.destination(d.id)
        do {
            let keep = kind == .network || (kind == .sftp && auth != .terminal)   // cloud secrets live with the account, not the destination
            if !secret.isEmpty && keep { try model.secrets.set(secret, for: account) }
            else if !keep || !savedSecretApplies { try model.secrets.remove(for: account) }   // a password is not a passphrase: a stale one goes
        } catch { problem = Notice(title: "The sign-in could not be saved", message: error.localizedDescription); return }
        model.upsert(d, in: job)
        dismiss()
    }
}
