// Reads a source folder into a Snapshot: every file, folder and link under it with its size and modified date.
// Nothing is skipped (the owner's decision: copy everything); a `.datasyncer` folder at the top of a source is
// left out, because a source can also be another job's destination and those records are not the user's data.
import Foundation

public enum Scanner {
    public struct Result: Sendable {
        public var snapshot: Snapshot
        public var fileCount: Int
        public var totalBytes: Int64
        /// paths the scan could not read, with the reason
        public var problems: [(RelPath, String)]
        /// the problem paths alone: nothing at or under one of these may be treated as "gone from the source"
        public var unreadable: Set<RelPath> { Set(problems.map(\.0)) }

        /// The same scan seen one level up: everything under a folder called `name` (with `meta` as that folder's
        /// own dates and permissions). For a destination that copies the source folder itself, not just what
        /// is inside it — the copy is then made from the source's parent, so every path still resolves.
        public func nested(under name: String, meta: FileMeta) -> Result {
            var out = Result(snapshot: [:], fileCount: fileCount, totalBytes: totalBytes, problems: [])
            out.snapshot.reserveCapacity(snapshot.count + 1)
            out.snapshot[name] = FileMeta(isDirectory: true, modified: meta.modified, permissions: meta.permissions)
            for (path, m) in snapshot { out.snapshot[name + "/" + path] = m }
            out.problems = problems.map { (joinPath(name, $0.0), $0.1) }
            return out
        }
    }

    /// Scan a local folder. Throws when the folder itself cannot be read.
    public static func scan(_ root: URL) throws -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw DSError("The source folder \(root.path) isn't there.")
        }
        // access() says yes for folders macOS protects (Desktop, Documents without Full Disk Access) and for
        // read-only-no-search folders; only an actual listing proves the root can be read
        guard fm.isReadableFile(atPath: root.path), (try? fm.contentsOfDirectory(atPath: root.path)) != nil else {
            throw DSError("The source folder \(root.path) can't be read. If it is in Desktop, Documents or another folder macOS protects, give Data Syncer Full Disk Access in System Settings → Privacy & Security.")
        }
        var snapshot: Snapshot = [:]
        var files = 0
        var bytes: Int64 = 0
        var problems: [(RelPath, String)] = []
        let rootPath = root.standardizedFileURL.path
        // the enumerator only needs to know what to descend into; everything else comes from one lstat per entry
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.producesRelativePathURLs],
                                             errorHandler: { url, error in
                                                 problems.append((Scanner.relative(url, rootPath: rootPath), error.localizedDescription))
                                                 return true
                                             }) else {
            throw DSError("The source folder \(root.path) could not be listed.")
        }
        for case let url as URL in enumerator {
            let rel = relative(url, rootPath: rootPath)
            if rel.isEmpty { continue }
            if rel == Records.folderName || rel.hasPrefix(Records.folderName + "/") { enumerator.skipDescendants(); continue }
            guard let meta = LocalStorage.meta(at: url) else { problems.append((rel, "could not be read")); continue }
            if meta.isSymlink { enumerator.skipDescendants() } // a link to a folder is copied as a link, not followed
            snapshot[rel] = meta
            if !meta.isDirectory && !meta.isSymlink { files += 1; bytes += meta.size }
        }
        // a problem at the root itself means nothing below it was seen: that is a failed scan, not an empty source
        if problems.contains(where: { $0.0.isEmpty }) {
            throw DSError("The source folder \(root.path) could not be listed: \(problems.first { $0.0.isEmpty }!.1) If it is in Desktop, Documents or another folder macOS protects, give Data Syncer Full Disk Access in System Settings → Privacy & Security.")
        }
        return Result(snapshot: snapshot, fileCount: files, totalBytes: bytes, problems: problems)
    }

    static func relative(_ url: URL, rootPath: String) -> RelPath {
        let full = url.standardizedFileURL.path
        if full == rootPath { return "" }
        if full.hasPrefix(rootPath + "/") { return String(full.dropFirst(rootPath.count + 1)) }
        return url.relativePath
    }
}
