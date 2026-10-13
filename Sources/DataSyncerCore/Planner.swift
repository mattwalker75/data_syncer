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
    /// things at the destination that are in the way — a file where the source has a folder, a folder or link
    /// where it has a file — removed first, deepest first
    public var replace: [RelPath] = []
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
    /// deletions that were NOT planned because the source could not be read there
    public var heldBack = 0
    /// a plain warning when the plan looks like a mistake (an empty source, deleting most of the destination);
    /// the preview shows it, and a run without a preview refuses to go ahead
    public var warning: String?

    public var summary: String {
        var parts: [String] = []
        if !copy.isEmpty { parts.append("copy \(copy.count)") }
        if !makeDirs.isEmpty { parts.append("make \(makeDirs.count) folder\(makeDirs.count == 1 ? "" : "s")") }
        if !replace.isEmpty { parts.append("replace \(replace.count)") }
        if !delete.isEmpty { parts.append("delete \(delete.count)") }
        if parts.isEmpty { return "nothing to do — already in sync" }
        var s = parts.joined(separator: ", ") + " · \(unchanged) unchanged"
        if heldBack > 0 { s += " · \(heldBack) deletion\(heldBack == 1 ? "" : "s") held back (source unreadable there)" }
        return s
    }
}

/// Is `path` at or under one of the paths the scan could not read?
func isUnder(_ path: RelPath, _ unreadable: Set<RelPath>) -> Bool {
    if unreadable.isEmpty { return false }
    if unreadable.contains(path) { return true }
    var p = (path as NSString).deletingLastPathComponent
    while !p.isEmpty { if unreadable.contains(p) { return true }; p = (p as NSString).deletingLastPathComponent }
    return false
}

/// Deepest first, so files go before the folders that hold them.
func deepestFirst(_ paths: some Collection<RelPath>) -> [RelPath] {
    paths.sorted { a, b in
        let da = a.split(separator: "/").count, db = b.split(separator: "/").count
        return da != db ? da > db : a > b
    }
}

/// A folder, a file, or a link: what the source wants and what the destination has must agree.
func sameShape(_ a: FileMeta, _ b: FileMeta) -> Bool {
    a.isSymlink == b.isSymlink && (a.isSymlink || a.isDirectory == b.isDirectory)
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
    /// `unreadable` are paths the scan could not read: nothing at or under them counts as gone from the source.
    public static func sync(source: Snapshot, state: SyncState?, destination: Snapshot?, deleteExtras: Bool,
                            unreadable: Set<RelPath> = []) -> SyncPlan {
        var plan = SyncPlan()
        var inTheWay = Set<RelPath>()
        for path in source.keys.sorted() {
            let meta = source[path]!
            if let there = destination?[path], !sameShape(meta, there) { inTheWay.insert(path) }
            if meta.isDirectory && !meta.isSymlink {
                if !(destination?[path].map { $0.isDirectory && !$0.isSymlink } ?? false) { plan.makeDirs.append(path) }
                continue
            }
            let recorded = state?.files[path]
            let there = inTheWay.contains(path) ? nil : destination?[path]
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
        // what is in the way goes before the folders are made; anything under a replaced folder goes with it
        plan.replace = deepestFirst(inTheWay)
        if deleteExtras {
            let known: Set<RelPath> = destination.map { Set($0.keys) } ?? Set(state?.files.keys ?? [:].keys)
            var extras = known.subtracting(source.keys)
            let held = extras.filter { isUnder($0, unreadable) }
            plan.heldBack = held.count
            extras.subtract(held)
            extras = extras.filter { e in !inTheWay.contains { e.hasPrefix($0 + "/") } }
            plan.delete = deepestFirst(extras)
            // a wipe that is probably a mistake: an empty source, or most of the destination going
            let sourceFiles = source.values.filter { !$0.isDirectory }.count
            let knownFiles = (destination ?? [:]).values.filter { !$0.isDirectory }.count
            if sourceFiles == 0 && !plan.delete.isEmpty {
                plan.warning = "The source has no files at all, so this sync would delete everything at the destination (\(plan.delete.count) items). If the source is a drive or share that isn't connected, connect it first."
            } else if knownFiles >= 20 && plan.delete.count * 2 > knownFiles {
                plan.warning = "This sync would delete \(plan.delete.count) of the \(knownFiles) files at the destination. Check that the source is the right folder before going ahead."
            }
        }
        return plan
    }

    /// What a backup folder will hold. For an incremental, `parent` is the manifest it is measured against.
    public static func backup(kind: BackupChoice, folderName: String, source: Snapshot, parent: Manifest?,
                              unreadable: Set<RelPath> = []) -> BackupPlan {
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
            // files the parent backup could not copy count as new, so they are picked up now
            let missing = Set(parent?.failed ?? [])
            for path in missing where source[path] != nil && !plan.copy.contains(where: { $0.path == path }) {
                let meta = source[path]!
                if meta.isDirectory && !meta.isSymlink { continue }
                plan.copy.append(PlannedFile(path: path, meta: meta)); plan.unchanged -= 1
                if !meta.isSymlink { plan.bytes += meta.size }
            }
            plan.copy.sort { $0.path < $1.path }
            plan.deleted = Set(base.keys).subtracting(source.keys).filter { !isUnder($0, unreadable) }.sorted()
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
