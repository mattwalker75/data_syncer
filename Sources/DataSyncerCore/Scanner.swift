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
    }

    /// Scan a local folder. Throws when the folder itself cannot be read.
    public static func scan(_ root: URL) throws -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw DSError("The source folder \(root.path) isn't there.")
        }
        guard fm.isReadableFile(atPath: root.path) else {
            throw DSError("The source folder \(root.path) can't be read. If it is in Desktop, Documents or another folder macOS protects, give Data Syncer Full Disk Access in System Settings → Privacy & Security.")
        }
        var snapshot: Snapshot = [:]
        var files = 0
        var bytes: Int64 = 0
        var problems: [(RelPath, String)] = []
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
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
        return Result(snapshot: snapshot, fileCount: files, totalBytes: bytes, problems: problems)
    }

    static func relative(_ url: URL, rootPath: String) -> RelPath {
        let full = url.standardizedFileURL.path
        if full == rootPath { return "" }
        if full.hasPrefix(rootPath + "/") { return String(full.dropFirst(rootPath.count + 1)) }
        return url.relativePath
    }
}
