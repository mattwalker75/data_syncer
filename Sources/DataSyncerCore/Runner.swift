// Runs a job: one destination after another, reporting what it does as it goes. The UI shows the events; the
// core never shows anything itself. A run can be cancelled (the Task that runs it is cancelled); a failed or
// cancelled destination does not stop the next one (owner decision: carry on, report at the end).
import Foundation

// MARK: - What a run reports

public struct Progress: Equatable, Sendable {
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var currentPath: RelPath = ""
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0) }
}

public enum FileAction: Equatable, Sendable {
    case copied, linked, madeFolder, deleted
    case skipped(String)
    case failed(String)
}

public enum RunEvent: Sendable {
    case destinationStarted(Destination.ID, String)
    /// a check before copying: what was checked, whether it passed, and the detail
    case check(Destination.ID, name: String, ok: Bool, detail: String)
    /// the plan, in words ("copy 212, delete 3 · 12,268 unchanged")
    case planned(Destination.ID, summary: String)
    case progress(Destination.ID, Progress)
    case file(Destination.ID, RelPath, FileAction)
    case destinationFinished(DestinationResult)
}

public enum DestinationStatus: Equatable, Sendable {
    case finished
    case finishedWithProblems
    case failed(String)
    case cancelled
    case skipped(String)

    public var label: String {
        switch self {
        case .finished: return "Finished"
        case .finishedWithProblems: return "Finished with problems"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        }
    }
}

public struct DestinationResult: Equatable, Sendable {
    public var destinationId: Destination.ID
    public var destinationName: String
    public var status: DestinationStatus
    public var copied = 0
    public var deleted = 0
    public var unchanged = 0
    public var skipped = 0
    public var bytes: Int64 = 0
    public var startedAt: Date
    public var finishedAt: Date
    /// the dated folder a backup went into
    public var backupFolder: String?
    public var problems: [String] = []
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

public struct RunReport: Equatable, Sendable {
    public var jobId: Job.ID
    public var jobName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var results: [DestinationResult]
    public var allFine: Bool {
        results.allSatisfy { r in
            if case .skipped = r.status { return true }
            return r.status == .finished
        }
    }
}

// MARK: - Where a destination's storage comes from

public protocol StorageFactory: Sendable {
    /// The storage for a destination's configured folder. Throws a DSError when the location is not there.
    func storage(for destination: Destination) async throws -> Storage
}

/// Local folders and USB drives. Later steps add the network and cloud kinds.
public struct DefaultStorageFactory: StorageFactory {
    public init() {}
    public func storage(for d: Destination) async throws -> Storage {
        switch d.kind {
        case .localFolder:
            let url = URL(fileURLWithPath: (d.folder as NSString).expandingTildeInPath, isDirectory: true)
            return LocalStorage(root: url, describe: "the folder \(url.path)")
        case .usbDrive(let volume):
            let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mount.path, isDirectory: &isDir), isDir.boolValue else {
                throw DSError("The drive “\(volume)” isn't connected. Plug it in (or wait for it to appear in Finder) and try again.")
            }
            let folder = d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = folder.isEmpty ? mount : mount.appendingPathComponent(folder, isDirectory: true)
            return LocalStorage(root: root, describe: "\(d.kind.label), /\(folder)")
        default:
            throw DSError("\(d.kind.label) destinations are not built yet.")
        }
    }
}

// MARK: - The runner

public final class JobRunner: @unchecked Sendable {
    public var factory: StorageFactory
    /// the clock, so tests get fixed folder names
    public var now: @Sendable () -> Date = { Date() }

    public init(factory: StorageFactory = DefaultStorageFactory()) { self.factory = factory }

    /// Run `job` to its enabled destinations, in order. `choices` says, per Full + incremental destination, whether
    /// to make a full or an incremental backup (missing = incremental when the chain allows it, else full).
    public func run(_ job: Job, choices: [Destination.ID: BackupChoice] = [:],
                    onEvent: @escaping @Sendable (RunEvent) -> Void) async -> RunReport {
        let started = now()
        var results: [DestinationResult] = []
        var source: Scanner.Result?
        for destination in job.destinations {
            if !destination.enabled {
                results.append(DestinationResult(destinationId: destination.id, destinationName: destination.name,
                                                 status: .skipped("turned off for this job"), startedAt: now(), finishedAt: now()))
                continue
            }
            let r = await runOne(job, destination, choices[destination.id], source: &source, onEvent: onEvent)
            results.append(r)
            onEvent(.destinationFinished(r))
            if Task.isCancelled { break }
        }
        return RunReport(jobId: job.id, jobName: job.name, startedAt: started, finishedAt: now(), results: results)
    }

    private func runOne(_ job: Job, _ d: Destination, _ choice: BackupChoice?, source: inout Scanner.Result?,
                        onEvent: @escaping @Sendable (RunEvent) -> Void) async -> DestinationResult {
        var result = DestinationResult(destinationId: d.id, destinationName: d.name, status: .finished, startedAt: now(), finishedAt: now())
        onEvent(.destinationStarted(d.id, d.name))
        func finish(_ status: DestinationStatus) -> DestinationResult { result.status = status; result.finishedAt = now(); return result }
        func check(_ name: String, _ ok: Bool, _ detail: String) { onEvent(.check(d.id, name: name, ok: ok, detail: detail)) }
        do {
            // 1. the source, scanned once per run
            if source == nil {
                do { source = try Scanner.scan(job.sourceURL) } catch let e as DSError { check("Source", false, e.message); throw e }
                check("Source", true, "\(source!.fileCount) files · \(ByteCount.string(source!.totalBytes))")
                for (path, why) in source!.problems.prefix(20) { result.problems.append("\(path): \(why)") }
            }
            let src = source!
            // 2. the destination
            let storage: Storage
            do { storage = try await factory.storage(for: d); try await storage.checkReachable() }
            catch let e as DSError { check("Destination", false, e.message); throw e }
            check("Destination", true, storage.describe)
            try await Records.ensure(on: storage, job: job, destination: d)
            try Task.checkCancellation()
            // 3. plan and copy
            switch d.mode {
            case .sync(let deleteExtras):
                try await runSync(job, d, storage, src, deleteExtras: deleteExtras, result: &result, onEvent: onEvent)
            case .fullOnly:
                try await runBackup(job, d, storage, src, choice: .full, chainStart: .lastFull, maxIncrementals: 0, result: &result, onEvent: onEvent)
            case .fullIncremental(let chainStart, let maxIncrementals):
                try await runBackup(job, d, storage, src, choice: choice, chainStart: chainStart, maxIncrementals: maxIncrementals, result: &result, onEvent: onEvent)
            }
            return finish(result.problems.isEmpty ? .finished : .finishedWithProblems)
        } catch is CancellationError {
            return finish(.cancelled)
        } catch let e as DSError {
            return finish(.failed(e.message))
        } catch {
            return finish(.failed(error.localizedDescription))
        }
    }

    // MARK: sync

    private func runSync(_ job: Job, _ d: Destination, _ storage: Storage, _ src: Scanner.Result, deleteExtras: Bool,
                         result: inout DestinationResult, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws {
        var state: SyncState
        do { state = try await Records.loadSyncState(from: storage) ?? SyncState() }
        catch let e as DSError { result.problems.append(e.message); state = SyncState() }
        let there = try await storage.walk()
        let plan = Planner.sync(source: src.snapshot, state: state, destination: there, deleteExtras: deleteExtras)
        onEvent(.planned(d.id, summary: plan.summary))
        try await checkSpace(storage, needed: plan.bytes, d, onEvent)
        var progress = Progress(filesTotal: plan.copy.count + plan.delete.count, bytesTotal: plan.bytes)
        result.unchanged = plan.unchanged
        state.updatedAt = now()
        defer { Task { try? await Records.saveSyncState(state, to: storage) } }
        for dir in plan.makeDirs {
            try Task.checkCancellation()
            try await storage.makeDirectory(dir)
            onEvent(.file(d.id, dir, .madeFolder))
        }
        for file in plan.copy {
            try Task.checkCancellation()
            progress.currentPath = file.path
            onEvent(.progress(d.id, progress))
            let action = await copyOne(file, from: job.sourceURL, to: storage, prefix: "", progress: &progress, onEvent: onEvent, d.id)
            onEvent(.file(d.id, file.path, action))
            switch action {
            case .copied, .linked:
                result.copied += 1
                if let written = try await storage.stat(file.path) { state.files[file.path] = .init(written: written, source: file.meta) }
            case .skipped(let why): result.skipped += 1; result.problems.append("\(file.path): \(why)"); state.files.removeValue(forKey: file.path)
            case .failed(let why): result.problems.append("\(file.path): \(why)"); state.files.removeValue(forKey: file.path)
            default: break
            }
            progress.filesDone += 1
            if !file.meta.isSymlink { progress.bytesDone += file.meta.size }
        }
        for path in plan.delete {
            try Task.checkCancellation()
            do { try await storage.remove(path); result.deleted += 1; onEvent(.file(d.id, path, .deleted)) }
            catch let e as DSError { result.problems.append("\(path): \(e.message)"); onEvent(.file(d.id, path, .failed(e.message))) }
            state.files.removeValue(forKey: path)
            progress.filesDone += 1
        }
        progress.currentPath = ""
        onEvent(.progress(d.id, progress))
        result.bytes = plan.bytes
        try await Records.saveSyncState(state, to: storage)
    }

    // MARK: backups

    private func runBackup(_ job: Job, _ d: Destination, _ storage: Storage, _ src: Scanner.Result, choice: BackupChoice?,
                           chainStart: ChainStart, maxIncrementals: Int,
                           result: inout DestinationResult, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws {
        let catalog = try await BackupCatalog.load(from: storage)
        var kind = choice ?? .incremental
        var parent: BackupEntry?
        if case .fullOnly = d.mode { kind = .full }
        if kind == .incremental {
            let (p, soFar, reason) = catalog.incrementalParent(chainStart: chainStart, maxIncrementals: maxIncrementals)
            if let reason {
                if choice == .incremental { onEvent(.check(d.id, name: "Backup chain", ok: false, detail: reason)); throw DSError(reason) }
                kind = .full
                onEvent(.check(d.id, name: "Backup chain", ok: true, detail: reason + " Making a full backup."))
            } else {
                parent = p
                onEvent(.check(d.id, name: "Backup chain", ok: true, detail: "incremental \(soFar + 1) of \(maxIncrementals), measured against \(p!.folder)"))
            }
        }
        let title = job.backupTitle(for: d)
        var folder = BackupNaming.folderName(kind: kind, title: title, date: now())
        if try await storage.exists(folder) {
            throw DSError("A backup folder named \(folder) is already there — a backup was made this same minute. Wait a minute and run again.")
        }
        let plan = Planner.backup(kind: kind, folderName: folder, source: src.snapshot, parent: parent?.manifest)
        onEvent(.planned(d.id, summary: plan.summary))
        try await checkSpace(storage, needed: plan.bytes, d, onEvent)
        result.backupFolder = folder
        result.unchanged = plan.unchanged
        var progress = Progress(filesTotal: plan.copy.count, bytesTotal: plan.bytes)
        try await storage.makeDirectory(folder)
        var ok = false
        defer {
            // a backup that did not finish is not a backup: its folder goes, so it is never mistaken for one
            if !ok { Task { try? await storage.remove(folder) } }
        }
        for dir in plan.makeDirs {
            try Task.checkCancellation()
            try await storage.makeDirectory(joinPath(folder, dir))
        }
        var copied: [RelPath] = []
        for file in plan.copy {
            try Task.checkCancellation()
            progress.currentPath = file.path
            onEvent(.progress(d.id, progress))
            let action = await copyOne(file, from: job.sourceURL, to: storage, prefix: folder, progress: &progress, onEvent: onEvent, d.id)
            onEvent(.file(d.id, file.path, action))
            switch action {
            case .copied, .linked: result.copied += 1; copied.append(file.path)
            case .skipped(let why): result.skipped += 1; result.problems.append("\(file.path): \(why)")
            case .failed(let why): result.problems.append("\(file.path): \(why)")
            default: break
            }
            progress.filesDone += 1
            if !file.meta.isSymlink { progress.bytesDone += file.meta.size }
        }
        progress.currentPath = ""
        onEvent(.progress(d.id, progress))
        let manifest = Manifest(kind: kind, createdAt: now(), jobName: job.name, title: title, basedOn: parent?.folder,
                                snapshot: plan.snapshot, copied: copied, deleted: plan.deleted,
                                fileCount: copied.count, totalBytes: plan.bytes)
        try await Records.saveManifest(manifest, of: folder, to: storage)
        result.deleted = plan.deleted.count
        result.bytes = plan.bytes
        ok = true
        _ = folder
        folder = ""
    }

    // MARK: one file

    private func copyOne(_ file: PlannedFile, from sourceRoot: URL, to storage: Storage, prefix: RelPath,
                         progress: inout Progress, onEvent: @escaping @Sendable (RunEvent) -> Void, _ id: Destination.ID) async -> FileAction {
        let target = joinPath(prefix, file.path)
        if file.meta.isSymlink {
            do { try await storage.makeSymlink(target, target: file.meta.linkTarget); return .linked }
            catch let e as DSError { return .skipped(e.message) }
            catch { return .skipped(error.localizedDescription) }
        }
        let local = sourceRoot.appendingPathComponent(file.path)
        let base = progress.bytesDone
        let snapshot = progress
        do {
            try await storage.upload(localURL: local, to: target, meta: file.meta, progress: { done in
                var p = snapshot
                p.bytesDone = base + done
                onEvent(.progress(id, p))
            })
            return .copied
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let e as DSError {
            return .failed(e.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func checkSpace(_ storage: Storage, needed: Int64, _ d: Destination, _ onEvent: @escaping @Sendable (RunEvent) -> Void) async throws {
        guard let free = try await storage.freeSpace() else { return }
        let margin: Int64 = 50 * 1024 * 1024
        if free < needed + margin {
            let msg = "Not enough space: \(ByteCount.string(needed)) to copy, \(ByteCount.string(free)) free."
            onEvent(.check(d.id, name: "Free space", ok: false, detail: msg))
            throw DSError(msg)
        }
        onEvent(.check(d.id, name: "Free space", ok: true, detail: "\(ByteCount.string(free)) free, \(ByteCount.string(needed)) needed"))
    }
}
