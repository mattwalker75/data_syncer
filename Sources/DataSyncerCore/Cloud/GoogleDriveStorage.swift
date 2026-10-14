// Google Drive through the Drive API v3 with the drive.file permission (owner decision 9): Data Syncer sees only
// the files and folders it made itself, which is the safest scope — so the destination folder is made by the
// app on the user's say-so ("Make this folder"). Files keep their modified dates (modifiedTime is settable).
import Foundation

public final class GoogleDriveStorage: Storage, @unchecked Sendable {
    let tokens: TokenProvider
    /// "Data Syncer/Work documents" under My Drive
    public let rootPath: [String]
    public let describe: String
    public let keepsModifiedDates = true
    private var ids: [String: String] = [:]   // path (relative to My Drive) → file id
    private let lock = NSLock()
    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3"
    static let folderMime = "application/vnd.google-apps.folder"
    static let chunk = 8 * 1024 * 1024   // a multiple of 256 KB, as the resumable upload wants

    public init(tokens: TokenProvider, folder: String, accountLabel: String) {
        self.tokens = tokens
        rootPath = folder.split(separator: "/").map(String.init)
        describe = "Google Drive (\(accountLabel)), /\(rootPath.joined(separator: "/"))"
    }

    // MARK: requests

    private func request(_ method: String, _ url: String, query: [(String, String)] = [], json: Any? = nil) async throws -> URLRequest {
        var c = URLComponents(string: url)!
        // encoded by hand: URLComponents leaves "+" alone, and Google reads a bare "+" as a space
        if !query.isEmpty { c.percentEncodedQuery = query.map { "\(HTTP.encode($0.0))=\(HTTP.encode($0.1))" }.joined(separator: "&") }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        if let json { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = HTTP.json(json) }
        return r
    }

    private func send(_ r: URLRequest) async throws -> HTTPResponse {
        var resp = try await HTTP.send(r, service: "Google Drive")
        if resp.status == 401 {
            tokens.invalidate()
            var retry = r
            retry.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            resp = try await HTTP.send(retry, service: "Google Drive")
        }
        return resp
    }

    private func fail(_ what: String, _ r: HTTPResponse) -> DSError {
        let msg = ((r.json()?["error"] as? [String: Any])?["message"] as? String) ?? r.text.prefix(200).description
        switch r.status {
        case 401, 403 where msg.lowercased().contains("insufficient"): return DSError("Google Drive refused \(what): the sign-in no longer allows it. Sign in again in Settings → Accounts.")
        case 403: return DSError("Google Drive refused \(what): \(msg)")
        case 404: return DSError("Google Drive: \(what) — not found. \(msg)")
        case 429, 503: return DSError("Google Drive is busy (\(r.status)); try again in a minute.")
        default: return DSError("Google Drive: \(what) failed (\(r.status)) \(msg)")
        }
    }

    // MARK: path → id

    private func cached(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return ids[path] }
    private func cache(_ path: String, _ id: String?) { lock.lock(); if let id { ids[path] = id } else { ids.removeValue(forKey: path) }; lock.unlock() }
    private func forget(prefix: String) { lock.lock(); ids = ids.filter { !($0.key == prefix || $0.key.hasPrefix(prefix + "/")) }; lock.unlock() }

    private func fullPath(_ rel: RelPath) -> [String] { rootPath + rel.split(separator: "/").map(String.init) }

    /// The id of a folder or file by path; nil when it isn't there. `create` makes missing folders along the way.
    private func id(of components: [String], create: Bool = false) async throws -> String? {
        var parent = "root"
        var sofar: [String] = []
        for name in components {
            sofar.append(name)
            let key = sofar.joined(separator: "/")
            if let c = cached(key) { parent = c; continue }
            let q = "'\(parent)' in parents and name = '\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))' and trashed = false"
            let r = try await send(try await request("GET", "\(GoogleDriveStorage.api)/files", query: [("q", q), ("fields", "files(id,mimeType,modifiedTime)"), ("pageSize", "10")]))
            guard r.ok else { throw fail("looking up \(key)", r) }
            let files = (r.json()?["files"] as? [[String: Any]]) ?? []
            // Drive allows several files with one name in a folder: always take the newest, so runs stay consistent
            if let f = GoogleDriveStorage.newest(files), let id = f["id"] as? String {
                cache(key, id); parent = id
            } else if create {
                let m: [String: Any] = ["name": name, "mimeType": GoogleDriveStorage.folderMime, "parents": [parent]]
                let c = try await send(try await request("POST", "\(GoogleDriveStorage.api)/files", query: [("fields", "id")], json: m))
                guard c.ok, let id = c.json()?["id"] as? String else { throw fail("making the folder \(key)", c) }
                cache(key, id); parent = id
            } else {
                return nil
            }
        }
        return parent
    }

    /// Drive allows several files with one name in a folder; `walk`, `list` and `stat` must all pick the same one
    /// whatever order Drive listed them in: the newest modifiedTime, then the greatest id.
    static func isNewer(_ a: [String: Any], than b: [String: Any]) -> Bool {
        let da = HTTP.date(a["modifiedTime"] as? String), db = HTTP.date(b["modifiedTime"] as? String)
        if da != db { return da > db }
        return (a["id"] as? String ?? "") > (b["id"] as? String ?? "")
    }
    static func newest(_ files: [[String: Any]]) -> [String: Any]? {
        files.max { isNewer($1, than: $0) }
    }

    private func meta(_ f: [String: Any]) -> FileMeta {
        let isDir = (f["mimeType"] as? String) == GoogleDriveStorage.folderMime
        return FileMeta(isDirectory: isDir, size: isDir ? 0 : (Int64(f["size"] as? String ?? "") ?? 0), modified: HTTP.date(f["modifiedTime"] as? String))
    }

    // MARK: Storage

    public func checkReachable() async throws {
        guard try await id(of: rootPath) != nil else {
            throw DSError("The folder /\(rootPath.joined(separator: "/")) isn't in this Google Drive yet (or wasn't made by Data Syncer — with the drive.file permission the app only sees folders it made). Use “Make this folder” in the destination's settings, then try again.")
        }
    }

    public func makeRootFolder() async throws { _ = try await id(of: rootPath, create: true) }

    public func exists(_ path: RelPath) async throws -> Bool { try await id(of: fullPath(path)) != nil }

    public func stat(_ path: RelPath) async throws -> FileMeta? {
        guard let id = try await id(of: fullPath(path)) else { return nil }
        let r = try await send(try await request("GET", "\(GoogleDriveStorage.api)/files/\(id)", query: [("fields", "id,mimeType,size,modifiedTime")]))
        if r.status == 404 { cache(fullPath(path).joined(separator: "/"), nil); return nil }
        guard r.ok, let f = r.json() else { throw fail("looking at \(path)", r) }
        return meta(f)
    }

    public func list(_ dir: RelPath) async throws -> [Entry] {
        guard let id = try await id(of: fullPath(dir)) else { return [] }
        var out: [Entry] = []
        var best: [String: [String: Any]] = [:]   // name → the file chosen so far (for the tie-break)
        var token: String?
        repeat {
            var q = [("q", "'\(id)' in parents and trashed = false"), ("fields", "nextPageToken,files(id,name,mimeType,size,modifiedTime)"), ("pageSize", "1000")]
            if let t = token { q.append(("pageToken", t)) }
            let r = try await send(try await request("GET", "\(GoogleDriveStorage.api)/files", query: q))
            guard r.ok, let json = r.json() else { throw fail("listing \(dir)", r) }
            for f in (json["files"] as? [[String: Any]]) ?? [] {
                guard let name = f["name"] as? String, let fid = f["id"] as? String else { continue }
                if let i = out.firstIndex(where: { $0.name == name }) {
                    // a duplicate name: keep the newest (the one id(of:) would pick)
                    if let other = best[name], GoogleDriveStorage.isNewer(f, than: other) { best[name] = f; out[i] = Entry(name: name, meta: meta(f)); cache((fullPath(dir) + [name]).joined(separator: "/"), fid) }
                    continue
                }
                cache((fullPath(dir) + [name]).joined(separator: "/"), fid)
                best[name] = f
                out.append(Entry(name: name, meta: meta(f)))
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        return out
    }

    /// The whole tree in as few requests as possible: one listing of everything the app can see, assembled by
    /// parent ids under the folder (instead of one request per folder).
    public func walk(_ dir: RelPath) async throws -> Snapshot {
        guard let rootId = try await id(of: fullPath(dir)) else { return [:] }
        var all: [String: [String: Any]] = [:]   // id → file
        var byParent: [String: [[String: Any]]] = [:]
        var token: String?
        repeat {
            var q = [("q", "trashed = false"), ("fields", "nextPageToken,files(id,name,mimeType,size,modifiedTime,parents)"), ("pageSize", "1000")]
            if let t = token { q.append(("pageToken", t)) }
            let r = try await send(try await request("GET", "\(GoogleDriveStorage.api)/files", query: q))
            guard r.ok, let json = r.json() else { throw fail("listing \(dir)", r) }
            for f in (json["files"] as? [[String: Any]]) ?? [] {
                guard let id = f["id"] as? String else { continue }
                all[id] = f
                for p in (f["parents"] as? [String]) ?? [] { byParent[p, default: []].append(f) }
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        var out: Snapshot = [:]
        var queue: [(String, String)] = [(rootId, "")]
        var i = 0
        while i < queue.count {
            let (parent, prefix) = queue[i]; i += 1
            var seen: [String: [String: Any]] = [:]
            for f in byParent[parent] ?? [] {
                guard let name = f["name"] as? String else { continue }
                if let other = seen[name], !GoogleDriveStorage.isNewer(f, than: other) { continue }
                seen[name] = f
            }
            for (name, f) in seen {
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                if dir.isEmpty, rel == Records.folderName || rel.hasPrefix(Records.folderName + "/") { continue }
                let m = meta(f)
                out[rel] = m
                if let fid = f["id"] as? String {
                    cache((fullPath(dir) + rel.split(separator: "/").map(String.init)).joined(separator: "/"), fid)
                    if m.isDirectory { queue.append((fid, rel)) }
                }
            }
        }
        return out
    }

    public func makeDirectory(_ path: RelPath) async throws { _ = try await id(of: fullPath(path), create: true) }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        guard let id = try await id(of: fullPath(path)) else { return }
        let r = try await send(try await request("DELETE", "\(GoogleDriveStorage.api)/files/\(id)"))
        guard r.ok || r.status == 404 else { throw fail("deleting \(path)", r) }
        forget(prefix: fullPath(path).joined(separator: "/"))
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let comps = fullPath(path)
        guard let parent = try await id(of: Array(comps.dropLast()), create: true) else { throw DSError("The folder for \(path) could not be made in Google Drive.") }
        let existing = try await id(of: comps)
        let metadata: [String: Any] = existing == nil
            ? ["name": comps.last!, "parents": [parent], "modifiedTime": HTTP.dateString(meta.modified)]
            : ["modifiedTime": HTTP.dateString(meta.modified)]
        let url = existing.map { "\(GoogleDriveStorage.uploadAPI)/files/\($0)" } ?? "\(GoogleDriveStorage.uploadAPI)/files"
        var start = try await request(existing == nil ? "POST" : "PATCH", url, query: [("uploadType", "resumable"), ("fields", "id")], json: metadata)
        start.setValue(String(meta.size), forHTTPHeaderField: "X-Upload-Content-Length")
        let s = try await send(start)
        guard s.ok, let session = s.header("location") else { throw fail("starting the upload of \(path)", s) }
        var offset: Int64 = 0
        var finalId: String?
        var done = false
        repeat {
            try Task.checkCancellation()
            let chunk = meta.size == 0 ? Data() : try HTTP.chunk(of: localURL, offset: offset, length: GoogleDriveStorage.chunk)
            var put = URLRequest(url: URL(string: session)!)
            put.httpMethod = "PUT"
            let end = offset + Int64(chunk.count)
            put.setValue(meta.size == 0 ? "bytes */0" : "bytes \(offset)-\(end - 1)/\(meta.size)", forHTTPHeaderField: "Content-Range")
            let r = try await HTTP.upload(put, data: chunk, service: "Google Drive")
            if r.status == 308 {
                // Google says how much it has: "Range: bytes=0-N" (nothing = nothing yet); carry on from there
                if let range = r.header("range"), let dash = range.lastIndex(of: "-"), let last = Int64(range[range.index(after: dash)...]) { offset = last + 1 }
                else if r.header("range") == nil { offset = 0 } else { offset = end }
                if meta.size == 0 { throw DSError("Google Drive did not finish the empty file \(path).") }
            } else if r.ok {
                offset = meta.size
                finalId = r.json()?["id"] as? String
                done = true
            } else {
                throw fail("uploading \(path)", r)
            }
            progress?(offset)
        } while !done && offset < meta.size
        if !done {
            // all bytes sent but no final answer yet: ask where things stand
            var ask = URLRequest(url: URL(string: session)!); ask.httpMethod = "PUT"; ask.setValue("bytes */\(meta.size)", forHTTPHeaderField: "Content-Range")
            let r = try await HTTP.upload(ask, data: Data(), service: "Google Drive")
            guard r.ok else { throw fail("finishing the upload of \(path)", r) }
            finalId = r.json()?["id"] as? String
        }
        if let finalId { cache(comps.joined(separator: "/"), finalId) }
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        guard let id = try await id(of: fullPath(path)) else { throw DSError("\(path) isn't in Google Drive any more.") }
        let r = try await HTTP.download(try await request("GET", "\(GoogleDriveStorage.api)/files/\(id)", query: [("alt", "media")]), to: localURL, service: "Google Drive")
        guard r.ok else { throw fail("reading \(path)", r) }
        try LocalStorage.apply(meta, to: localURL)
    }

    public func readData(_ path: RelPath) async throws -> Data {
        guard let id = try await id(of: fullPath(path)) else { throw DSError("\(path) isn't in Google Drive.") }
        let r = try await send(try await request("GET", "\(GoogleDriveStorage.api)/files/\(id)", query: [("alt", "media")]))
        guard r.ok else { throw fail("reading \(path)", r) }
        return r.data
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ds-" + UUID().uuidString)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await upload(localURL: tmp, to: path, meta: FileMeta(size: Int64(data.count), modified: Date().timeIntervalSince1970), progress: nil)
    }

    public func freeSpace() async throws -> Int64? {
        let r = try await send(try await request("GET", "\(GoogleDriveStorage.api)/about", query: [("fields", "storageQuota")]))
        guard r.ok, let q = r.json()?["storageQuota"] as? [String: Any], let limit = Int64(q["limit"] as? String ?? ""), let used = Int64(q["usage"] as? String ?? "") else { return nil }
        return max(0, limit - used)
    }

    public func stopReason() -> String? {
        tokens.signInRefused ? "The sign-in for this account was refused by the service. Sign in again in Settings → Accounts." : nil
    }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        throw DSError("Google Drive can't hold links, so this link was skipped (it points to \(target)).")
    }

    /// Who is signed in, for the account's label.
    public static func whoAmI(_ tokens: TokenProvider) async throws -> String {
        var r = URLRequest(url: URL(string: "\(api)/about?fields=user")!)
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let resp = try await HTTP.send(r, service: "Google Drive")
        return ((resp.json()?["user"] as? [String: Any])?["emailAddress"] as? String) ?? "Google Drive"
    }
}
