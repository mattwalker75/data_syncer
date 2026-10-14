// Puts a backup back: the chain's full backup first, then each incremental up to the chosen restore point, into a
// folder the user picks. "Remove files that were deleted" decides whether a file an incremental recorded as
// deleted ends up gone, or is left for the user to sort out (owner decision: both, their choice).
import Foundation

public struct RestorePlan: Equatable, Sendable {
    /// oldest first: the full, then the incrementals
    public var chain: [String]
    public var fileCount: Int
    public var bytes: Int64
    public var deletions: Int
    /// files a backup in the chain could not copy at the time: they will be missing from the result
    public var missing: [RelPath] = []
    public var summary: String {
        "\(chain.count) backup\(chain.count == 1 ? "" : "s") to apply · \(fileCount) files · \(ByteCount.string(bytes))" +
            (deletions > 0 ? " · \(deletions) deletions recorded along the way" : "") +
            (missing.isEmpty ? "" : " · \(missing.count) file\(missing.count == 1 ? "" : "s") the backups never managed to copy")
    }
}

public struct RestoreResult: Equatable, Sendable {
    public var status: DestinationStatus
    public var restored = 0
    public var removed = 0
    public var skipped = 0
    public var problems: [String] = []
    public var startedAt: Date
    public var finishedAt: Date
}

public enum RestoreEvent: Sendable {
    /// a check before copying: what was checked, whether it passed, and the detail
    case check(name: String, ok: Bool, detail: String)
    case planned(RestorePlan)
    case applying(backup: String, index: Int, of: Int)
    case progress(RunProgress)
    case file(RelPath, FileAction)
}

public enum RestoreEngine {
    /// Removes a file or link that sits where a folder is needed (at the leaf when `wantsDirectory`, and at every
    /// ancestor below `root`), so a folder that replaced a file in a later backup restores correctly.
    static func clearWay(to local: URL, wantsDirectory: Bool, in root: URL) throws {
        var ancestors: [URL] = []
        var u = local.deletingLastPathComponent()
        while u.pathComponents.count > root.pathComponents.count { ancestors.append(u); u = u.deletingLastPathComponent() }
        for a in ancestors.reversed() {
            if let m = LocalStorage.meta(at: a), !(m.isDirectory && !m.isSymlink) { try FileManager.default.removeItem(at: a) }
        }
        if wantsDirectory, let m = LocalStorage.meta(at: local), !(m.isDirectory && !m.isSymlink) { try FileManager.default.removeItem(at: local) }
    }

    /// Deletes a backup folder at the destination — the user's decision; Data Syncer never does this on its own.
    /// Returns the backups that depended on it (they can no longer be restored; everything else is unaffected).
    @discardableResult
    public static func delete(_ folder: String, from storage: Storage, catalog: BackupCatalog) async throws -> [BackupEntry] {
        guard catalog.entry(folder) != nil else { throw DSError("The backup \(folder) isn't at the destination (any more).") }
        let dependents = catalog.dependents(of: folder)
        try await storage.remove(folder)
        return dependents
    }

    /// What restoring `point` would do. Throws when the chain is broken (a missing or unreadable backup).
    public static func plan(_ catalog: BackupCatalog, point: String) throws -> RestorePlan {
        let chain = try catalog.chain(endingAt: point)
        var files = 0
        var bytes: Int64 = 0
        var deletions = 0
        var missing = Set<RelPath>()
        for e in chain {
            let m = e.manifest!
            files += m.copied.count
            bytes += m.totalBytes
            deletions += m.deleted.count
            // a file one backup failed on is only "missing" if no later backup in the chain copied it
            missing.formUnion(m.failed ?? [])
            missing.subtract(m.copied)
            missing.subtract(m.deleted)
        }
        return RestorePlan(chain: chain.map(\.folder), fileCount: files, bytes: bytes, deletions: deletions, missing: missing.sorted())
    }

    /// Restore into `target` (an existing local folder). Cancelling the Task stops it where it is.
    public static func restore(from storage: Storage, catalog: BackupCatalog, point: String, to target: URL,
                               removeDeleted: Bool, onEvent: @escaping @Sendable (RestoreEvent) -> Void) async -> RestoreResult {
        var result = RestoreResult(status: .finished, startedAt: Date(), finishedAt: Date())
        let fm = FileManager.default
        do {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
                throw DSError("The folder to restore into, \(target.path), isn't there. Make it first (an empty folder is best).")
            }
            let plan = try plan(catalog, point: point)
            onEvent(.planned(plan))
            if let free = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                let margin: Int64 = 50 * 1024 * 1024
                if free < plan.bytes + margin {
                    let msg = "Not enough space in \(target.path): \(ByteCount.string(plan.bytes)) to restore, \(ByteCount.string(free)) free."
                    onEvent(.check(name: "Free space", ok: false, detail: msg))
                    throw DSError(msg)
                }
                onEvent(.check(name: "Free space", ok: true, detail: "\(ByteCount.string(free)) free, \(ByteCount.string(plan.bytes)) needed"))
            }
            var progress = RunProgress(filesTotal: plan.fileCount, bytesTotal: plan.bytes)
            let targetResolved = target.resolvingSymlinksInPath().path
            /// nothing may be written or removed outside the target, even through a link that was restored earlier
            func inside(_ u: URL) -> Bool {
                var probe = u
                while LocalStorage.meta(at: probe) == nil, probe.pathComponents.count > target.pathComponents.count { probe = probe.deletingLastPathComponent() }
                let r = probe.resolvingSymlinksInPath().path
                return r == targetResolved || r.hasPrefix(targetResolved + "/")
            }
            for (i, folder) in plan.chain.enumerated() {
                try Task.checkCancellation()
                onEvent(.applying(backup: folder, index: i + 1, of: plan.chain.count))
                let manifest = catalog.entry(folder)!.manifest!
                // what this backup recorded as deleted goes first, so a case-only rename ends with the new name only
                if removeDeleted {
                    for path in manifest.deleted.sorted(by: { $0.count > $1.count }) {
                        let local = target.appendingPathComponent(path)
                        // the parent must be inside; the entry itself may be a link (removing a link never follows it)
                        guard inside(local.deletingLastPathComponent()) else { result.problems.append("\(path): leads outside the restore folder, left alone"); continue }
                        if LocalStorage.meta(at: local) != nil {
                            do { try fm.removeItem(at: local); result.removed += 1; onEvent(.file(path, .deleted)) }
                            catch { result.problems.append("\(path): could not remove — \(error.localizedDescription)") }
                        }
                    }
                }
                // the backup's folders first (parents before children), clearing a file or link that is in the way —
                // including a link an earlier backup in the chain restored where this one has a real folder
                for path in manifest.snapshot.keys.sorted() where manifest.snapshot[path]!.isDirectory && !manifest.snapshot[path]!.isSymlink {
                    let local = target.appendingPathComponent(path)
                    guard inside(local.deletingLastPathComponent()) else { continue }
                    do { try RestoreEngine.clearWay(to: local, wantsDirectory: true, in: target); try fm.createDirectory(at: local, withIntermediateDirectories: true) }
                    catch { result.problems.append("\(path): could not make the folder — \(error.localizedDescription)") }
                }
                for path in manifest.copied.sorted() {
                    try Task.checkCancellation()
                    guard let meta = manifest.snapshot[path] else { continue }
                    progress.currentPath = path
                    onEvent(.progress(progress))
                    let local = target.appendingPathComponent(path)
                    let action: FileAction
                    do {
                        guard inside(local.deletingLastPathComponent()) else { throw DSError("leads outside the restore folder (through a link), left alone") }
                        // a file or link where a folder is needed on the way (or at the leaf) must go first
                        try RestoreEngine.clearWay(to: local, wantsDirectory: meta.isDirectory && !meta.isSymlink, in: target)
                        if meta.isDirectory && !meta.isSymlink {
                            try fm.createDirectory(at: local, withIntermediateDirectories: true); action = .madeFolder
                        } else if meta.isSymlink {
                            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if LocalStorage.meta(at: local) != nil { try fm.removeItem(at: local) }
                            try fm.createSymbolicLink(atPath: local.path, withDestinationPath: meta.linkTarget); action = .linked
                        } else {
                            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try await storage.download(joinPath(folder, path), to: local, meta: meta); action = .copied
                        }
                        result.restored += 1
                    } catch is CancellationError { throw CancellationError() }
                    catch let e as DSError { action = .failed(e.message); result.problems.append("\(path): \(e.message)") }
                    catch { action = .failed(error.localizedDescription); result.problems.append("\(path): \(error.localizedDescription)") }
                    onEvent(.file(path, action))
                    progress.filesDone += 1
                    if !meta.isSymlink && !meta.isDirectory { progress.bytesDone += meta.size }
                }
            }
            // folder dates and permissions from the restore point's snapshot, deepest first, after everything is in
            if let last = catalog.entry(plan.chain.last!)?.manifest {
                for path in last.snapshot.keys.sorted(by: { $0.count > $1.count }) where last.snapshot[path]!.isDirectory && !last.snapshot[path]!.isSymlink {
                    try? LocalStorage.apply(last.snapshot[path]!, to: target.appendingPathComponent(path))
                }
            }
            for path in plan.missing { result.problems.append("\(path): the backups never managed to copy this file, so it is not in the result") }
            progress.currentPath = ""
            onEvent(.progress(progress))
            result.status = result.problems.isEmpty ? .finished : .finishedWithProblems
        } catch is CancellationError {
            result.status = .cancelled
        } catch let e as DSError {
            result.status = .failed(e.message)
        } catch {
            result.status = .failed(error.localizedDescription)
        }
        result.finishedAt = Date()
        return result
    }
}
