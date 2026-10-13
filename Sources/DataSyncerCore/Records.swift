// What Data Syncer writes beside the copies so a destination describes itself (owner decision, Oct 2026):
//
//   <destination folder>/.datasyncer/README.txt        what this folder is, for anyone who finds it
//   <destination folder>/.datasyncer/destination.json  which job and mode used this folder
//   <destination folder>/.datasyncer/sync-state.json   (sync) each file as it was last written here
//   <destination folder>/<backup folder>/.datasyncer/manifest.json   (backups) what that backup holds
//
// Because the records travel with the data, another Mac — or a fresh install — can run incrementals against,
// and restore from, backups it has never seen before. Nothing is kept only on the Mac that made them.
import Foundation

public enum Records {
    public static let folderName = ".datasyncer"
    public static let readmeText = """
    This is metadata used by the Data Syncer tool that is used to run adhoc backups and syncing of data from a \
    source to one or more destinations. Seeing this means this is or was a destination used by the Data Syncer tool.

    The folders beside this one are plain copies of the source: open them like any other folder. The files in \
    here let Data Syncer know what each backup holds, so it can make incremental backups and restore them. \
    Leave them in place; delete a whole backup folder if you no longer want it.
    """

    // dates as "2026-10-13T20:37:46.123Z": readable, sortable, and exact to the millisecond
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// "2026-10-13T21:04:05.123Z" or "2026-10-13T21:04:05Z" (the services and the records both use these).
    public static func parseDate(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(fractional.string(from: date))
        }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) { return date }
            throw DSError("“\(s)” is not a date Data Syncer understands.")
        }
        return d
    }()

    /// The destination record, if the folder has one.
    public static func loadDestinationRecord(from storage: Storage) async throws -> DestinationRecord? {
        let path = joinPath(folderName, "destination.json")
        guard try await storage.exists(path) else { return nil }
        return try? decoder.decode(DestinationRecord.self, from: try await storage.readData(path))
    }

    /// Make sure the README and the destination record are there. Called at the start of every run.
    /// A folder already used by another destination (of this or another job) is refused: two jobs mirroring one
    /// folder would erase each other's files. `otherJobIds` are the jobs that still exist besides this one; a
    /// record from a job that no longer exists is simply taken over.
    public static func ensure(on storage: Storage, job: Job, destination: Destination, otherJobIds: Set<UUID> = []) async throws {
        let readme = joinPath(folderName, "README.txt")
        if try await !storage.exists(readme) {
            try await storage.makeDirectory(folderName)
            try await storage.writeData(Data(readmeText.utf8), to: readme)
        }
        let path = joinPath(folderName, "destination.json")
        if let existing = try await loadDestinationRecord(from: storage) {
            if existing.destinationId == destination.id { return }
            if existing.jobId == job.id {
                throw DSError("This folder is already used by another destination of this job (“\(existing.destinationName)”). Two destinations can't share one folder — give this one a folder of its own.")
            }
            if otherJobIds.contains(existing.jobId) {
                throw DSError("This folder is already used by the job “\(existing.jobName)” (destination “\(existing.destinationName)”). Two jobs can't share one folder — a sync would erase the other job's files. Give this destination a folder of its own.")
            }
            // the job that used it is gone: take the folder over
        }
        let record = DestinationRecord(jobId: job.id, jobName: job.name, destinationId: destination.id,
                                       destinationName: destination.name, mode: destination.mode.label, since: Date())
        try await storage.writeData(try encoder.encode(record), to: path)
    }

    public static func loadSyncState(from storage: Storage) async throws -> SyncState? {
        let path = joinPath(folderName, "sync-state.json")
        guard try await storage.exists(path) else { return nil }
        do { return try decoder.decode(SyncState.self, from: try await storage.readData(path)) } catch {
            throw DSError("The sync record at \(storage.describe) could not be read (\(error.localizedDescription)). Everything will be compared file by file this time.")
        }
    }

    public static func saveSyncState(_ state: SyncState, to storage: Storage) async throws {
        try await storage.writeData(try encoder.encode(state), to: joinPath(folderName, "sync-state.json"))
    }

    public static func loadManifest(of backupFolder: String, from storage: Storage) async throws -> Manifest? {
        let path = joinPath(joinPath(backupFolder, folderName), "manifest.json")
        guard try await storage.exists(path) else { return nil }
        return try decoder.decode(Manifest.self, from: try await storage.readData(path))
    }

    public static func saveManifest(_ manifest: Manifest, of backupFolder: String, to storage: Storage) async throws {
        let dir = joinPath(backupFolder, folderName)
        try await storage.makeDirectory(dir)
        try await storage.writeData(try encoder.encode(manifest), to: joinPath(dir, "manifest.json"))
    }
}

public struct DestinationRecord: Codable, Equatable, Sendable {
    public var version = 1
    public var jobId: UUID
    public var jobName: String
    public var destinationId: UUID
    public var destinationName: String
    public var mode: String
    public var since: Date
}

/// (sync) Each file as it was written to the destination last time, and what it was copied from.
public struct SyncState: Codable, Equatable, Sendable {
    public struct Written: Codable, Equatable, Sendable {
        /// the file as the destination reported it right after the copy
        public var written: FileMeta
        /// the source file it came from
        public var source: FileMeta
    }
    public var version = 1
    public var updatedAt: Date
    public var files: [RelPath: Written]
    public init(updatedAt: Date = Date(), files: [RelPath: Written] = [:]) { self.updatedAt = updatedAt; self.files = files }
}

/// (backups) What one dated backup folder holds.
public struct Manifest: Codable, Equatable, Sendable {
    public var version = 1
    public var kind: BackupChoice
    public var createdAt: Date
    public var jobName: String
    public var title: String
    /// the backup this incremental is measured against (its folder name); nil for a full
    public var basedOn: String?
    /// the whole source as it was at this backup — a full state, so a chain can be rebuilt and compared against
    public var snapshot: Snapshot
    /// what this backup's folder actually contains (a full: everything; an incremental: only what changed)
    public var copied: [RelPath]
    /// files the backup could not copy (unreadable, locked); the next incremental copies them, a restore lacks them
    public var failed: [RelPath]?
    /// gone from the source since `basedOn` (empty for a full)
    public var deleted: [RelPath]
    public var fileCount: Int
    public var totalBytes: Int64
}

// MARK: - Backup folder names

public enum BackupNaming {
    /// "Work documents" → "Work_documents": letters, digits, - and _ only, so the name works on every file system.
    public static func sanitizeTitle(_ title: String) -> String {
        var out = ""
        for ch in title.trimmingCharacters(in: .whitespaces) {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) } else { out.append("_") }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        return out.isEmpty ? "backup" : out
    }

    /// "2026_10_20_1432_Full_Work_documents" — year first so Finder sorts them in order; the time keeps two
    /// backups on one day apart (owner decision).
    public static func folderName(kind: BackupChoice, title: String, date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy_MM_dd_HHmm"
        let word = kind == .full ? "Full" : "Incremental"
        return "\(f.string(from: date))_\(word)_\(sanitizeTitle(title))"
    }

    public struct Parsed: Equatable, Sendable {
        public var folder: String
        public var kind: BackupChoice
        public var title: String
        public var date: Date
    }

    static let pattern = try! NSRegularExpression(pattern: #"^(\d{4})_(\d{2})_(\d{2})_(\d{2})(\d{2})_(Full|Incremental)_(.+)$"#)

    /// Read a folder name back; nil when it is not one of Data Syncer's.
    public static func parse(_ folder: String, calendar: Calendar = .current) -> Parsed? {
        let range = NSRange(folder.startIndex..., in: folder)
        guard let m = pattern.firstMatch(in: folder, range: range) else { return nil }
        func part(_ i: Int) -> String { String(folder[Range(m.range(at: i), in: folder)!]) }
        var comps = DateComponents()
        comps.year = Int(part(1)); comps.month = Int(part(2)); comps.day = Int(part(3))
        comps.hour = Int(part(4)); comps.minute = Int(part(5))
        guard let date = calendar.date(from: comps) else { return nil }
        return Parsed(folder: folder, kind: part(6) == "Full" ? .full : .incremental, title: part(7), date: date)
    }
}

// MARK: - The backups found at a destination

/// One backup folder at a destination, with its record when it has one.
public struct BackupEntry: Equatable, Sendable {
    public var parsed: BackupNaming.Parsed
    /// nil = the folder is named like a backup but its record is missing or unreadable (made by hand, or damaged)
    public var manifest: Manifest?
    public var folder: String { parsed.folder }
}

public struct BackupCatalog: Sendable {
    public var entries: [BackupEntry]
    private var index: [String: BackupEntry]

    /// Every backup-named folder at the root of the storage, newest first. With `title`, only the backups of
    /// that title: another job's backups in the same folder are never part of this one's chains.
    public static func load(from storage: Storage, title: String? = nil) async throws -> BackupCatalog {
        var entries: [BackupEntry] = []
        for entry in try await storage.list("") where entry.meta.isDirectory {
            guard let parsed = BackupNaming.parse(entry.name) else { continue }
            if let title, parsed.title != title { continue }
            let manifest = try? await Records.loadManifest(of: entry.name, from: storage)
            entries.append(BackupEntry(parsed: parsed, manifest: manifest))
        }
        entries.sort { $0.parsed.date > $1.parsed.date }
        return BackupCatalog(entries: entries)
    }

    public init(entries: [BackupEntry]) {
        self.entries = entries
        index = Dictionary(entries.map { ($0.folder, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func entry(_ folder: String) -> BackupEntry? { index[folder] }

    /// The newest full backup with a readable record.
    public var newestFull: BackupEntry? { entries.first { $0.parsed.kind == .full && $0.manifest != nil } }

    /// The chain a backup belongs to, oldest first: its full backup, then each incremental down to `folder`.
    /// Throws when a link of the chain is missing or unreadable, naming it.
    public func chain(endingAt folder: String) throws -> [BackupEntry] {
        var out: [BackupEntry] = []
        var current = folder
        var seen = Set<String>()
        while true {
            guard let e = entry(current) else {
                throw DSError("The backup \(current) is missing at the destination, so backups that depend on it cannot be restored.")
            }
            guard let m = e.manifest else {
                throw DSError("The backup \(current) has no readable record (it may have been made by hand, or damaged), so it cannot be part of a restore.")
            }
            out.append(e)
            if m.kind == .full { break }
            guard let parent = m.basedOn, !seen.contains(parent) else {
                throw DSError("The backup \(current) is an incremental without a full backup to go with it.")
            }
            seen.insert(current)
            current = parent
        }
        return out.reversed()
    }

    /// The members of the newest full backup's chain, newest first (the full itself last).
    public func currentChain() -> [BackupEntry] {
        guard let full = newestFull else { return [] }
        // incrementals whose chain ends at this full
        var members: [BackupEntry] = []
        for e in entries where e.manifest?.kind == .incremental {
            if let c = try? chain(endingAt: e.folder), c.first?.folder == full.folder { members.append(e) }
        }
        return members + [full]
    }

    /// The backups that could no longer be restored if `folder` were deleted: every incremental whose chain
    /// passes through it (newest first). Empty for a backup nothing depends on.
    public func dependents(of folder: String) -> [BackupEntry] {
        entries.filter { e in
            e.folder != folder && e.manifest?.kind == .incremental
                && ((try? chain(endingAt: e.folder))?.contains { $0.folder == folder } ?? false)
        }
    }

    /// Which backup a new incremental would be measured against, and whether one is allowed at all.
    public func incrementalParent(chainStart: ChainStart, maxIncrementals: Int) -> (parent: BackupEntry?, incrementalsSoFar: Int, reason: String?) {
        guard let full = newestFull else { return (nil, 0, "There is no full backup here yet, so the first backup must be a full one.") }
        let chainMembers = currentChain()
        let count = chainMembers.count - 1
        if count >= maxIncrementals {
            return (nil, count, "This chain already has \(count) incremental backups (the limit is \(maxIncrementals)); the next backup must be a full one.")
        }
        switch chainStart {
        case .lastFull: return (full, count, nil)
        case .lastIncremental: return (chainMembers.first, count, nil)
        }
    }
}
