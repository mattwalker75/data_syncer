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
    public static func check(_ job: Job, _ d: Destination, factory: StorageFactory = DefaultStorageFactory()) async -> DestinationCheck {
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
        // writable: a small file in the records folder, removed again
        do {
            let probe = joinPath(Records.folderName, ".write-check")
            try await storage.makeDirectory(Records.folderName)
            try await storage.writeData(Data("ok".utf8), to: probe)
            try await storage.remove(probe)
            out.items.append(CheckItem(name: "Writable", ok: true, detail: "Data Syncer can write here"))
        } catch let e as DSError {
            out.items.append(CheckItem(name: "Writable", ok: false, detail: e.message))
        } catch {
            out.items.append(CheckItem(name: "Writable", ok: false, detail: error.localizedDescription))
        }
        if let free = try? await storage.freeSpace() {
            out.items.append(CheckItem(name: "Free space", ok: true, detail: ByteCount.string(free)))
        }
        switch d.mode {
        case .sync:
            if let state = try? await Records.loadSyncState(from: storage) {
                out.items.append(CheckItem(name: "Last sync", ok: true, detail: "\(state.files.count) files recorded, \(Self.when(state.updatedAt))"))
            } else {
                out.items.append(CheckItem(name: "Last sync", ok: true, detail: "never synced here yet — the first run copies everything"))
            }
        case .fullOnly, .fullIncremental:
            if let catalog = try? await BackupCatalog.load(from: storage) {
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
