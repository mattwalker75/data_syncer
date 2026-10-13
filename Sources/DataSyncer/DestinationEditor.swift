// The sheet that makes or changes a destination: where (a folder here, iCloud Drive, a USB drive by name, a
// network share, an SSH server — the cloud services arrive in step 5), how (the mode and its options), and
// the sign-in, which goes to the Keychain. "Test connection" tries the destination without copying anything.
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
        var available: Bool { [.folder, .iCloud, .usb, .network, .sftp].contains(self) }
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
    // the sign-in (share password, SSH password or key passphrase)
    @State private var secret = ""
    @State private var secretLoaded = false
    @State private var hadSecret = false
    // how
    @State private var mode: ModeChoice = .sync
    @State private var deleteExtras = true
    @State private var chainStart: ChainStart = .lastIncremental
    @State private var maxIncrementals = 10
    @State private var backupTitle = ""
    @State private var enabled = true
    // test
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(destination == nil ? "New destination" : "Edit destination").font(.title2).fontWeight(.bold)
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(kind == .usb ? "Backup drive" : "Second copy"))
                    Picker("Where", selection: $kind) {
                        ForEach(KindChoice.allCases) { k in
                            Text(k.available ? k.rawValue : "\(k.rawValue) — coming in a later step").tag(k)
                        }
                    }
                    .onChange(of: kind) { _, k in if !k.available { kind = .folder }; testResult = nil }
                    whereFields
                }
                Section("How") {
                    Picker("Mode", selection: $mode) { ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) } }
                    switch mode {
                    case .sync:
                        Toggle("Delete files at the destination that the source no longer has", isOn: $deleteExtras)
                        Text("The destination is made to match the source. You see a preview of what will be copied and deleted before anything happens.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    case .fullOnly:
                        TextField("Backup title", text: $backupTitle, prompt: Text(job.name))
                        Text("Every run makes a new dated folder with a complete copy: \(BackupNaming.folderName(kind: .full, title: BackupNaming.sanitizeTitle(backupTitle.isEmpty ? job.name : backupTitle), date: Date())). Old backups are never deleted by Data Syncer.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    case .fullIncremental:
                        TextField("Backup title", text: $backupTitle, prompt: Text(job.name))
                        Picker("Incrementals are measured", selection: $chainStart) {
                            Text("since the last incremental (smallest backups)").tag(ChainStart.lastIncremental)
                            Text("since the last full (each one complete on its own)").tag(ChainStart.lastFull)
                        }
                        Stepper("Most incrementals per chain: \(maxIncrementals)", value: $maxIncrementals, in: 1...365)
                        Text("After \(maxIncrementals) incrementals the next backup has to be a full one. When you run, you choose full or incremental for this destination.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("On — runs with the job", isOn: $enabled)
                }
            }
            .formStyle(.grouped)
            HStack {
                if kind == .network || kind == .sftp {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.disabled(testing || !valid)
                    if let r = testResult {
                        HStack(spacing: 6) { Dot(color: r.ok ? Theme.good : Theme.problem); Text(r.text).font(.system(size: 12)).lineLimit(2) }
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
        .frame(width: 660)
        .onAppear(perform: load)
    }

    // MARK: where

    @ViewBuilder private var whereFields: some View {
        switch kind {
        case .usb:
            Picker("Drive", selection: $volume) {
                if volumes.isEmpty { Text("No drives connected").tag("") }
                else {
                    if !volume.isEmpty, !volumes.contains(volume) { Text("\(volume) (not connected)").tag(volume) }
                    ForEach(volumes, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                TextField("Folder on the drive", text: $folder, prompt: Text("backup/Work documents")).font(.system(.body, design: .monospaced))
                Button("Choose…") {
                    let mount = URL(fileURLWithPath: "/Volumes/\(volume)")
                    if let url = FolderPicker.choose(title: "Choose the folder on the drive", message: "The folder on “\(volume)” that holds this destination's copies. It must already exist.", start: mount) {
                        if url.path.hasPrefix(mount.path) { folder = String(url.path.dropFirst(mount.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                        else { model.notice = Notice(title: "Not on that drive", message: "Choose a folder on “\(volume)”.") }
                    }
                }.disabled(volume.isEmpty)
            }
            note("The drive is found by its name whenever you run, so it can be plugged into any port. The folder must already exist — Data Syncer never creates it.")
        case .iCloud, .folder:
            HStack {
                TextField(kind == .iCloud ? "Folder in iCloud Drive" : "Folder", text: $folder, prompt: Text("/Volumes/Backup/Work")).font(.system(.body, design: .monospaced))
                Button("Choose…") {
                    let start = kind == .iCloud ? iCloudRoot : (folder.isEmpty ? nil : URL(fileURLWithPath: folder))
                    if let url = FolderPicker.choose(title: "Choose the destination folder", message: "The folder that holds this destination's copies. It must already exist.", start: start) { folder = url.path }
                }
            }
            note(kind == .iCloud
                 ? "iCloud Drive is a folder on this Mac that macOS keeps in the cloud; pick a folder inside it. Files are uploaded by macOS after Data Syncer copies them."
                 : "The folder must already exist — Data Syncer never creates it. It can be on this Mac or a drive or share that is already connected.")
        case .network:
            TextField("Share address", text: $shareAddress, prompt: Text("smb://nas.local/backups")).font(.system(.body, design: .monospaced))
            TextField("Folder in the share", text: $folder, prompt: Text("Work documents (leave empty for the share itself)")).font(.system(.body, design: .monospaced))
            TextField("User name", text: $shareUser, prompt: Text("leave empty for a guest share"))
            SecureField("Password", text: $secret, prompt: Text(hadSecret ? "(saved — type to replace)" : "kept in your Keychain"))
            note("If the share is already connected in Finder it is used as it is. Otherwise Data Syncer connects it with this sign-in when you run (smb:// for Windows, NAS and Mac shares; afp:// for older Macs). The folder must already exist.")
        case .sftp:
            HStack {
                TextField("Server", text: $host, prompt: Text("nas.local or 192.168.1.5")).font(.system(.body, design: .monospaced))
                if !configHosts.isEmpty {
                    Menu("From ~/.ssh/config") {
                        ForEach(configHosts) { h in
                            Button(h.alias + (h.hostName.map { " (\($0))" } ?? "")) { useConfig(h) }
                        }
                    }.frame(width: 170)
                }
                TextField("Port", text: $port).frame(width: 60)
            }
            TextField("User name", text: $user)
            TextField("Folder on the server", text: $folder, prompt: Text("/volume1/backups/Work (or relative to the home folder)")).font(.system(.body, design: .monospaced))
            Picker("Sign in with", selection: $auth) { ForEach(SSHAuth.allCases) { Text($0.rawValue).tag($0) } }
            switch auth {
            case .terminal:
                note("Uses whatever ssh in Terminal would: keys loaded in ssh-agent, ~/.ssh/config and the default keys in ~/.ssh. Settings → Accounts shows what this Mac has.")
            case .key:
                HStack {
                    if sshKeys.isEmpty {
                        TextField("Key file", text: $keyPath, prompt: Text("~/.ssh/id_ed25519")).font(.system(.body, design: .monospaced))
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
                SecureField("Key passphrase", text: $secret, prompt: Text(hadSecret ? "(saved — type to replace)" : "leave empty if the key has none"))
            case .password:
                SecureField("Password", text: $secret, prompt: Text(hadSecret ? "(saved — type to replace)" : "kept in your Keychain"))
                note("Passwords work when the server allows them; a key is safer and never asks again.")
            }
        default:
            EmptyView()
        }
    }

    private func note(_ s: String) -> some View { Text(s).font(.system(size: 12)).foregroundStyle(.secondary) }

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
        case .usb: return !volume.isEmpty
        case .network: return URL(string: shareAddress.trimmingCharacters(in: .whitespaces))?.host != nil
        case .sftp: return !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil && !user.trimmingCharacters(in: .whitespaces).isEmpty && !folder.trimmingCharacters(in: .whitespaces).isEmpty && (auth != .key || !keyPath.isEmpty)
        default: return !folder.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: load / build / save

    private func load() {
        volumes = FolderPicker.volumes()
        sshKeys = SSHInfo.keys(in: SSHInfo.sshDir)
        configHosts = SSHInfo.configHosts(at: SSHInfo.sshDir.appendingPathComponent("config"))
        guard let d = destination else { volume = volumes.first ?? ""; keyPath = sshKeys.first?.path ?? ""; return }
        name = d.name; folder = d.folder; enabled = d.enabled; backupTitle = d.backupTitle
        hadSecret = (try? model.secrets.secret(for: SecretAccount.destination(d.id))) != nil
        switch d.kind {
        case .usbDrive(let v): kind = .usb; volume = v
        case .localFolder: kind = folder.contains("com~apple~CloudDocs") ? .iCloud : .folder
        case .networkShare(let urlString):
            kind = .network
            if var c = URLComponents(string: urlString) { shareUser = c.user?.removingPercentEncoding ?? ""; c.user = nil; c.password = nil; shareAddress = c.string ?? urlString } else { shareAddress = urlString }
        case .sftp(let h, let p, let u, let k):
            kind = .sftp; host = h; port = String(p); user = u
            if let k { auth = .key; keyPath = k } else { auth = hadSecret ? .password : .terminal }
        default: kind = .folder
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
        default: k = .localFolder
        }
        let m: DestinationMode
        switch mode {
        case .sync: m = .sync(deleteExtras: deleteExtras)
        case .fullOnly: m = .fullOnly
        case .fullIncremental: m = .fullIncremental(chainStart: chainStart, maxIncrementals: maxIncrementals)
        }
        return Destination(id: destination?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), kind: k,
                           folder: folder.trimmingCharacters(in: .whitespaces), mode: m, enabled: enabled, backupTitle: backupTitle)
    }

    /// The secret to use: what was typed, else what is saved (when still relevant).
    private var secretForUse: String? {
        if !secret.isEmpty { return secret }
        if hadSecret, let d = destination, kind != .folder, auth != .terminal || kind == .network { return try? model.secrets.secret(for: SecretAccount.destination(d.id)) }
        return nil
    }

    private func test() async {
        testing = true; testResult = nil
        let d = build()
        let secrets = MemorySecrets(secretForUse.map { [SecretAccount.destination(d.id): $0] } ?? [:])
        do {
            let storage = try await DefaultStorageFactory(secrets: secrets).storage(for: d)
            try await storage.checkReachable()
            let free = (try? await storage.freeSpace()).flatMap { $0 }.map { " · \(Formatting.bytes($0)) free" } ?? ""
            testResult = (true, "Connected: \(storage.describe)\(free)")
            if let s = storage as? SSHStorage { await s.client.close() }
        } catch let e as DSError { testResult = (false, e.message) } catch { testResult = (false, error.localizedDescription) }
        testing = false
    }

    private func save() {
        let d = build()
        let account = SecretAccount.destination(d.id)
        do {
            let keep = kind == .network || (kind == .sftp && auth != .terminal)
            if !secret.isEmpty && keep { try model.secrets.set(secret, for: account) }
            else if !keep || (hadSecret && kind == .sftp && auth == .terminal) { try model.secrets.remove(for: account) }
        } catch { model.notice = Notice(title: "The sign-in could not be saved", message: error.localizedDescription) }
        model.upsert(d, in: job)
        dismiss()
    }
}
