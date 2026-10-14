// OneDrive through the Microsoft Graph API (/me/drive). Paths are addressed as /root:/folder/file; uploads keep
// the modified date (fileSystemInfo.lastModifiedDateTime); big files go up through an upload session.
import Foundation

public final class OneDriveStorage: Storage, @unchecked Sendable {
    let tokens: TokenProvider
    public let root: String
    public let describe: String
    public let keepsModifiedDates = true
    static let api = "https://graph.microsoft.com/v1.0/me/drive"
    static let small = 4 * 1024 * 1024
    static let chunk = 327_680 * 25   // ~8 MB, a multiple of 320 KiB as the upload session wants

    public init(tokens: TokenProvider, folder: String, accountLabel: String) {
        self.tokens = tokens
        root = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        describe = "OneDrive (\(accountLabel)), /\(root)"
    }

    /// "/root:/Data Syncer/Work" or "/root" for the drive itself
    private func item(_ path: RelPath, suffix: String = "") -> String {
        let full = joinPath(root, path)
        if full.isEmpty { return "\(OneDriveStorage.api)/root" + (suffix.isEmpty ? "" : "/" + suffix) }
        let encoded = full.split(separator: "/").map { HTTP.encode(String($0)) }.joined(separator: "/")
        return "\(OneDriveStorage.api)/root:/\(encoded)" + (suffix.isEmpty ? "" : ":/" + suffix)
    }

    private func request(_ method: String, _ url: String, json: Any? = nil) async throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        if let json { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = HTTP.json(json) }
        return r
    }

    private func send(_ r: URLRequest) async throws -> HTTPResponse {
        var resp = try await HTTP.send(r, service: "OneDrive")
        if resp.status == 401 {
            tokens.invalidate()
            var retry = r
            retry.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            resp = try await HTTP.send(retry, service: "OneDrive")
        }
        return resp
    }

    private func fail(_ what: String, _ r: HTTPResponse) -> DSError {
        let msg = ((r.json()?["error"] as? [String: Any])?["message"] as? String) ?? r.text.prefix(200).description
        switch r.status {
        case 401: return DSError("OneDrive refused \(what): the sign-in has expired. Sign in again in Settings → Accounts.")
        case 403: return DSError("OneDrive refused \(what): \(msg)")
        case 404: return DSError("OneDrive: \(what) — not found. \(msg)")
        case 429, 503: return DSError("OneDrive is busy (\(r.status)); try again in a minute.")
        case 507: return DSError("OneDrive is full.")
        default: return DSError("OneDrive: \(what) failed (\(r.status)) \(msg)")
        }
    }

    private func meta(_ j: [String: Any]) -> FileMeta {
        let isDir = j["folder"] != nil
        let fsi = j["fileSystemInfo"] as? [String: Any]
        return FileMeta(isDirectory: isDir, size: isDir ? 0 : ((j["size"] as? NSNumber)?.int64Value ?? 0), modified: HTTP.date((fsi?["lastModifiedDateTime"] as? String) ?? (j["lastModifiedDateTime"] as? String)))
    }

    // MARK: Storage

    public func checkReachable() async throws {
        let r = try await send(try await request("GET", item("") + "?$select=id,folder"))
        if r.status == 404 { throw DSError("The folder /\(root) isn't in this OneDrive. Data Syncer never creates the destination folder itself — use “Make this folder” in the destination's settings, or make it in OneDrive, then try again.") }
        guard r.ok else { throw fail("looking at /\(root)", r) }
        guard r.json()?["folder"] != nil else { throw DSError("/\(root) in this OneDrive is a file, not a folder. Choose a folder.") }
    }

    public func makeRootFolder() async throws {
        var sofar = ""
        for part in root.split(separator: "/").map(String.init) {
            let parent = sofar
            sofar = joinPath(sofar, part)
            let probe = try await send(try await request("GET", itemAbsolute(sofar) + "?$select=id"))
            if probe.ok { continue }
            let url = parent.isEmpty ? "\(OneDriveStorage.api)/root/children" : itemAbsolute(parent, suffix: "children")
            let r = try await send(try await request("POST", url, json: ["name": part, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"]))
            guard r.ok || r.status == 409 else { throw fail("making the folder /\(sofar)", r) }
        }
    }

    private func itemAbsolute(_ full: String, suffix: String = "") -> String {
        if full.isEmpty { return "\(OneDriveStorage.api)/root" + (suffix.isEmpty ? "" : "/" + suffix) }
        let encoded = full.split(separator: "/").map { HTTP.encode(String($0)) }.joined(separator: "/")
        return "\(OneDriveStorage.api)/root:/\(encoded)" + (suffix.isEmpty ? "" : ":/" + suffix)
    }

    public func exists(_ path: RelPath) async throws -> Bool { try await stat(path) != nil }

    public func stat(_ path: RelPath) async throws -> FileMeta? {
        let r = try await send(try await request("GET", item(path) + "?$select=id,name,size,folder,file,fileSystemInfo"))
        if r.status == 404 { return nil }
        guard r.ok, let j = r.json() else { throw fail("looking at \(path)", r) }
        return meta(j)
    }

    public func list(_ dir: RelPath) async throws -> [Entry] {
        var out: [Entry] = []
        var next: String? = item(dir, suffix: "children") + "?$select=id,name,size,folder,file,fileSystemInfo&$top=200"
        while let url = next {
            let r = try await send(try await request("GET", url))
            if r.status == 404 { return [] }
            guard r.ok, let j = r.json() else { throw fail("listing \(dir)", r) }
            for e in (j["value"] as? [[String: Any]]) ?? [] { if let name = e["name"] as? String { out.append(Entry(name: name, meta: meta(e))) } }
            next = j["@odata.nextLink"] as? String
        }
        return out
    }

    /// The whole tree in one paged request (delta), instead of one request per folder.
    public func walk(_ dir: RelPath) async throws -> Snapshot {
        let base = joinPath(root, dir)
        var out: Snapshot = [:]
        var next: String? = item(dir, suffix: "delta") + "?$select=id,name,size,folder,file,fileSystemInfo,parentReference,deleted"
        // OneDrive paths are case-insensitive and Graph reports the stored casing: compare case-insensitively
        let basePathPrefix = ("/drive/root:" + (base.isEmpty ? "" : "/" + base)).lowercased()
        while let url = next {
            let r = try await send(try await request("GET", url))
            // checkReachable proved the folder exists, so a 404 (or a drive that has no delta below the root)
            // means the listing failed — fall back to folder by folder rather than report an empty destination
            if r.status == 404 || r.status == 400 || r.status == 501 { return try await walkByFolder(dir) }
            guard r.ok, let j = r.json() else { throw fail("listing \(dir)", r) }
            for e in (j["value"] as? [[String: Any]]) ?? [] {
                guard e["deleted"] == nil, let name = e["name"] as? String, let parent = (e["parentReference"] as? [String: Any])?["path"] as? String else { continue }
                // parentReference.path is "/drive/root:/Backups/Work/sub" (percent-encoded)
                let decoded = parent.removingPercentEncoding ?? parent
                let lowered = decoded.lowercased()
                guard lowered == basePathPrefix || lowered.hasPrefix(basePathPrefix + "/") else { continue }   // the folder itself comes back too
                let relParent = String(decoded.dropFirst(basePathPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let rel = relParent.isEmpty ? name : relParent + "/" + name
                if dir.isEmpty, rel == Records.folderName || rel.hasPrefix(Records.folderName + "/") { continue }
                out[rel] = meta(e)
            }
            next = j["@odata.nextLink"] as? String
            if next == nil, j["@odata.deltaLink"] != nil { break }
        }
        return out
    }

    /// The protocol's default walk (one request per folder), for drives without delta on a sub-folder.
    private func walkByFolder(_ dir: RelPath) async throws -> Snapshot {
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

    public func makeDirectory(_ path: RelPath) async throws {
        var sofar = ""
        for part in path.split(separator: "/").map(String.init) {
            let parent = sofar
            sofar = joinPath(sofar, part)
            let r = try await send(try await request("POST", item(parent, suffix: "children"), json: ["name": part, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"]))
            guard r.ok || r.status == 409 else { throw fail("making the folder \(sofar)", r) }
        }
    }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        let r = try await send(try await request("DELETE", item(path)))
        guard r.ok || r.status == 404 else { throw fail("deleting \(path)", r) }
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let stamp = HTTP.dateString(meta.modified)
        if meta.size <= Int64(OneDriveStorage.small) {
            let data = try Data(contentsOf: localURL)
            var put = try await request("PUT", item(path, suffix: "content"))
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let r = try await HTTP.upload(put, data: data, service: "OneDrive")
            guard r.ok else { throw fail("writing \(path)", r) }
            let patch = try await send(try await request("PATCH", item(path), json: ["fileSystemInfo": ["lastModifiedDateTime": stamp]]))
            guard patch.ok else { throw fail("setting the date of \(path)", patch) }
            progress?(Int64(data.count))
            return
        }
        let body: [String: Any] = ["item": ["@microsoft.graph.conflictBehavior": "replace", "fileSystemInfo": ["lastModifiedDateTime": stamp]]]
        let s = try await send(try await request("POST", item(path, suffix: "createUploadSession"), json: body))
        guard s.ok, let uploadURL = s.json()?["uploadUrl"] as? String else { throw fail("starting the upload of \(path)", s) }
        var offset: Int64 = 0
        var resyncs = 0
        do {
            while offset < meta.size {
                try Task.checkCancellation()
                let chunk = try HTTP.chunk(of: localURL, offset: offset, length: OneDriveStorage.chunk)
                if chunk.isEmpty { break }
                var put = URLRequest(url: URL(string: uploadURL)!)
                put.httpMethod = "PUT"
                put.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(meta.size)", forHTTPHeaderField: "Content-Range")
                let r = try await HTTP.upload(put, data: chunk, service: "OneDrive")
                if r.status == 416 || r.status == 409 {
                    // the service already holds (some of) this fragment — a retried request after a lost answer:
                    // ask where it stands and carry on from there
                    guard resyncs < 5 else { throw fail("uploading \(path)", r) }
                    resyncs += 1
                    let status = try await HTTP.send(URLRequest(url: URL(string: uploadURL)!), service: "OneDrive")
                    if status.ok, let next = OneDriveStorage.nextExpected(status.json()) { offset = next; continue }
                    if status.ok, (status.json()?["nextExpectedRanges"] as? [String])?.isEmpty == true { offset = meta.size; break }   // all received
                    throw fail("uploading \(path)", r)
                }
                guard r.ok || r.status == 202 else { throw fail("uploading \(path)", r) }
                if r.status == 200 || r.status == 201 { offset = meta.size; progress?(offset); break }   // the item came back: done
                offset += Int64(chunk.count)
                progress?(offset)
            }
        } catch {
            var cancel = URLRequest(url: URL(string: uploadURL)!); cancel.httpMethod = "DELETE"
            await HTTP.sendIgnoringCancellation(cancel, service: "OneDrive")
            throw error
        }
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        let r = try await HTTP.download(try await request("GET", item(path, suffix: "content")), to: localURL, service: "OneDrive")
        guard r.ok else { throw fail("reading \(path)", r) }
        try LocalStorage.apply(meta, to: localURL)
    }

    public func readData(_ path: RelPath) async throws -> Data {
        let r = try await send(try await request("GET", item(path, suffix: "content")))
        guard r.ok else { throw fail("reading \(path)", r) }
        return r.data
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        var put = try await request("PUT", item(path, suffix: "content"))
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let r = try await HTTP.upload(put, data: data, service: "OneDrive")
        guard r.ok else { throw fail("writing \(path)", r) }
    }

    public func freeSpace() async throws -> Int64? {
        let r = try await send(try await request("GET", "\(OneDriveStorage.api)?$select=quota"))
        guard r.ok, let q = r.json()?["quota"] as? [String: Any], let remaining = (q["remaining"] as? NSNumber)?.int64Value else { return nil }
        return remaining
    }

    public func stopReason() -> String? {
        tokens.signInRefused ? "The sign-in for this account was refused by the service. Sign in again in Settings → Accounts." : nil
    }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        throw DSError("OneDrive can't hold links, so this link was skipped (it points to \(target)).")
    }

    /// "12345-" or "12345-67890" from an upload session's nextExpectedRanges → the next offset to send.
    static func nextExpected(_ json: [String: Any]?) -> Int64? {
        guard let ranges = json?["nextExpectedRanges"] as? [String], let first = ranges.first else { return nil }
        return Int64(first.split(separator: "-").first ?? "")
    }

    public static func whoAmI(_ tokens: TokenProvider) async throws -> String {
        var r = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,displayName")!)
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let resp = try await HTTP.send(r, service: "OneDrive")
        return (resp.json()?["userPrincipalName"] as? String) ?? (resp.json()?["displayName"] as? String) ?? "OneDrive"
    }
}
