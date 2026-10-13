// Amazon S3 (and S3-compatible services): an existing bucket, a key prefix as the destination folder, requests
// signed with Signature Version 4. Folders are "key/" marker objects so empty folders survive; links can't be
// kept (reported as skipped). Modified dates: the object's upload time, used consistently for list and stat.
import Foundation

public struct S3Options: Sendable, Equatable {
    public var bucket: String
    public var region: String
    /// nil = Amazon; otherwise an S3-compatible service's address, e.g. https://minio.local:9000
    public var endpoint: String?
    public var accessKey: String
    public var secretKey: String
    public init(bucket: String, region: String, endpoint: String? = nil, accessKey: String, secretKey: String) {
        self.bucket = bucket; self.region = region; self.endpoint = endpoint; self.accessKey = accessKey; self.secretKey = secretKey
    }
}

public final class S3Storage: Storage, @unchecked Sendable {
    public let options: S3Options
    /// the key prefix ("work-documents/"), empty for the bucket root
    public let prefix: String
    public let describe: String
    public let keepsModifiedDates = false
    static let partSize = 8 * 1024 * 1024
    /// tests set a fixed clock
    var now: @Sendable () -> Date = { Date() }

    public init(options: S3Options, folder: String) {
        self.options = options
        let p = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        prefix = p.isEmpty ? "" : p + "/"
        describe = "Amazon S3 “\(options.bucket)”" + (p.isEmpty ? "" : ", /\(p)")
    }

    // MARK: addressing and signing

    var baseURL: URL {
        if let e = options.endpoint, let u = URL(string: e.hasSuffix("/") ? String(e.dropLast()) : e), u.host != nil { return u.appendingPathComponent(options.bucket) }
        // a bucket name with a dot does not match Amazon's wildcard certificate: path-style for those
        if options.bucket.contains(".") { return URL(string: "https://s3.\(options.region).amazonaws.com/\(options.bucket)")! }
        return URL(string: "https://\(options.bucket).s3.\(options.region).amazonaws.com")!
    }

    /// A plain sentence when the service address or bucket name can't work; nil when they look fine.
    public static func validate(bucket: String, endpoint: String?) -> String? {
        if bucket.isEmpty { return "Enter the bucket's name." }
        if let e = endpoint?.trimmingCharacters(in: .whitespaces), !e.isEmpty {
            guard let u = URL(string: e), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else {
                return "The service address should start with https:// (or http://) and name the server, for example https://minio.local:9000."
            }
        }
        return nil
    }

    func key(_ path: RelPath) -> String { prefix + path }

    func url(key: String, query: [(String, String)] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = c.percentEncodedPath
        c.percentEncodedPath = basePath + "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { S3Storage.uriEncode(String($0)) }.joined(separator: "/")
        if !query.isEmpty { c.percentEncodedQuery = query.sorted { $0.0 < $1.0 }.map { "\(S3Storage.uriEncode($0.0))=\(S3Storage.uriEncode($0.1))" }.joined(separator: "&") }
        return c.url!
    }

    static func uriEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Signs a request (AWS Signature Version 4). `payloadHash` is the SHA-256 of the body, or UNSIGNED-PAYLOAD.
    func sign(_ req: inout URLRequest, payloadHash: String, date: Date? = nil) {
        S3Storage.sign(&req, options: options, payloadHash: payloadHash, date: date ?? now())
    }

    static func sign(_ req: inout URLRequest, options: S3Options, payloadHash: String, date: Date) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = f.string(from: date), day = String(amzDate.prefix(8))
        let url = req.url!
        req.setValue(url.host! + (url.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var headers: [(String, String)] = []
        for (k, v) in req.allHTTPHeaderFields ?? [:] {
            let name = k.lowercased()
            if name == "host" || name.hasPrefix("x-amz-") || name == "range" || name == "content-type" || name == "content-md5" {
                headers.append((name, v.trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        // URL.path drops a trailing "/", which a folder marker key needs: take the path as encoded in the URL
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawPath = comps?.percentEncodedPath ?? url.path
        let path = rawPath.isEmpty ? "/" : rawPath
        let query = comps?.percentEncodedQuery ?? ""
        let canonicalQuery = query.isEmpty ? "" : query.split(separator: "&").map { String($0).contains("=") ? String($0) : String($0) + "=" }.sorted().joined(separator: "&")
        let canonical = [req.httpMethod ?? "GET", path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(options.region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Hashing.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        var k = Hashing.hmac(Data(("AWS4" + options.secretKey).utf8), Data(day.utf8))
        k = Hashing.hmac(k, Data(options.region.utf8)); k = Hashing.hmac(k, Data("s3".utf8)); k = Hashing.hmac(k, Data("aws4_request".utf8))
        let signature = Hashing.hex(Hashing.hmac(k, Data(toSign.utf8)))
        req.setValue("AWS4-HMAC-SHA256 Credential=\(options.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }

    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private func request(_ method: String, key: String, query: [(String, String)] = [], body: Data? = nil, headers: [String: String] = [:], unsigned: Bool = false) -> URLRequest {
        var r = URLRequest(url: url(key: key, query: query))
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        sign(&r, payloadHash: unsigned ? "UNSIGNED-PAYLOAD" : Hashing.sha256Hex(body ?? Data()))
        return r
    }

    private func send(_ r: URLRequest) async throws -> HTTPResponse { try await HTTP.send(r, service: "Amazon S3 (\(options.bucket))") }

    private func fail(_ what: String, _ r: HTTPResponse) -> DSError {
        let code = S3Storage.xmlValue(r.text, "Code") ?? ""
        let msg = S3Storage.xmlValue(r.text, "Message") ?? ""
        switch (r.status, code) {
        case (403, _), (_, "SignatureDoesNotMatch"), (_, "InvalidAccessKeyId"), (_, "AccessDenied"):
            return DSError("Amazon S3 refused \(what) in “\(options.bucket)”: \(code.isEmpty ? "access denied" : code). Check the access key, the secret key and the key's permissions on this bucket.")
        case (404, "NoSuchBucket"): return DSError("The bucket “\(options.bucket)” isn't there (or isn't in region \(options.region)).")
        case (301, _), (_, "PermanentRedirect"), (_, "AuthorizationHeaderMalformed"):
            return DSError("The bucket “\(options.bucket)” is in a different region than \(options.region). \(msg)")
        default: return DSError("Amazon S3: \(what) failed (\(r.status) \(code)) \(msg)".trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: Storage

    public func checkReachable() async throws {
        if let why = S3Storage.validate(bucket: options.bucket, endpoint: options.endpoint) { throw DSError(why) }
        let r = try await send(request("GET", key: "", query: [("list-type", "2"), ("prefix", prefix), ("max-keys", "1")]))
        guard r.ok else { throw fail("listing", r) }
        if !prefix.isEmpty {
            let page = S3Storage.parseList(r.text)
            if page.files.isEmpty && page.dirs.isEmpty {
                throw DSError("The folder /\(prefix.dropLast()) isn't in the bucket “\(options.bucket)”. Data Syncer never creates the destination folder itself — use “Make this folder” in the destination's settings, or create it in the S3 console, then try again.")
            }
        }
    }

    /// Creates the destination folder (the user's explicit choice in the editor).
    public func makeRootFolder() async throws {
        guard !prefix.isEmpty else { return }
        let r = try await send(request("PUT", key: prefix, body: Data()))
        guard r.ok else { throw fail("making the folder", r) }
    }

    public func exists(_ path: RelPath) async throws -> Bool { try await stat(path) != nil }

    public func stat(_ path: RelPath) async throws -> FileMeta? {
        if path.isEmpty { return FileMeta(isDirectory: true) }
        let r = try await send(request("HEAD", key: key(path)))
        if r.ok {
            return FileMeta(size: Int64(r.header("content-length") ?? "") ?? 0, modified: S3Storage.httpDate(r.header("last-modified")))
        }
        if r.status == 404 {
            let d = try await send(request("GET", key: "", query: [("list-type", "2"), ("prefix", key(path) + "/"), ("max-keys", "1")]))
            if d.ok, S3Storage.parseList(d.text).keyCount > 0 { return FileMeta(isDirectory: true) }
            return nil
        }
        throw fail("looking at \(path)", r)
    }

    public func list(_ dir: RelPath) async throws -> [Entry] {
        let base = dir.isEmpty ? prefix : key(dir) + "/"
        var entries: [Entry] = []
        var token: String?
        repeat {
            var q = [("list-type", "2"), ("prefix", base), ("delimiter", "/"), ("max-keys", "1000")]
            if let t = token { q.append(("continuation-token", t)) }
            let r = try await send(request("GET", key: "", query: q))
            guard r.ok else { throw fail("listing \(dir)", r) }
            let page = S3Storage.parseList(r.text)
            for d in page.dirs { entries.append(Entry(name: String(d.dropFirst(base.count).dropLast()), meta: FileMeta(isDirectory: true))) }
            for f in page.files where f.key != base { entries.append(Entry(name: String(f.key.dropFirst(base.count)), meta: FileMeta(size: f.size, modified: f.modified))) }
            token = page.next
        } while token != nil
        return entries
    }

    /// One listing (no delimiter) for the whole tree; folders come from "x/" markers and from file paths.
    public func walk(_ dir: RelPath) async throws -> Snapshot {
        let base = dir.isEmpty ? prefix : key(dir) + "/"
        var out: Snapshot = [:]
        var token: String?
        repeat {
            var q = [("list-type", "2"), ("prefix", base), ("max-keys", "1000")]
            if let t = token { q.append(("continuation-token", t)) }
            let r = try await send(request("GET", key: "", query: q))
            guard r.ok else { throw fail("listing", r) }
            let page = S3Storage.parseList(r.text)
            for f in page.files {
                let rel = String(f.key.dropFirst(base.count))
                if rel.isEmpty { continue }
                if dir.isEmpty, rel == Records.folderName || rel.hasPrefix(Records.folderName + "/") { continue }
                if rel.hasSuffix("/") { out[String(rel.dropLast())] = FileMeta(isDirectory: true); continue }
                out[rel] = FileMeta(size: f.size, modified: f.modified)
                var parent = (rel as NSString).deletingLastPathComponent
                while !parent.isEmpty { if out[parent] == nil { out[parent] = FileMeta(isDirectory: true) }; parent = (parent as NSString).deletingLastPathComponent }
            }
            token = page.next
        } while token != nil
        return out
    }

    public func makeDirectory(_ path: RelPath) async throws {
        let r = try await send(request("PUT", key: key(path) + "/", body: Data()))
        guard r.ok else { throw fail("making the folder \(path)", r) }
    }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        var keys = [key(path)]
        var token: String?
        repeat {
            var q = [("list-type", "2"), ("prefix", key(path) + "/"), ("max-keys", "1000")]
            if let t = token { q.append(("continuation-token", t)) }
            let r = try await send(request("GET", key: "", query: q))
            guard r.ok else { throw fail("listing \(path)", r) }
            let page = S3Storage.parseList(r.text)
            keys += page.files.map(\.key)
            token = page.next
        } while token != nil
        for batch in stride(from: 0, to: keys.count, by: 1000).map({ Array(keys[$0..<min($0 + 1000, keys.count)]) }) {
            let xml = "<Delete><Quiet>true</Quiet>" + batch.map { "<Object><Key>\(S3Storage.xmlEscape($0))</Key></Object>" }.joined() + "</Delete>"
            let body = Data(xml.utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let r = try await send(request("POST", key: "", query: [("delete", "")], body: body, headers: ["Content-MD5": md5, "Content-Type": "application/xml"]))
            guard r.ok else { throw fail("deleting \(path)", r) }
            // quiet mode answers 200 even when some keys could not be deleted
            if let first = S3Storage.blocks(r.text, "Error").first {
                let k = S3Storage.xmlValue(first, "Key") ?? "", code = S3Storage.xmlValue(first, "Code") ?? "", msg = S3Storage.xmlValue(first, "Message") ?? ""
                throw DSError("Amazon S3 would not delete \(S3Storage.xmlUnescape(k)) (\(code) \(msg)). Check the key's permissions on this bucket, and whether the bucket has Object Lock or a retention policy.")
            }
        }
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let headers = ["x-amz-meta-mtime": String(meta.modified), "x-amz-meta-mode": String(meta.permissions ?? 0o644), "Content-Type": "application/octet-stream"]
        if meta.size <= Int64(S3Storage.partSize) {
            let data = try Data(contentsOf: localURL)
            let r = try await HTTP.upload(request("PUT", key: key(path), headers: headers, unsigned: true), data: data, service: "Amazon S3")
            guard r.ok else { throw fail("writing \(path)", r) }
            progress?(Int64(data.count))
            return
        }
        // multipart
        let start = try await send(request("POST", key: key(path), query: [("uploads", "")], body: Data(), headers: headers))
        guard start.ok, let uploadId = S3Storage.xmlValue(start.text, "UploadId") else { throw fail("starting the upload of \(path)", start) }
        var etags: [(Int, String)] = []
        var offset: Int64 = 0, part = 1
        do {
            while offset < meta.size {
                try Task.checkCancellation()
                let chunk = try HTTP.chunk(of: localURL, offset: offset, length: S3Storage.partSize)
                if chunk.isEmpty { break }
                let r = try await HTTP.upload(request("PUT", key: key(path), query: [("partNumber", String(part)), ("uploadId", uploadId)], unsigned: true), data: chunk, service: "Amazon S3")
                guard r.ok, let etag = r.header("etag") else { throw fail("uploading part \(part) of \(path)", r) }
                etags.append((part, etag))
                offset += Int64(chunk.count); part += 1
                progress?(offset)
            }
            let xml = "<CompleteMultipartUpload>" + etags.map { "<Part><PartNumber>\($0.0)</PartNumber><ETag>\(S3Storage.xmlEscape($0.1))</ETag></Part>" }.joined() + "</CompleteMultipartUpload>"
            let done = try await send(request("POST", key: key(path), query: [("uploadId", uploadId)], body: Data(xml.utf8), headers: ["Content-Type": "application/xml"]))
            guard done.ok, !done.text.contains("<Error>") else { throw fail("finishing the upload of \(path)", done) }
        } catch {
            // abort the multipart upload (otherwise its parts are kept, and billed) — even after a cancel
            await HTTP.sendIgnoringCancellation(request("DELETE", key: key(path), query: [("uploadId", uploadId)]), service: "Amazon S3")
            throw error
        }
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        let r = try await HTTP.download(request("GET", key: key(path)), to: localURL, service: "Amazon S3")
        guard r.ok else { throw fail("reading \(path)", r) }
        try LocalStorage.apply(meta, to: localURL)
    }

    public func readData(_ path: RelPath) async throws -> Data {
        let r = try await send(request("GET", key: key(path)))
        guard r.ok else { throw fail("reading \(path)", r) }
        return r.data
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        let r = try await send(request("PUT", key: key(path), body: data, headers: ["Content-Type": "application/octet-stream"]))
        guard r.ok else { throw fail("writing \(path)", r) }
    }

    public func freeSpace() async throws -> Int64? { nil }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        throw DSError("Amazon S3 can't hold links, so this link was skipped (it points to \(target)).")
    }

    // MARK: parsing

    struct ListPage { var files: [(key: String, size: Int64, modified: TimeInterval)] = []; var dirs: [String] = []; var next: String?; var keyCount = 0 }

    static func parseList(_ xml: String) -> ListPage {
        var page = ListPage()
        for block in blocks(xml, "Contents") {
            guard let k = xmlValue(block, "Key") else { continue }
            page.files.append((xmlUnescape(k), Int64(xmlValue(block, "Size") ?? "") ?? 0, HTTP.date(xmlValue(block, "LastModified"))))
        }
        for block in blocks(xml, "CommonPrefixes") { if let p = xmlValue(block, "Prefix") { page.dirs.append(xmlUnescape(p)) } }
        page.next = xmlValue(xml, "NextContinuationToken").map(xmlUnescape)
        page.keyCount = Int(xmlValue(xml, "KeyCount") ?? "") ?? (page.files.count + page.dirs.count)
        return page
    }

    static func blocks(_ xml: String, _ tag: String) -> [String] {
        var out: [String] = []
        var rest = Substring(xml)
        while let open = rest.range(of: "<\(tag)>"), let close = rest.range(of: "</\(tag)>", range: open.upperBound..<rest.endIndex) {
            out.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return out
    }

    static func xmlValue(_ xml: String, _ tag: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"), let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func xmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semi) <= 10 else { out += "&"; rest = rest.dropFirst(); continue }
            let entity = rest[rest.index(after: rest.startIndex)..<semi]
            switch entity {
            case "lt": out += "<"; case "gt": out += ">"; case "quot": out += "\""; case "apos": out += "'"; case "amp": out += "&"
            default:
                // numeric: &#13; or &#x0D; (keys with control characters come back this way)
                if entity.hasPrefix("#x"), let v = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { out += String(Character(u)) }
                else if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) { out += String(Character(u)) }
                else { out += "&" + entity + ";" }
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    /// "Wed, 12 Oct 2026 07:28:00 GMT"
    static func httpDate(_ s: String?) -> TimeInterval {
        guard let s else { return 0 }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)?.timeIntervalSince1970 ?? 0
    }
}

import CryptoKit
