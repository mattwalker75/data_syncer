// Where copies go. Every destination kind implements `Storage`; the engines only ever talk to this protocol, so
// a sync to a USB drive and a sync to S3 run the same code. Step 1 ships LocalStorage (a folder on this Mac,
// which also covers USB drives, connected network shares and cloud services that show up as a folder).
//
// Paths are RelPaths under the storage's root — the destination's configured folder.
import Foundation

public struct Entry: Equatable, Sendable {
    public var name: String
    public var meta: FileMeta
    public init(name: String, meta: FileMeta) { self.name = name; self.meta = meta }
}

public protocol Storage: AnyObject, Sendable {
    /// plain words for messages: "USB drive “Backup2TB”, /backup"
    var describe: String { get }
    /// Throws a DSError saying why the storage cannot be used right now (drive not connected, not signed in…).
    func checkReachable() async throws
    func exists(_ path: RelPath) async throws -> Bool
    func stat(_ path: RelPath) async throws -> FileMeta?
    /// immediate children of a folder
    func list(_ dir: RelPath) async throws -> [Entry]
    func makeDirectory(_ path: RelPath) async throws
    /// a file, a link, or a folder with everything in it
    func remove(_ path: RelPath) async throws
    /// Copy a local file in, keeping its modified date (and permissions where the storage has them).
    /// `progress` gets the bytes written so far, now and then.
    func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws
    /// Copy a file out to a local path, setting its modified date from `meta`.
    func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws
    func readData(_ path: RelPath) async throws -> Data
    func writeData(_ data: Data, to path: RelPath) async throws
    /// nil when the storage cannot say
    func freeSpace() async throws -> Int64?
    /// Make a symbolic link; a storage with no links throws DSError (the runner reports the file as skipped).
    func makeSymlink(_ path: RelPath, target: String) async throws
    /// Modified dates this storage can keep exactly (false: cloud services that round or replace them).
    var keepsModifiedDates: Bool { get }
    /// Give a folder its source's date and permissions (after its files are in). Storages without folder
    /// attributes do nothing (the default).
    func applyDirectoryMeta(_ path: RelPath, meta: FileMeta) async throws
    /// Every file and folder under `dir`, recursively, by relative path. The `.datasyncer` records folder at the
    /// root is left out — it is Data Syncer's, not the user's data. The default lists folder by folder; a
    /// storage that can do it in one request (SSH, cloud) overrides it.
    func walk(_ dir: RelPath) async throws -> Snapshot
    /// Called when a run or restore is done with the storage (SSH closes its shared connection). Default: nothing.
    func close() async
    /// A reason to stop this destination now rather than try the next file (a cloud sign-in the service has
    /// refused to renew). Default: nil.
    func stopReason() -> String?
}

public extension Storage {
    func walk() async throws -> Snapshot { try await walk("") }
    func applyDirectoryMeta(_ path: RelPath, meta: FileMeta) async throws {}
    func close() async {}
    func stopReason() -> String? { nil }

    func walk(_ dir: RelPath) async throws -> Snapshot {
        var out: Snapshot = [:]
        var queue: [RelPath] = [dir]
        var next = 0
        while next < queue.count {
            let current = queue[next]; next += 1
            for entry in try await list(current) {
                let path = current.isEmpty ? entry.name : current + "/" + entry.name
                if current.isEmpty && entry.name == Records.folderName { continue }
                out[path] = entry.meta
                if entry.meta.isDirectory && !entry.meta.isSymlink { queue.append(path) }
            }
        }
        return out
    }
}

/// Joins relative paths the way the storage expects ("" + "a" = "a", "a" + "b" = "a/b").
public func joinPath(_ a: RelPath, _ b: RelPath) -> RelPath {
    if a.isEmpty { return b }
    if b.isEmpty { return a }
    return a + "/" + b
}

// MARK: - A folder on this Mac

public final class LocalStorage: Storage, @unchecked Sendable {
    public let root: URL
    public let describe: String
    public let keepsModifiedDates = true
    private let fm = FileManager.default

    public init(root: URL, describe: String? = nil) {
        self.root = root.standardizedFileURL
        self.describe = describe ?? root.path
    }

    private func url(_ path: RelPath) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    public func checkReachable() async throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw DSError("The folder \(root.path) isn't there. Data Syncer never creates the destination folder itself — make it first, then try again.")
        }
        guard fm.isWritableFile(atPath: root.path) else {
            throw DSError("The folder \(root.path) is there but can't be written to. Check its permissions.")
        }
    }

    public func exists(_ path: RelPath) async throws -> Bool {
        fm.fileExists(atPath: url(path).path)
    }

    public func stat(_ path: RelPath) async throws -> FileMeta? {
        LocalStorage.meta(at: url(path))
    }

    /// What a local file looks like (without following a link); nil when it isn't there. One lstat per entry.
    public static func meta(at url: URL) -> FileMeta? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        let isLink = type == S_IFLNK, isDir = type == S_IFDIR
        let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        let size: Int64 = isDir || isLink ? 0 : Int64(st.st_size)
        let perms = Int16(st.st_mode & 0o7777)
        let target = isLink ? ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "") : ""
        return FileMeta(isDirectory: isDir, isSymlink: isLink, size: size, modified: modified, linkTarget: target, permissions: perms)
    }

    /// Refuses a path that resolves (through a link) to somewhere outside the destination folder.
    private func guardInside(_ u: URL, _ path: RelPath) throws {
        let rootResolved = root.resolvingSymlinksInPath().path
        // resolve the deepest existing ancestor; the leaf itself may not exist yet
        var probe = u
        while LocalStorage.meta(at: probe) == nil, probe.pathComponents.count > root.pathComponents.count { probe = probe.deletingLastPathComponent() }
        let resolved = probe.resolvingSymlinksInPath().path
        guard resolved == rootResolved || resolved.hasPrefix(rootResolved + "/") else {
            throw DSError("\(path) leads outside the destination folder (through a link to \(resolved)), so it was left alone.")
        }
    }

    /// Removes whatever is at a path without following links (a file, a link, or a folder with its contents).
    private func removeLeaf(_ u: URL) throws {
        if LocalStorage.meta(at: u) != nil { try fm.removeItem(at: u) }
    }

    public func list(_ dir: RelPath) async throws -> [Entry] {
        let base = url(dir)
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: base.path) } catch {
            throw DSError("Could not read the folder \(base.path): \(error.localizedDescription)")
        }
        return names.compactMap { name in
            LocalStorage.meta(at: base.appendingPathComponent(name)).map { Entry(name: name, meta: $0) }
        }
    }

    public func makeDirectory(_ path: RelPath) async throws {
        let u = url(path)
        try guardInside(u, path)
        // createDirectory "succeeds" over a link to a folder; a file or link in the way must go first
        if let m = LocalStorage.meta(at: u), !(m.isDirectory && !m.isSymlink) { try removeLeaf(u) }
        do { try fm.createDirectory(at: u, withIntermediateDirectories: true) } catch {
            throw DSError("Could not make the folder \(path): \(error.localizedDescription)")
        }
    }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        let u = url(path)
        try guardInside(u.deletingLastPathComponent(), path)
        do { try removeLeaf(u) } catch {
            throw DSError("Could not remove \(path): \(error.localizedDescription)")
        }
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let dest = url(path)
        try guardInside(dest.deletingLastPathComponent(), path)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalStorage.copyReplacing(from: localURL, to: dest, meta: meta, progress: progress)
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        try fm.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalStorage.copyReplacing(from: url(path), to: localURL, meta: meta, progress: nil)
    }

    public func applyDirectoryMeta(_ path: RelPath, meta: FileMeta) async throws {
        try LocalStorage.apply(meta, to: url(path))
    }

    public func readData(_ path: RelPath) async throws -> Data {
        try guardInside(url(path).deletingLastPathComponent(), path)
        do { return try Data(contentsOf: url(path)) } catch {
            throw DSError("Could not read \(path): \(error.localizedDescription)")
        }
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        let dest = url(path)
        try guardInside(dest.deletingLastPathComponent(), path)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: dest, options: .atomic) } catch {
            throw DSError("Could not write \(path): \(error.localizedDescription)")
        }
    }

    public func freeSpace() async throws -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        return values?.volumeAvailableCapacity.map { Int64($0) }
    }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        let dest = url(path)
        try guardInside(dest.deletingLastPathComponent(), path)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try removeLeaf(dest)
        do { try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: target) } catch {
            throw DSError("Could not make the link \(path): \(error.localizedDescription)")
        }
    }

    // MARK: helpers

    /// Copies into a temporary name beside the target and renames over it only when the copy is complete, so
    /// the old copy survives a failure or a cancel and nothing half-written is ever left under the real name.
    public static func copyReplacing(from src: URL, to dst: URL, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) throws {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(LocalStorage.partName(for: dst.lastPathComponent))
        do {
            try copyFile(from: src, to: tmp, progress: progress)
            try apply(meta, to: tmp)
            // a folder or link under the target name must go; a file is replaced in one step by rename(2)
            if let m = LocalStorage.meta(at: dst), m.isDirectory || m.isSymlink { try FileManager.default.removeItem(at: dst) }
            guard rename(tmp.path, dst.path) == 0 else {
                throw DSError("Could not put \(dst.lastPathComponent) in place: \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// A chunked copy so progress is reported while a big file copies and a cancel takes effect mid-file.
    static func copyFile(from src: URL, to dst: URL, progress: (@Sendable (Int64) -> Void)?) throws {
        guard let input = FileHandle(forReadingAtPath: src.path) else {
            throw DSError("Could not read \(src.lastPathComponent) — is it still there, and readable?")
        }
        defer { try? input.close() }
        try? FileManager.default.removeItem(at: dst)
        guard FileManager.default.createFile(atPath: dst.path, contents: nil),
              let output = FileHandle(forWritingAtPath: dst.path) else {
            throw DSError("Could not create \(dst.lastPathComponent) at the destination.")
        }
        defer { try? output.close() }
        var done: Int64 = 0
        let chunk = 4 * 1024 * 1024
        while true {
            if Task.isCancelled { throw CancellationError() }
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            done += Int64(data.count)
            progress?(done)
        }
    }

    /// Modified date and permissions, as the source had them.
    public static func apply(_ meta: FileMeta, to url: URL) throws {
        var attrs: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSince1970: meta.modified)]
        // a folder keeps its source's mode but never loses the owner's write and search bits: a read-only source
        // folder (0555) must not make its copy unwritable for the next run, or a backup undeletable
        if let p = meta.permissions { attrs[.posixPermissions] = meta.isDirectory ? Int(p) | 0o700 : Int(p) }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    /// The temporary name a copy lands under beside its target: ".<name>.datasyncer-part", shortened when the
    /// file name is so long that the suffix would push it past the file system's 255-byte limit.
    static func partName(for name: String) -> String {
        let suffix = ".datasyncer-part"
        let full = "." + name + suffix
        if full.utf8.count <= 255 { return full }
        var head = name
        while ("." + head + suffix).utf8.count > 255 - 9 { head.removeLast() }   // room for a short hash
        let hash = String(format: "%08x", name.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) })
        return "." + head + "-" + hash + suffix
    }
}
