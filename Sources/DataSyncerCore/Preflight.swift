// "Check destinations": what the user runs before a backup to see that everything is reachable and writable —
// the same checks a run makes first, without copying anything. Each item is a sentence with a pass or fail.
import Foundation

public struct CheckItem: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var ok: Bool
    public var detail: String
    public init(name: String, ok: Bool, detail: String) { self.name = name; self.ok = ok; self.detail = detail }
}

public struct DestinationCheck: Equatable, Sendable {
    public var destinationId: Destination.ID
    public var items: [CheckItem]
    /// for Full + incremental: what the next backup can be
    public var canIncremental = false
    public var incrementalNote = ""
    public var ok: Bool { items.allSatisfy(\.ok) }
}

public enum Preflight {
    /// The source alone: there, and readable.
    public static func checkSource(_ job: Job) -> CheckItem {
        let url = job.sourceURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return CheckItem(name: "Source", ok: false, detail: "The source folder \(url.path) isn't there.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path), (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            return CheckItem(name: "Source", ok: false, detail: "The source folder \(url.path) can't be read. If it is in Desktop, Documents or another folder macOS protects, give Data Syncer Full Disk Access in System Settings → Privacy & Security.")
        }
        return CheckItem(name: "Source", ok: true, detail: url.path)
    }

    /// One destination: reachable, the folder there and writable, free space, and what backups it already holds.
    public static func check(_ job: Job, _ d: Destination, factory: StorageFactory = DefaultStorageFactory(), otherJobIds: Set<UUID>? = nil) async -> DestinationCheck {
        var out = DestinationCheck(destinationId: d.id, items: [])
        let storage: Storage
        do {
            storage = try await factory.storage(for: d)
            try await storage.checkReachable()
            out.items.append(CheckItem(name: "Reachable", ok: true, detail: storage.describe))
        } catch let e as DSError {
            out.items.append(CheckItem(name: "Reachable", ok: false, detail: e.message))
            return out
        } catch {
            out.items.append(CheckItem(name: "Reachable", ok: false, detail: error.localizedDescription))
            return out
        }
        // writable: a small file in the records folder, removed again (and the folder too, if the check made it)
        do {
            let probe = joinPath(Records.folderName, ".write-check")
            let hadRecords = try await storage.exists(Records.folderName)
            try await storage.makeDirectory(Records.folderName)
            try await storage.writeData(Data("ok".utf8), to: probe)
            try await storage.remove(probe)
            if !hadRecords { try? await storage.remove(Records.folderName) }
            out.items.append(CheckItem(name: "Writable", ok: true, detail: "Data Syncer can write here"))
        } catch let e as DSError {
            out.items.append(CheckItem(name: "Writable", ok: false, detail: e.message))
        } catch {
            out.items.append(CheckItem(name: "Writable", ok: false, detail: error.localizedDescription))
        }
        if let free = try? await storage.freeSpace() {
            out.items.append(CheckItem(name: "Free space", ok: true, detail: ByteCount.string(free)))
        }
        if let record = try? await Records.loadDestinationRecord(from: storage), record.destinationId != d.id {
            let other = record.jobId == job.id ? job.destinations.contains { $0.id == record.destinationId } : (otherJobIds?.contains(record.jobId) ?? true)
            out.items.append(CheckItem(name: "Folder in use", ok: !other,
                                       detail: other ? "already used by the job “\(record.jobName)” (destination “\(record.destinationName)”) — two jobs can't share one folder"
                                                     : "was used by a job that no longer exists (“\(record.jobName)”); it will be taken over"))
        }
        switch d.mode {
        case .sync:
            do {
                if let state = try await Records.loadSyncState(from: storage) {
                    out.items.append(CheckItem(name: "Last sync", ok: true, detail: "\(state.files.count) files recorded, \(Self.when(state.updatedAt))"))
                } else {
                    out.items.append(CheckItem(name: "Last sync", ok: true, detail: "never synced here yet — the first run copies everything"))
                }
            } catch let e as DSError {
                out.items.append(CheckItem(name: "Last sync", ok: false, detail: e.message))
            } catch {
                out.items.append(CheckItem(name: "Last sync", ok: false, detail: error.localizedDescription))
            }
        case .fullOnly, .fullIncremental:
            if let catalog = try? await BackupCatalog.load(from: storage, title: job.backupTitle(for: d)) {
                let fulls = catalog.entries.filter { $0.parsed.kind == .full }.count
                let incs = catalog.entries.filter { $0.parsed.kind == .incremental }.count
                let unreadable = catalog.entries.filter { $0.manifest == nil }.count
                var detail = catalog.entries.isEmpty ? "no backups here yet" : "\(fulls) full, \(incs) incremental"
                if let newest = catalog.entries.first { detail += " · newest \(newest.folder)" }
                if unreadable > 0 { detail += " · \(unreadable) without a readable record" }
                out.items.append(CheckItem(name: "Backups here", ok: true, detail: detail))
                if case .fullIncremental(let start, let max) = d.mode {
                    let (_, soFar, reason) = catalog.incrementalParent(chainStart: start, maxIncrementals: max)
                    out.canIncremental = reason == nil
                    out.incrementalNote = reason ?? "an incremental is possible (\(soFar) of \(max) in the current chain)"
                }
            }
        }
        return out
    }

    static func when(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
