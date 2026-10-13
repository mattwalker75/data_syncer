// Decides what a run will do before anything is copied — so the user can see a preview ("copy 212, delete 3")
// and so a check for free space is honest. Pure functions over snapshots; nothing here touches a disk.
import Foundation

public struct PlannedFile: Equatable, Sendable {
    public var path: RelPath
    public var meta: FileMeta
    public init(path: RelPath, meta: FileMeta) { self.path = path; self.meta = meta }
}

/// (sync) The destination will be made to match the source.
public struct SyncPlan: Equatable, Sendable {
    /// folders to create (the destination lacks them)
    public var makeDirs: [RelPath] = []
    /// files and links to copy: new, changed, or no longer matching what was written last time
    public var copy: [PlannedFile] = []
    /// extras at the destination the source does not have, deepest first (files before their folders)
    public var delete: [RelPath] = []
    /// files found unchanged and left alone
    public var unchanged = 0
    /// bytes to copy
    public var bytes: Int64 = 0

    public var summary: String {
        var parts: [String] = []
        if !copy.isEmpty { parts.append("copy \(copy.count)") }
        if !makeDirs.isEmpty { parts.append("make \(makeDirs.count) folder\(makeDirs.count == 1 ? "" : "s")") }
        if !delete.isEmpty { parts.append("delete \(delete.count)") }
        if parts.isEmpty { return "nothing to do — already in sync" }
        return parts.joined(separator: ", ") + " · \(unchanged) unchanged"
    }
}

/// (backups) A new dated folder.
public struct BackupPlan: Equatable, Sendable {
    public var kind: BackupChoice
    public var folderName: String
    /// the backup an incremental is measured against
    public var basedOn: String?
    public var makeDirs: [RelPath] = []
    public var copy: [PlannedFile] = []
    /// gone from the source since `basedOn`
    public var deleted: [RelPath] = []
    /// the whole source as it is now (saved in the manifest)
    public var snapshot: Snapshot
    public var unchanged = 0
    public var bytes: Int64 = 0

    public var summary: String {
        let what = kind == .full ? "full copy" : "incremental"
        var s = "\(what): \(copy.count) file\(copy.count == 1 ? "" : "s"), \(ByteCount.string(bytes))"
        if kind == .incremental { s += " · \(unchanged) unchanged · \(deleted.count) deleted since" }
        return s
    }
}

public enum Planner {
    /// What a sync needs to do. `state` is the record from the last run (nil the first time, or when unreadable);
    /// `destination` is what is at the destination now (nil = not looked at; then only the record is trusted).
    public static func sync(source: Snapshot, state: SyncState?, destination: Snapshot?, deleteExtras: Bool) -> SyncPlan {
        var plan = SyncPlan()
        for path in source.keys.sorted() {
            let meta = source[path]!
            if meta.isDirectory && !meta.isSymlink {
                if destination?[path]?.isDirectory != true { plan.makeDirs.append(path) }
                continue
            }
            let recorded = state?.files[path]
            let there = destination?[path]
            var needs = false
            if let recorded {
                if !recorded.source.matches(meta) { needs = true }                       // the source changed
                else if let dest = destination { needs = !(there.map { $0.matches(recorded.written) } ?? false) } // the copy changed or vanished
            } else if let there {
                needs = !there.matches(meta)                                             // no record: trust what is there if it matches
            } else {
                needs = true
            }
            if needs { plan.copy.append(PlannedFile(path: path, meta: meta)); if !meta.isSymlink { plan.bytes += meta.size } }
            else { plan.unchanged += 1 }
        }
        if deleteExtras {
            let known: Set<RelPath> = destination.map { Set($0.keys) } ?? Set(state?.files.keys ?? [:].keys)
            let extras = known.subtracting(source.keys)
            // deepest first, so files go before the folders that hold them
            plan.delete = extras.sorted { a, b in
                let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                return da != db ? da > db : a > b
            }
        }
        return plan
    }

    /// What a backup folder will hold. For an incremental, `parent` is the manifest it is measured against.
    public static func backup(kind: BackupChoice, folderName: String, source: Snapshot, parent: Manifest?) -> BackupPlan {
        var plan = BackupPlan(kind: kind, folderName: folderName, basedOn: parent.map { _ in "" }, snapshot: source)
        plan.basedOn = nil
        let base = kind == .incremental ? (parent?.snapshot ?? [:]) : [:]
        for path in source.keys.sorted() {
            let meta = source[path]!
            if meta.isDirectory && !meta.isSymlink {
                if kind == .full || base[path]?.isDirectory != true { plan.makeDirs.append(path) }
                continue
            }
            if let was = base[path], was.matches(meta) { plan.unchanged += 1; continue }
            plan.copy.append(PlannedFile(path: path, meta: meta))
            if !meta.isSymlink { plan.bytes += meta.size }
        }
        if kind == .incremental {
            plan.deleted = Set(base.keys).subtracting(source.keys).sorted()
        }
        return plan
    }
}

public enum ByteCount {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
