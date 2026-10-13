// Dropbox through its HTTP API v2. Paths are "/<folder>/<file>"; the whole tree lists in one call
// (list_folder recursive); uploads keep the modified date (client_modified); big files go up in a session.
import Foundation

public final class DropboxStorage: Storage, @unchecked Sendable {
    let tokens: TokenProvider
    public let root: String
    public let describe: String
    public let keepsModifiedDates = true
    static let api = "https://api.dropboxapi.com/2"
    static let content = "https://content.dropboxapi.com/2"
    static let chunk = 8 * 1024 * 1024

    public init(tokens: TokenProvider, folder: String, accountLabel: String) {
        self.tokens = tokens
        let f = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        root = f.isEmpty ? "" : "/" + f
        describe = "Dropbox (\(accountLabel)), \(root.isEmpty ? "/" : root)"
    }

    private func p(_ path: RelPath) -> String { path.isEmpty ? root : root + "/" + path }

    private func rpc(_ endpoint: String, _ arg: Any) async throws -> HTTPResponse {
        var r = URLRequest(url: URL(string: "\(DropboxStorage.api)/\(endpoint)")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = HTTP.json(arg)
        return try await send(r)
    }

    private func send(_ r: URLRequest) async throws -> HTTPResponse {
        var req = r
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        var resp = try await HTTP.send(req, service: "Dropbox")
        if resp.status == 401 {
            tokens.invalidate()
            req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            resp = try await HTTP.send(req, service: "Dropbox")
        }
        return resp
    }

    private func contentRequest(_ endpoint: String, arg: Any) async throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(DropboxStorage.content)/\(endpoint)")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        r.setValue(DropboxStorage.headerJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// The Dropbox-API-Arg header must be pure ASCII: every other character goes as a JSON \uXXXX escape.
    static func headerJSON(_ arg: Any) -> String {
        let raw = String(decoding: HTTP.json(arg), as: UTF8.self)
        var out = ""
        for u in raw.utf16 {
            if u < 0x80 { out.append(Character(Unicode.Scalar(u)!)) } else { out += String(format: "\\u%04X", u) }
        }
        return out
    }

    /// A content-endpoint upload with the same "expired token → refresh → once more" as `send`.
    private func uploadContent(_ endpoint: String, arg: Any, data: Data) async throws -> HTTPResponse {
        var r = try await HTTP.upload(try await contentRequest(endpoint, arg: arg), data: data, service: "Dropbox")
        if r.status == 401 { tokens.invalidate(); r = try await HTTP.upload(try await contentRequest(endpoint, arg: arg), data: data, service: "Dropbox") }
        return r
    }

    private func fail(_ what: String, _ r: HTTPResponse) -> DSError {
        let summary = (r.json()?["error_summary"] as? String) ?? r.text.prefix(200).description
        switch r.status {
        case 401: return DSError("Dropbox refused \(what): the sign-in has expired. Sign in again in Settings → Accounts.")
        case 403: return DSError("Dropbox refused \(what): \(summary). Check the app's permissions in the Dropbox App Console (files.content.write and files.content.read).")
        case 429: return DSError("Dropbox is asking Data Syncer to slow down; try again in a minute.")
        case 507: return DSError("Dropbox is full.")
        default: return DSError("Dropbox: \(what) failed (\(r.status)) \(summary)")
        }
    }

    static func isNotFound(_ r: HTTPResponse) -> Bool { r.status == 409 && ((r.json()?["error_summary"] as? String) ?? "").contains("not_found") }

    private func meta(_ e: [String: Any]) -> FileMeta {
        let isDir = (e[".tag"] as? String) == "folder"
        return FileMeta(isDirectory: isDir, size: isDir ? 0 : ((e["size"] as? NSNumber)?.int64Value ?? 0), modified: HTTP.date(e["client_modified"] as? String))
    }

    // MARK: Storage

    public func checkReachable() async throws {
        guard !root.isEmpty else { return }
        let r = try await rpc("files/get_metadata", ["path": root])
        if DropboxStorage.isNotFound(r) { throw DSError("The folder \(root) isn't in this Dropbox. Data Syncer never creates the destination folder itself — use “Make this folder” in the destination's settings, or make it in Dropbox, then try again.") }
        guard r.ok else { throw fail("looking at \(root)", r) }
    }

    public func makeRootFolder() async throws {
        guard !root.isEmpty else { return }
        let r = try await rpc("files/create_folder_v2", ["path": root, "autorename": false])
        guard r.ok || r.text.contains("conflict") else { throw fail("making the folder \(root)", r) }
    }

    public func exists(_ path: RelPath) async throws -> Bool { try await stat(path) != nil }

    public func stat(_ path: RelPath) async throws -> FileMeta? {
        if path.isEmpty && root.isEmpty { return FileMeta(isDirectory: true) }
        let r = try await rpc("files/get_metadata", ["path": p(path)])
        if DropboxStorage.isNotFound(r) { return nil }
        guard r.ok, let e = r.json() else { throw fail("looking at \(path)", r) }
        return meta(e)
    }

    public func list(_ dir: RelPath) async throws -> [Entry] {
        try await entries(p(dir), recursive: false).map { Entry(name: ($0.0 as NSString).lastPathComponent, meta: $0.1) }
    }

    public func walk(_ dir: RelPath) async throws -> Snapshot {
        let base = p(dir)
        var out: Snapshot = [:]
        for (path, m) in try await entries(base, recursive: true) {
            guard path.lowercased().hasPrefix(base.lowercased() + "/") || base.isEmpty else { continue }
            let rel = base.isEmpty ? String(path.dropFirst()) : String(path.dropFirst(base.count + 1))
            if rel.isEmpty { continue }
            if dir.isEmpty, rel == Records.folderName || rel.hasPrefix(Records.folderName + "/") { continue }
            out[rel] = m
        }
        return out
    }

    /// (path_display, meta) for everything under a folder.
    private func entries(_ path: String, recursive: Bool) async throws -> [(String, FileMeta)] {
        var out: [(String, FileMeta)] = []
        var r = try await rpc("files/list_folder", ["path": path, "recursive": recursive, "include_deleted": false, "limit": 2000])
        if DropboxStorage.isNotFound(r) { return [] }
        while true {
            guard r.ok, let json = r.json() else { throw fail("listing \(path)", r) }
            for e in (json["entries"] as? [[String: Any]]) ?? [] {
                guard let display = e["path_display"] as? String, (e[".tag"] as? String) != "deleted" else { continue }
                if display.lowercased() == path.lowercased() { continue }
                out.append((display, meta(e)))
            }
            guard (json["has_more"] as? Bool) == true, let cursor = json["cursor"] as? String else { break }
            r = try await rpc("files/list_folder/continue", ["cursor": cursor])
        }
        return out
    }

    public func makeDirectory(_ path: RelPath) async throws {
        let r = try await rpc("files/create_folder_v2", ["path": p(path), "autorename": false])
        guard r.ok || r.text.contains("conflict") else { throw fail("making the folder \(path)", r) }
    }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        let r = try await rpc("files/delete_v2", ["path": p(path)])
        if r.ok || DropboxStorage.isNotFound(r) { return }
        // a very large folder: Dropbox asks for it piecemeal
        if r.text.contains("too_many_files") {
            for (child, _) in try await entries(p(path), recursive: false) {
                let rel = String(child.dropFirst(root.count + 1))
                try await remove(rel)
            }
            let again = try await rpc("files/delete_v2", ["path": p(path)])
            guard again.ok || DropboxStorage.isNotFound(again) else { throw fail("deleting \(path)", again) }
            return
        }
        throw fail("deleting \(path)", r)
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let commit: [String: Any] = ["path": p(path), "mode": "overwrite", "mute": true, "client_modified": DropboxStorage.stamp(meta.modified)]
        if meta.size <= Int64(DropboxStorage.chunk) {
            let data = try Data(contentsOf: localURL)
            let r = try await uploadContent("files/upload", arg: commit, data: data)
            guard r.ok else { throw fail("writing \(path)", r) }
            progress?(Int64(data.count))
            return
        }
        // a session: start, append, finish
        let first = try HTTP.chunk(of: localURL, offset: 0, length: DropboxStorage.chunk)
        let s = try await uploadContent("files/upload_session/start", arg: ["close": false], data: first)
        guard s.ok, let sessionId = s.json()?["session_id"] as? String else { throw fail("starting the upload of \(path)", s) }
        var offset = Int64(first.count)
        progress?(offset)
        while offset < meta.size {
            try Task.checkCancellation()
            let chunk = try HTTP.chunk(of: localURL, offset: offset, length: DropboxStorage.chunk)
            if chunk.isEmpty { break }
            let cursor: [String: Any] = ["session_id": sessionId, "offset": offset]
            let last = offset + Int64(chunk.count) >= meta.size
            let r: HTTPResponse
            if last {
                r = try await uploadContent("files/upload_session/finish", arg: ["cursor": cursor, "commit": commit], data: chunk)
            } else {
                r = try await uploadContent("files/upload_session/append_v2", arg: ["cursor": cursor, "close": false], data: chunk)
            }
            guard r.ok else { throw fail("uploading \(path)", r) }
            offset += Int64(chunk.count)
            progress?(offset)
        }
        if offset == Int64(first.count) {   // exactly one chunk: finish with nothing more
            let r = try await uploadContent("files/upload_session/finish", arg: ["cursor": ["session_id": sessionId, "offset": offset], "commit": commit], data: Data())
            guard r.ok else { throw fail("finishing the upload of \(path)", r) }
        }
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        var r = try await HTTP.download(try await contentRequest("files/download", arg: ["path": p(path)]), to: localURL, service: "Dropbox")
        if r.status == 401 { tokens.invalidate(); r = try await HTTP.download(try await contentRequest("files/download", arg: ["path": p(path)]), to: localURL, service: "Dropbox") }
        guard r.ok else { throw fail("reading \(path)", r) }
        try LocalStorage.apply(meta, to: localURL)
    }

    public func readData(_ path: RelPath) async throws -> Data {
        let r = try await send(try await contentRequest("files/download", arg: ["path": p(path)]))
        guard r.ok else { throw fail("reading \(path)", r) }
        return r.data
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        let commit: [String: Any] = ["path": p(path), "mode": "overwrite", "mute": true]
        let r = try await uploadContent("files/upload", arg: commit, data: data)
        guard r.ok else { throw fail("writing \(path)", r) }
    }

    public func freeSpace() async throws -> Int64? {
        var r = URLRequest(url: URL(string: "\(DropboxStorage.api)/users/get_space_usage")!)
        r.httpMethod = "POST"
        let resp = try await send(r)
        guard resp.ok, let j = resp.json(), let used = (j["used"] as? NSNumber)?.int64Value,
              let alloc = j["allocation"] as? [String: Any], let total = (alloc["allocated"] as? NSNumber)?.int64Value else { return nil }
        return max(0, total - used)
    }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        throw DSError("Dropbox can't hold links, so this link was skipped (it points to \(target)).")
    }

    /// Dropbox wants whole seconds: "2015-05-12T15:50:38Z"
    static func stamp(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: t.rounded(.down)))
    }

    public static func whoAmI(_ tokens: TokenProvider) async throws -> String {
        var r = URLRequest(url: URL(string: "\(api)/users/get_current_account")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let resp = try await HTTP.send(r, service: "Dropbox")
        return (resp.json()?["email"] as? String) ?? "Dropbox"
    }
}
