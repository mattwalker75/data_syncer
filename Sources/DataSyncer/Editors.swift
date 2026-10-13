// The sheets that make or change a job and a destination, and the folder picker they share.
import SwiftUI
import AppKit
import DataSyncerCore

enum FolderPicker {
    /// The standard Mac "choose a folder" panel. nil when cancelled.
    @MainActor
    static func choose(title: String, message: String, start: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.message = message
        p.prompt = "Choose"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = false
        p.allowsMultipleSelection = false
        if let start { p.directoryURL = start }
        return p.runModal() == .OK ? p.url : nil
    }

    /// The drives under /Volumes (other than the startup disk), as a person sees them in Finder.
    static func volumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return nil }
            return url.lastPathComponent
        }.sorted()
    }
}

// MARK: - a job

struct JobEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job?
    @State private var name = ""
    @State private var sourcePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(job == nil ? "New job" : "Edit job").font(.title2).fontWeight(.bold)
            Form {
                TextField("Name", text: $name, prompt: Text("Work documents"))
                LabeledContent("Source folder") {
                    HStack {
                        TextField("", text: $sourcePath, prompt: Text("/Users/you/Documents")).font(.system(.body, design: .monospaced))
                        Button("Choose…") {
                            if let url = FolderPicker.choose(title: "Choose the source folder", message: "The folder on this Mac that Data Syncer copies from.", start: sourcePath.isEmpty ? nil : URL(fileURLWithPath: sourcePath)) { sourcePath = url.path }
                        }
                    }
                }
                Text("The source is always a folder on this Mac, and it is the truth: copying only ever goes from it to the destinations.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                if job != nil { Text("Destinations are added on the job's page.").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(job == nil ? "Add job" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || sourcePath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { if let job { name = job.name; sourcePath = job.sourcePath } }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces), s = sourcePath.trimmingCharacters(in: .whitespaces)
        if var job {
            job.name = n; job.sourcePath = s
            model.update(job)
        } else {
            model.add(Job(name: n, sourcePath: s))
        }
        dismiss()
    }
}

// MARK: - a destination

struct DestinationEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job
    let destination: Destination?

    enum KindChoice: String, CaseIterable, Identifiable {
        case folder = "Folder on this Mac", usb = "USB drive", network = "Network share", sftp = "SSH (SFTP)", s3 = "Amazon S3", googleDrive = "Google Drive", dropbox = "Dropbox", oneDrive = "OneDrive", iCloud = "iCloud Drive"
        var id: String { rawValue }
        var available: Bool { self == .folder || self == .usb || self == .iCloud }
    }
    enum ModeChoice: String, CaseIterable, Identifiable {
        case sync = "Sync", fullOnly = "Full only", fullIncremental = "Full + incremental"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var kind: KindChoice = .folder
    @State private var folder = ""
    @State private var volume = ""
    @State private var volumes: [String] = []
    @State private var mode: ModeChoice = .sync
    @State private var deleteExtras = true
    @State private var chainStart: ChainStart = .lastIncremental
    @State private var maxIncrementals = 10
    @State private var backupTitle = ""
    @State private var enabled = true

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
                    .onChange(of: kind) { _, k in if !k.available { kind = .folder } }
                    where_
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
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(destination == nil ? "Add destination" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: load)
    }

    @ViewBuilder private var where_: some View {
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
            Text("The drive is found by its name whenever you run, so it can be plugged into any port. The folder must already exist — Data Syncer never creates it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .iCloud, .folder:
            HStack {
                TextField(kind == .iCloud ? "Folder in iCloud Drive" : "Folder", text: $folder, prompt: Text("/Volumes/Backup/Work")).font(.system(.body, design: .monospaced))
                Button("Choose…") {
                    let start = kind == .iCloud ? iCloudRoot : (folder.isEmpty ? nil : URL(fileURLWithPath: folder))
                    if let url = FolderPicker.choose(title: "Choose the destination folder", message: "The folder that holds this destination's copies. It must already exist.", start: start) { folder = url.path }
                }
            }
            Text(kind == .iCloud
                 ? "iCloud Drive is a folder on this Mac that macOS keeps in the cloud; pick a folder inside it. Files are uploaded by macOS after Data Syncer copies them."
                 : "The folder must already exist — Data Syncer never creates it. It can be on this Mac or a drive or share that is already connected.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var iCloudRoot: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .usb: return !volume.isEmpty
        default: return !folder.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func load() {
        volumes = FolderPicker.volumes()
        guard let d = destination else { volume = volumes.first ?? ""; return }
        name = d.name; folder = d.folder; enabled = d.enabled; backupTitle = d.backupTitle
        switch d.kind {
        case .usbDrive(let v): kind = .usb; volume = v
        case .localFolder: kind = folder.contains("com~apple~CloudDocs") ? .iCloud : .folder
        default: kind = .folder
        }
        switch d.mode {
        case .sync(let del): mode = .sync; deleteExtras = del
        case .fullOnly: mode = .fullOnly
        case .fullIncremental(let start, let max): mode = .fullIncremental; chainStart = start; maxIncrementals = max
        }
    }

    private func save() {
        let k: DestinationKind = kind == .usb ? .usbDrive(volumeName: volume) : .localFolder
        let m: DestinationMode
        switch mode {
        case .sync: m = .sync(deleteExtras: deleteExtras)
        case .fullOnly: m = .fullOnly
        case .fullIncremental: m = .fullIncremental(chainStart: chainStart, maxIncrementals: maxIncrementals)
        }
        let d = Destination(id: destination?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), kind: k,
                            folder: folder.trimmingCharacters(in: .whitespaces), mode: m, enabled: enabled, backupTitle: backupTitle)
        model.upsert(d, in: job)
        dismiss()
    }
}
