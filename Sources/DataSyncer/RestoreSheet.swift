// Restore…: pick one of the job's backup destinations, see the backups there, choose a restore point and a
// folder to restore into, and go. Old backups can be deleted here too (the user's decision — never the app's).
import SwiftUI
import DataSyncerCore

struct RestoreSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var destinationId: Destination.ID?
    @State private var loading = false
    @State private var loadError: String?
    @State private var storage: Storage?
    @State private var catalog: BackupCatalog?
    @State private var point: String?
    @State private var targetPath = ""
    @State private var removeDeleted = true
    @State private var toDelete: BackupEntry?
    @State private var deleting = false

    private var candidates: [Destination] {
        job.destinations.filter { if case .sync = $0.mode { return false }; return true }
    }
    private var destination: Destination? { candidates.first { $0.id == destinationId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore a backup of “\(job.name)”").font(.title2).fontWeight(.bold)
            if candidates.isEmpty {
                Text("This job has no backup destinations. Restore works with Full only and Full + incremental destinations; a Sync destination is a plain copy you can open in Finder.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Picker("From", selection: $destinationId) {
                    ForEach(candidates) { d in Text("\(d.name) — \(d.kind.label)").tag(Optional(d.id)) }
                }
                .onChange(of: destinationId) { _, _ in Task { await load() } }
                backups
                options
                HStack {
                    Text(verdict).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Restore") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!ready)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: candidates.isEmpty ? 200 : 620)
        .onAppear { destinationId = candidates.first?.id; Task { await load() } }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("Delete backup", role: .destructive) { Task { await deleteBackup() } }
            Button("Cancel", role: .cancel) { toDelete = nil }
        } message: { Text(deleteMessage) }
    }

    // MARK: the list

    @ViewBuilder private var backups: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Backups at \(destination?.name ?? "")")
                if loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Look again")
            }
            if let loadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) { Dot(color: Theme.problem); Text(loadError).textSelection(.enabled) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else if let catalog {
                if catalog.entries.isEmpty {
                    Text("No backups here yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    List(catalog.entries, id: \.folder, selection: $point) { e in
                        row(e)
                            .tag(e.folder)
                            .contextMenu { Button("Delete this backup…", role: .destructive) { toDelete = e } }
                    }
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                }
            } else {
                Text(loading ? "Looking at the destination…" : "").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ e: BackupEntry) -> some View {
        let isFull = e.parsed.kind == .full
        let badge = isFull ? Theme.badge(.fullOnly) : Theme.badge(.fullIncremental(chainStart: .lastFull, maxIncrementals: 0))
        return HStack(spacing: 12) {
            Badge(text: isFull ? "Full" : "Incremental", fill: badge.fill, color: badge.text).frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.parsed.date.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                Text(e.folder).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if let m = e.manifest {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Formatting.count(m.fileCount)) file\(m.fileCount == 1 ? "" : "s") · \(Formatting.bytes(m.totalBytes))").font(.system(size: 12))
                    if let b = m.basedOn { Text("since \(b)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    else if !isFull { Text("no parent recorded").font(.system(size: 11)).foregroundStyle(Theme.problem) }
                }
            } else {
                Text("no readable record").font(.system(size: 12)).foregroundStyle(Theme.problem)
                    .help("Named like a backup but its .datasyncer/manifest.json is missing or damaged — it can't be restored or used in a chain.")
            }
            Button { toDelete = e } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete this backup…")
        }
        .padding(.vertical, 3)
    }

    // MARK: options and the verdict

    private var plan: Result<RestorePlan, DSError>? {
        guard let catalog, let point else { return nil }
        do { return .success(try RestoreEngine.plan(catalog, point: point)) }
        catch let e as DSError { return .failure(e) }
        catch { return .failure(DSError(error.localizedDescription)) }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Restore into").frame(width: 90, alignment: .leading)
                TextField("", text: $targetPath, prompt: Text("an empty folder on this Mac")).font(.system(.body, design: .monospaced))
                Button("Choose…") {
                    if let url = FolderPicker.choose(title: "Choose where to restore", message: "The folder the backup is put into. An empty folder is best; existing files with the same names are replaced.", start: targetPath.isEmpty ? nil : URL(fileURLWithPath: targetPath)) { targetPath = url.path }
                }
            }
            Toggle("Remove files the backups recorded as deleted (so the result matches the source as it was then)", isOn: $removeDeleted)
                .font(.system(size: 12.5))
            Text("Off: those files are left in place for you to look at. Only matters when an incremental in the chain recorded deletions.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if case .success(let p) = plan {
                HStack(spacing: 8) { Dot(color: Theme.good); Text("\(p.summary) — \(p.chain.joined(separator: " → "))") }
                    .font(.system(size: 12.5)).lineLimit(3)
            } else if case .failure(let e) = plan {
                HStack(spacing: 8) { Dot(color: Theme.problem); Text(e.message) }.font(.system(size: 12.5))
            }
        }
    }

    private var ready: Bool {
        guard case .success = plan, !targetPath.trimmingCharacters(in: .whitespaces).isEmpty, !model.isRunning, storage != nil else { return false }
        return true
    }

    private var verdict: String {
        if model.isRunning { return "Restore is unavailable while a job is running." }
        if point == nil { return "Choose a backup to restore." }
        if case .failure = plan { return "That backup can't be restored." }
        if targetPath.isEmpty { return "Choose a folder to restore into." }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDir) || !isDir.boolValue { return "That folder isn't there — make it first." }
        if let n = try? FileManager.default.contentsOfDirectory(atPath: targetPath).filter({ $0 != ".DS_Store" }).count, n > 0 {
            return "That folder already holds \(n) item\(n == 1 ? "" : "s"); files with the same names will be replaced."
        }
        return "Ready."
    }

    // MARK: actions

    private func load() async {
        guard let d = destination else { return }
        loading = true; loadError = nil; catalog = nil; point = nil; storage = nil
        do {
            let s = try await DefaultStorageFactory().storage(for: d)
            try await s.checkReachable()
            let c = try await BackupCatalog.load(from: s)
            storage = s; catalog = c
            point = c.entries.first { $0.manifest != nil }?.folder
        } catch let e as DSError { loadError = e.message } catch { loadError = error.localizedDescription }
        loading = false
    }

    private func start() {
        guard let d = destination, let storage, let catalog, let point else { return }
        let target = URL(fileURLWithPath: (targetPath as NSString).expandingTildeInPath, isDirectory: true)
        model.startRestore(job: job, destination: d, storage: storage, catalog: catalog, point: point, target: target, removeDeleted: removeDeleted)
        dismiss()
    }

    private var deleteTitle: String { "Delete the backup \(toDelete?.folder ?? "")?" }
    private var deleteMessage: String {
        guard let e = toDelete, let catalog else { return "" }
        let deps = catalog.dependents(of: e.folder)
        var s = "The folder and everything in it are removed from \(destination?.name ?? "the destination"). This can't be undone."
        if !deps.isEmpty {
            s += "\n\n\(deps.count) incremental backup\(deps.count == 1 ? "" : "s") depend on it and could no longer be restored:\n" + deps.map(\.folder).joined(separator: "\n")
        }
        return s
    }

    private func deleteBackup() async {
        guard let e = toDelete, let storage, let catalog else { return }
        toDelete = nil; deleting = true
        do { try await RestoreEngine.delete(e.folder, from: storage, catalog: catalog) }
        catch let err as DSError { model.notice = Notice(title: "The backup could not be deleted", message: err.message) }
        catch { model.notice = Notice(title: "The backup could not be deleted", message: error.localizedDescription) }
        deleting = false
        await load()
    }
}
