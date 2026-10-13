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
    public var summary: String {
        "\(chain.count) backup\(chain.count == 1 ? "" : "s") to apply · \(fileCount) files · \(ByteCount.string(bytes))" +
            (deletions > 0 ? " · \(deletions) deletions recorded along the way" : "")
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
        for e in chain {
            let m = e.manifest!
            files += m.copied.count
            bytes += m.totalBytes
            deletions += m.deleted.count
        }
        return RestorePlan(chain: chain.map(\.folder), fileCount: files, bytes: bytes, deletions: deletions)
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
            for (i, folder) in plan.chain.enumerated() {
                try Task.checkCancellation()
                onEvent(.applying(backup: folder, index: i + 1, of: plan.chain.count))
                let manifest = catalog.entry(folder)!.manifest!
                for path in manifest.copied.sorted() {
                    try Task.checkCancellation()
                    guard let meta = manifest.snapshot[path] else { continue }
                    progress.currentPath = path
                    onEvent(.progress(progress))
                    let local = target.appendingPathComponent(path)
                    let action: FileAction
                    do {
                        if meta.isDirectory && !meta.isSymlink {
                            try fm.createDirectory(at: local, withIntermediateDirectories: true); action = .madeFolder
                        } else if meta.isSymlink {
                            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if fm.fileExists(atPath: local.path) || (try? local.checkResourceIsReachable()) == true { try? fm.removeItem(at: local) }
                            try fm.createSymbolicLink(atPath: local.path, withDestinationPath: meta.linkTarget); action = .linked
                        } else {
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
                // folders the backup holds but did not need to copy (an incremental's unchanged tree) — make the empty ones
                for (path, meta) in manifest.snapshot where meta.isDirectory && !meta.isSymlink {
                    try? fm.createDirectory(at: target.appendingPathComponent(path), withIntermediateDirectories: true)
                }
                if removeDeleted {
                    for path in manifest.deleted.sorted(by: { $0.count > $1.count }) {
                        let local = target.appendingPathComponent(path)
                        if fm.fileExists(atPath: local.path) || (try? local.checkResourceIsReachable()) == true {
                            do { try fm.removeItem(at: local); result.removed += 1; onEvent(.file(path, .deleted)) }
                            catch { result.problems.append("\(path): could not remove — \(error.localizedDescription)") }
                        }
                    }
                }
            }
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
