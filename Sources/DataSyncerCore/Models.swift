// The things Data Syncer works with: a job (one source, several destinations), a destination (where copies go
// and how), and the small value types the rest of the core shares.
//
// Everything here is plain data (Codable) so the jobs file, the records at a destination and the tests all use
// the same shapes. Rules live in the engines (Planner, Runner, Restore), never here.
import Foundation

/// A relative path inside a source or destination: "Clients/Acme/notes.md". Always "/"-separated, never leading "/".
public typealias RelPath = String

/// A plain-English problem the user sees as it is. Every error the core raises is one of these.
public struct DSError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What a file or folder looks like, used for comparing a source with a destination and for the records.
public struct FileMeta: Codable, Equatable, Sendable {
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// bytes (0 for a folder or a link)
    public var size: Int64
    /// seconds since 1970, as the file system reports it
    public var modified: TimeInterval
    /// where a symlink points (as written), empty otherwise
    public var linkTarget: String
    /// POSIX permission bits, kept on local, USB and network copies; nil when the storage has none
    public var permissions: Int16?

    public init(isDirectory: Bool = false, isSymlink: Bool = false, size: Int64 = 0, modified: TimeInterval = 0,
                linkTarget: String = "", permissions: Int16? = nil) {
        self.isDirectory = isDirectory; self.isSymlink = isSymlink; self.size = size; self.modified = modified
        self.linkTarget = linkTarget; self.permissions = permissions
    }

    /// FAT and exFAT drives keep modified times to 2 seconds; cloud storage rounds them too. Within that, "same".
    public static let timeTolerance: TimeInterval = 2

    /// The same content, as far as size and modified date can tell (what a sync and an incremental compare).
    public func matches(_ other: FileMeta) -> Bool {
        if isDirectory != other.isDirectory || isSymlink != other.isSymlink { return false }
        if isDirectory { return true }
        if isSymlink { return linkTarget == other.linkTarget }
        return size == other.size && abs(modified - other.modified) <= FileMeta.timeTolerance
    }
}

/// Every file and folder under a root, by relative path. Folders are included so empty ones are kept.
public typealias Snapshot = [RelPath: FileMeta]

// MARK: - Destinations

/// The kinds of place a destination can be. Step 1 builds local folders; the others follow in later steps.
public enum DestinationKind: Codable, Equatable, Sendable {
    /// a folder on this Mac (also iCloud Drive, or any cloud service that shows up as a folder)
    case localFolder
    /// a drive found by its name under /Volumes; the folder is inside it
    case usbDrive(volumeName: String)
    /// an SMB/AFP share: already connected in Finder, or connected by the app from `url`
    case networkShare(url: String)
    case sftp(host: String, port: Int, user: String, keyPath: String?)
    /// `account` is a CloudAccount id (the access key id and secret key live there)
    case s3(account: String, bucket: String, region: String, endpoint: String?)
    /// `account` is a CloudAccount id
    case googleDrive(account: String)
    case dropbox(account: String)
    case oneDrive(account: String)

    /// the cloud account this destination signs in with, if any
    public var cloudAccount: String? {
        switch self {
        case .s3(let a, _, _, _), .googleDrive(let a), .dropbox(let a), .oneDrive(let a): return a
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .localFolder: return "Folder on this Mac"
        case .usbDrive(let v): return "USB drive “\(v)”"
        case .networkShare(let u): return "Network share \(u)"
        case .sftp(let h, _, let u, _): return "SFTP \(u)@\(h)"
        case .s3(_, let b, _, _): return "Amazon S3 “\(b)”"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        }
    }
}

/// For a Full + incremental destination: what an incremental backup is measured against.
public enum ChainStart: String, Codable, Sendable {
    /// only what changed since the newest backup in the chain (full or incremental): smallest, "increments of increments"
    case lastIncremental
    /// everything that changed since the chain's full backup: each incremental is complete on its own
    case lastFull
}

/// What a destination does with the source.
public enum DestinationMode: Codable, Equatable, Sendable {
    /// the destination folder is made to match the source; `deleteExtras` = files the source no longer has go too
    case sync(deleteExtras: Bool)
    /// every run makes a new dated folder holding a complete copy
    case fullOnly
    /// dated folders: full backups and incrementals that depend on them; `maxIncrementals` per chain before a full is required
    case fullIncremental(chainStart: ChainStart, maxIncrementals: Int)

    public var label: String {
        switch self {
        case .sync: return "Sync"
        case .fullOnly: return "Full only"
        case .fullIncremental: return "Full + incremental"
        }
    }
}

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// what the user calls it
    public var name: String
    public var kind: DestinationKind
    /// the folder inside the location that holds this destination's copies (the dated backup folders, or the mirror)
    public var folder: String
    public var mode: DestinationMode
    public var enabled: Bool
    /// the <title> in "2026_10_20_1432_Full_<title>"; empty = the job's name
    public var backupTitle: String

    public init(id: UUID = UUID(), name: String, kind: DestinationKind, folder: String, mode: DestinationMode,
                enabled: Bool = true, backupTitle: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.folder = folder; self.mode = mode
        self.enabled = enabled; self.backupTitle = backupTitle
    }
}

// MARK: - Jobs

public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// the source: always a folder on this Mac
    public var sourcePath: String
    public var destinations: [Destination]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, sourcePath: String, destinations: [Destination] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.sourcePath = sourcePath; self.destinations = destinations; self.createdAt = createdAt
    }

    public var sourceURL: URL { URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath, isDirectory: true) }

    /// A copy of the job renamed to `newName` whose backup destinations keep the titles they had (the title
    /// defaults to the job's name, so a plain rename would start a new backup family and orphan the old one).
    public func renamed(_ newName: String) -> Job {
        var j = self
        for i in j.destinations.indices where j.destinations[i].backupTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            if case .sync = j.destinations[i].mode { continue }
            j.destinations[i].backupTitle = name
        }
        j.name = newName
        return j
    }

    /// The title used in a destination's backup folder names.
    public func backupTitle(for destination: Destination) -> String {
        let raw = destination.backupTitle.trimmingCharacters(in: .whitespaces)
        return BackupNaming.sanitizeTitle(raw.isEmpty ? name : raw)
    }
}

/// What kind of backup a run makes to a destination (chosen per destination on the run screen).
public enum BackupChoice: String, Codable, Sendable {
    case full
    case incremental
}
