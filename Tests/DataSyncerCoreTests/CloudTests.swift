// The cloud layer without the cloud: a URLProtocol answers every request from memory. S3 gets a small fake
// bucket (enough for a real sync/backup/restore through the engines); the OAuth providers get canned answers for
// listing, stat, token refresh and the 401 retry; signing is checked against Amazon's published example.
import Foundation
import XCTest
@testable import DataSyncerCore

// MARK: - the fake network

final class FakeHTTP: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, [String: String], Data)
    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var log: [String] = []
    static let lock = NSLock()

    static func install(_ h: @escaping Handler) {
        lock.lock(); handler = h; log = []; lock.unlock()
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeHTTP.self]
        HTTP.session = URLSession(configuration: c)
    }
    static func uninstall() { lock.lock(); handler = nil; lock.unlock(); HTTP.session = URLSession(configuration: .default) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var d = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 65536); if n <= 0 { break }; d.append(buf, count: n) }
            buf.deallocate(); stream.close(); body = d
        }
        FakeHTTP.lock.lock(); let h = FakeHTTP.handler; FakeHTTP.log.append("\(request.httpMethod ?? "") \(request.url!.path)\(request.url!.query.map { "?" + $0 } ?? "")"); FakeHTTP.lock.unlock()
        let (status, headers, data) = h?(request, body) ?? (500, [:], Data())
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Enough of S3 to sync, back up and restore against: objects by key, list-type=2 with prefix/delimiter, multipart.
final class FakeBucket: @unchecked Sendable {
    var objects: [String: (Data, Date)] = [:]
    var parts: [String: [Int: Data]] = [:]
    let lock = NSLock()
    var requireAuth = true

    func handle(_ req: URLRequest, _ body: Data?) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        if requireAuth, !(req.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("AWS4-HMAC-SHA256 Credential=AKIA") {
            return (403, [:], Data("<Error><Code>AccessDenied</Code><Message>no</Message></Error>".utf8))
        }
        let url = req.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let key = String(comps.percentEncodedPath.dropFirst("/bucket/".count)).removingPercentEncoding ?? ""
        let fmt = ISO8601DateFormatter()
        switch req.httpMethod {
        case "GET" where q["list-type"] == "2":
            let prefix = q["prefix"] ?? "", delimiter = q["delimiter"]
            var contents: [String] = [], prefixes = Set<String>()
            for k in objects.keys.sorted() where k.hasPrefix(prefix) {
                let rest = k.dropFirst(prefix.count)
                if let d = delimiter, let i = rest.firstIndex(of: Character(d)) {
                    prefixes.insert(prefix + rest[...i]); continue
                }
                let (data, date) = objects[k]!
                contents.append("<Contents><Key>\(k)</Key><Size>\(data.count)</Size><LastModified>\(fmt.string(from: date))</LastModified></Contents>")
            }
            let xml = "<ListBucketResult><KeyCount>\(contents.count + prefixes.count)</KeyCount>" + contents.joined() + prefixes.sorted().map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined() + "</ListBucketResult>"
            return (200, ["Content-Type": "application/xml"], Data(xml.utf8))
        case "HEAD":
            guard let (data, date) = objects[key] else { return (404, [:], Data()) }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return (200, ["Content-Length": String(data.count), "Last-Modified": f.string(from: date)], Data())
        case "GET":
            guard let (data, _) = objects[key] else { return (404, [:], Data("<Error><Code>NoSuchKey</Code></Error>".utf8)) }
            return (200, [:], data)
        case "PUT" where q["partNumber"] != nil:
            parts[q["uploadId"]!, default: [:]][Int(q["partNumber"]!)!] = body ?? Data()
            return (200, ["ETag": "\"p\(q["partNumber"]!)\""], Data())
        case "PUT":
            objects[key] = (body ?? Data(), Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
            return (200, ["ETag": "\"x\""], Data())
        case "POST" where q["uploads"] != nil:
            let id = UUID().uuidString; parts[id] = [:]
            return (200, [:], Data("<InitiateMultipartUploadResult><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>".utf8))
        case "POST" where q["uploadId"] != nil:
            let ps = parts.removeValue(forKey: q["uploadId"]!) ?? [:]
            objects[key] = (ps.keys.sorted().reduce(Data()) { $0 + ps[$1]! }, Date())
            return (200, [:], Data("<CompleteMultipartUploadResult><Key>\(key)</Key></CompleteMultipartUploadResult>".utf8))
        case "POST" where q["delete"] != nil:
            let xml = String(decoding: body ?? Data(), as: UTF8.self)
            for k in S3Storage.blocks(xml, "Object").compactMap({ S3Storage.xmlValue($0, "Key") }) { objects.removeValue(forKey: S3Storage.xmlUnescape(k)) }
            return (200, [:], Data("<DeleteResult/>".utf8))
        case "DELETE":
            objects.removeValue(forKey: key); return (204, [:], Data())
        default:
            return (400, [:], Data())
        }
    }
}

final class S3Tests: XCTestCase {
    override func tearDown() { FakeHTTP.uninstall() }

    /// Amazon's worked example: GET /test.txt with a Range header, 24 May 2013.
    func testSignatureMatchesAmazonsExample() {
        let o = S3Options(bucket: "examplebucket", region: "us-east-1", accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        req.httpMethod = "GET"
        req.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        S3Storage.sign(&req, options: o, payloadHash: S3Storage.emptyHash, date: f.date(from: "20130524T000000Z")!)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testListParsingAndEncoding() {
        let xml = "<ListBucketResult><KeyCount>3</KeyCount><Contents><Key>w/a b.txt</Key><Size>12</Size><LastModified>2026-10-13T21:04:05.000Z</LastModified></Contents><Contents><Key>w/x&amp;y</Key><Size>1</Size><LastModified>2026-10-13T21:04:06Z</LastModified></Contents><CommonPrefixes><Prefix>w/sub/</Prefix></CommonPrefixes><NextContinuationToken>tok==</NextContinuationToken></ListBucketResult>"
        let page = S3Storage.parseList(xml)
        XCTAssertEqual(page.files.map(\.key), ["w/a b.txt", "w/x&y"])
        XCTAssertEqual(page.files[0].modified, 1_791_925_445)
        XCTAssertEqual(page.dirs, ["w/sub/"])
        XCTAssertEqual(page.next, "tok==")
        XCTAssertEqual(S3Storage.uriEncode("a b/c+d~e"), "a%20b%2Fc%2Bd~e")
        let st = S3Storage(options: S3Options(bucket: "b", region: "eu-west-1", accessKey: "k", secretKey: "s"), folder: "/work/")
        XCTAssertEqual(st.url(key: "work/a b.txt").absoluteString, "https://b.s3.eu-west-1.amazonaws.com/work/a%20b.txt")
        let mini = S3Storage(options: S3Options(bucket: "b", region: "us-east-1", endpoint: "https://minio.local:9000/", accessKey: "k", secretKey: "s"), folder: "")
        XCTAssertEqual(mini.url(key: "x", query: [("uploads", "")]).absoluteString, "https://minio.local:9000/b/x?uploads=")
    }

    func testRoundTripThroughTheEngines() async throws {
        let bucket = FakeBucket()
        bucket.objects["work/"] = (Data(), Date())      // the folders exist (the user made them)
        bucket.objects["backups/"] = (Data(), Date())
        FakeHTTP.install { req, body in bucket.handle(req, body) }
        let s = Scratch(); let src = s.dir("src")
        makeTree(src, ["a.txt": "A", "docs/b.txt": "B", "docs/link": "@b.txt"])
        let big = src.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: S3Storage.partSize * 2 + 10).write(to: big)
        let accounts = CloudAccountStore(url: s.root.appendingPathComponent("accounts.json"))
        let account = CloudAccount(provider: .s3, label: "AKIATEST", clientId: "AKIATEST")
        try accounts.save([account])
        let secrets = MemorySecrets()
        try CloudSecret(s3SecretKey: "secret").save(account.id, to: secrets)
        let factory = DefaultStorageFactory(secrets: secrets, accounts: accounts)
        let kind = DestinationKind.s3(account: account.id.uuidString, bucket: "bucket", region: "us-east-1", endpoint: "https://s3.fake")
        var job = Job(name: "Cloud", sourcePath: src.path)
        job.destinations = [
            Destination(name: "s3 sync", kind: kind, folder: "work", mode: .sync(deleteExtras: true)),
            Destination(name: "s3 backups", kind: kind, folder: "backups", mode: .fullOnly, backupTitle: "T"),
        ]
        let check = await Preflight.check(job, job.destinations[0], factory: factory)
        XCTAssertTrue(check.ok, check.items.map(\.detail).joined(separator: "; "))
        let clock = FixedClock(); let r = JobRunner(factory: factory); r.now = { clock.date }
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .finishedWithProblems)   // the link can't be kept
        XCTAssertEqual(report.results[0].copied, 3)
        XCTAssertEqual(report.results[0].skipped, 1)
        XCTAssertTrue(report.results[0].problems[0].contains("can't hold links"))
        XCTAssertEqual(report.results[1].status, .finishedWithProblems)
        XCTAssertEqual(bucket.objects["work/big.bin"]?.0.count, S3Storage.partSize * 2 + 10)   // multipart
        XCTAssertNotNil(bucket.objects["work/docs/"])
        XCTAssertNotNil(bucket.objects["work/.datasyncer/sync-state.json"])
        XCTAssertTrue(bucket.objects.keys.contains { $0.hasPrefix("backups/2026_10_14_") && $0.hasSuffix("_Full_T/.datasyncer/manifest.json") })
        // a second sync: nothing to copy except the link that keeps getting skipped
        let again = await r.run(job, choices: [:]) { _ in }
        XCTAssertEqual(again.results[0].copied, 0)
        XCTAssertEqual(again.results[0].unchanged, 3)
        // restore the full from S3
        let storage = try await factory.storage(for: job.destinations[1])
        let catalog = try await BackupCatalog.load(from: storage)
        XCTAssertEqual(catalog.entries.count, 1)
        let target = s.dir("restored")
        let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: target, removeDeleted: true) { _ in }
        XCTAssertEqual(result.status, .finishedWithProblems)   // the link S3 could never hold is reported as missing
        XCTAssertEqual(result.problems, ["docs/link: the backups never managed to copy this file, so it is not in the result"])
        var tree = readTree(target); tree.removeValue(forKey: "big.bin")
        XCTAssertEqual(tree, ["a.txt": "A", "docs": "<dir>", "docs/b.txt": "B"])
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("big.bin")).count, S3Storage.partSize * 2 + 10)
        // deleting a backup removes every key under it
        try await RestoreEngine.delete(catalog.entries[0].folder, from: storage, catalog: catalog)
        XCTAssertFalse(bucket.objects.keys.contains { $0.contains("_Full_T") })
    }

    func testDeleteErrorsNumericEntitiesAndValidation() async throws {
        let bucket = FakeBucket()
        bucket.objects["w/"] = (Data(), Date()); bucket.objects["w/locked.txt"] = (Data(), Date())
        FakeHTTP.install { req, body in
            if req.httpMethod == "POST", req.url!.query?.contains("delete") == true {
                return (200, [:], Data("<DeleteResult><Error><Key>w/locked.txt</Key><Code>AccessDenied</Code><Message>Object Lock</Message></Error></DeleteResult>".utf8))
            }
            return bucket.handle(req, body)
        }
        let st = S3Storage(options: S3Options(bucket: "bucket", region: "us-east-1", endpoint: "https://s3.fake", accessKey: "AKIAX", secretKey: "s"), folder: "w")
        do { try await st.remove("locked.txt"); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("would not delete w/locked.txt"), e.message) }
        do { try await st.remove(""); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("Refusing")) }
        XCTAssertEqual(S3Storage.xmlUnescape("a&#13;b&#x41;c&amp;&lt;&unknown;"), "a\rbAc&<&unknown;")
        XCTAssertNil(S3Storage.validate(bucket: "b", endpoint: "https://minio.local:9000"))
        XCTAssertNotNil(S3Storage.validate(bucket: "b", endpoint: "minio.local:9000"))
        XCTAssertNotNil(S3Storage.validate(bucket: "", endpoint: nil))
        let dotted = S3Storage(options: S3Options(bucket: "my.photos", region: "eu-west-1", accessKey: "k", secretKey: "s"), folder: "")
        XCTAssertEqual(dotted.url(key: "x").absoluteString, "https://s3.eu-west-1.amazonaws.com/my.photos/x")
    }

    func testMissingFolderAndBadKeysAreSentences() async throws {
        let bucket = FakeBucket()
        FakeHTTP.install { req, body in bucket.handle(req, body) }
        let st = S3Storage(options: S3Options(bucket: "bucket", region: "us-east-1", endpoint: "https://s3.fake", accessKey: "AKIAX", secretKey: "s"), folder: "nothere")
        do { try await st.checkReachable(); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("isn't in the bucket"), e.message) }
        try await st.makeRootFolder()
        try await st.checkReachable()
        let bad = S3Storage(options: S3Options(bucket: "bucket", region: "us-east-1", endpoint: "https://s3.fake", accessKey: "WRONG", secretKey: "s"), folder: "")
        do { try await bad.checkReachable(); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("Check the access key"), e.message) }
    }
}

// MARK: - the OAuth services

final class OAuthProviderTests: XCTestCase {
    override func tearDown() { FakeHTTP.uninstall() }

    func provider(_ p: CloudProvider, expired: Bool = false, saved: Locked<[OAuthTokens]>? = nil) -> TokenProvider {
        TokenProvider(config: p.oauthConfig(clientId: "cid", clientSecret: p == .googleDrive ? "sec" : nil)!,
                      tokens: OAuthTokens(accessToken: "old", refreshToken: "r1", expiresAt: expired ? .distantPast : Date().addingTimeInterval(3600))) { t in saved?.with { $0.append(t) } }
    }

    func testRefreshWhenExpiredAndSaveBack() async throws {
        let saved = Locked<[OAuthTokens]>([])
        FakeHTTP.install { req, body in
            if req.url!.host == "oauth2.googleapis.com" {
                let form = String(decoding: body ?? Data(), as: UTF8.self)
                XCTAssertTrue(form.contains("grant_type=refresh_token") && form.contains("refresh_token=r1") && form.contains("client_secret=sec"))
                return (200, ["Content-Type": "application/json"], Data(#"{"access_token":"new","expires_in":3599}"#.utf8))
            }
            return (404, [:], Data())
        }
        let tp = provider(.googleDrive, expired: true, saved: saved)
        let token = try await tp.accessToken()
        XCTAssertEqual(token, "new")
        XCTAssertEqual(saved.with { $0 }.first?.refreshToken, "r1")   // kept when the service doesn't send a new one
        let again = try await tp.accessToken()
        XCTAssertEqual(again, "new"); XCTAssertEqual(saved.with { $0.count }, 1)
    }

    func testRefreshFailureIsASentence() async throws {
        FakeHTTP.install { _, _ in (400, ["Content-Type": "application/json"], Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)) }
        do { _ = try await provider(.dropbox, expired: true).accessToken(); XCTFail() }
        catch let e as DSError { XCTAssertTrue(e.message.contains("Sign in again"), e.message) }
    }

    func testGoogleDriveListingStatAndFolderLookup() async throws {
        FakeHTTP.install { req, _ in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "q" }?.value ?? ""
            if req.url!.path == "/drive/v3/files" {
                if q == "trashed = false" {
                    XCTAssertTrue(req.url!.query!.contains("q=trashed%20%3D%20false"))
                    return (200, [:], Data(#"{"files":[{"id":"F1","name":"Data Syncer","mimeType":"application/vnd.google-apps.folder","parents":["root"]},{"id":"F2","name":"Work","mimeType":"application/vnd.google-apps.folder","parents":["F1"]},{"id":"A","name":"a.txt","mimeType":"text/plain","size":"12","modifiedTime":"2026-10-13T21:04:05.000Z","parents":["F2"]},{"id":"A-old","name":"a.txt","mimeType":"text/plain","size":"5","modifiedTime":"2026-10-01T00:00:00Z","parents":["F2"]},{"id":"S","name":"sub","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2026-10-13T21:00:00Z","parents":["F2"]},{"id":"P","name":"c++.txt","mimeType":"text/plain","size":"1","modifiedTime":"2026-10-13T21:00:00Z","parents":["S"]},{"id":"X","name":"elsewhere.txt","mimeType":"text/plain","size":"1","parents":["root"]}]}"#.utf8))
                }
                if q.contains("name = 'c++.txt'") {
                    XCTAssertTrue(req.url!.query!.contains("c%2B%2B.txt"), "a + must be sent encoded")
                    return (200, [:], Data(#"{"files":[{"id":"P","mimeType":"text/plain"}]}"#.utf8))
                }
                if q.contains("'root' in parents and name = 'Data Syncer'") { return (200, [:], Data(#"{"files":[{"id":"F1","mimeType":"application/vnd.google-apps.folder"}]}"#.utf8)) }
                if q.contains("'F1' in parents and name = 'Work'") { return (200, [:], Data(#"{"files":[{"id":"F2","mimeType":"application/vnd.google-apps.folder"}]}"#.utf8)) }
                if q.contains("name = 'missing'") { return (200, [:], Data(#"{"files":[]}"#.utf8)) }
                if q.contains("'F2' in parents and name = 'a.txt'") { return (200, [:], Data(#"{"files":[{"id":"A-old","mimeType":"text/plain","modifiedTime":"2026-10-01T00:00:00Z"},{"id":"A","mimeType":"text/plain","modifiedTime":"2026-10-13T21:04:05.000Z"}]}"#.utf8)) }
                if q.contains("'F2' in parents and trashed") { return (200, [:], Data(#"{"files":[{"id":"A","name":"a.txt","mimeType":"text/plain","size":"12","modifiedTime":"2026-10-13T21:04:05.000Z"},{"id":"A-old","name":"a.txt","mimeType":"text/plain","size":"5","modifiedTime":"2026-10-01T00:00:00Z"},{"id":"S","name":"sub","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2026-10-13T21:00:00Z"}]}"#.utf8)) }
                if q.contains("'S' in parents and trashed") { return (200, [:], Data(#"{"files":[]}"#.utf8)) }
            }
            if req.url!.path == "/drive/v3/files/A" { return (200, [:], Data(#"{"id":"A","mimeType":"text/plain","size":"12","modifiedTime":"2026-10-13T21:04:05.000Z"}"#.utf8)) }
            return (404, [:], Data(#"{"error":{"message":"nope"}}"#.utf8))
        }
        let st = GoogleDriveStorage(tokens: provider(.googleDrive), folder: "Data Syncer/Work", accountLabel: "me@gmail.com")
        try await st.checkReachable()
        let walked = try await st.walk()
        XCTAssertEqual(walked, ["a.txt": FileMeta(size: 12, modified: 1_791_925_445), "sub": FileMeta(isDirectory: true, modified: 1_791_925_200), "sub/c++.txt": FileMeta(size: 1, modified: 1_791_925_200)])
        let listed = try await st.list("")
        XCTAssertEqual(listed.count, 2, "a duplicate name is listed once, the newest")
        let a = try await st.stat("a.txt"); XCTAssertEqual(a?.size, 12)   // the newest of the two "a.txt"
        let plus = try await st.exists("sub/c++.txt"); XCTAssertTrue(plus)
        let missing = try await st.stat("missing"); XCTAssertNil(missing)
        let other = GoogleDriveStorage(tokens: provider(.googleDrive), folder: "Data Syncer/missing", accountLabel: "x")
        do { try await other.checkReachable(); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("Make this folder"), e.message) }
    }

    func testDropboxListingAnd401Retry() async throws {
        let calls = Locked(0)
        FakeHTTP.install { req, body in
            let n = calls.with { $0 += 1; return $0 }
            if req.url!.host == "api.dropboxapi.com", req.url!.path == "/oauth2/token" { return (200, [:], Data(#"{"access_token":"fresh","expires_in":100}"#.utf8)) }
            if n == 1 { return (401, [:], Data(#"{"error_summary":"expired_access_token/"}"#.utf8)) }
            switch req.url!.path {
            case "/2/files/get_metadata":
                let path = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])?["path"] as? String
                if path == "/Work/nope" { return (409, [:], Data(#"{"error_summary":"path/not_found/..."}"#.utf8)) }
                return (200, [:], Data(#"{".tag":"folder","name":"Work","path_display":"/Work"}"#.utf8))
            case "/2/files/list_folder":
                return (200, [:], Data(#"{"entries":[{".tag":"file","name":"a.txt","path_display":"/Work/a.txt","size":12,"client_modified":"2026-10-13T21:04:05Z"},{".tag":"folder","name":"sub","path_display":"/Work/sub"},{".tag":"file","name":"b","path_display":"/Work/sub/b","size":1,"client_modified":"2026-10-13T21:04:06Z"}],"cursor":"c","has_more":false}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        let st = DropboxStorage(tokens: provider(.dropbox), folder: "/Work/", accountLabel: "me")
        try await st.checkReachable()   // the first call gets a 401, the token refreshes, the retry succeeds
        let walked = try await st.walk()
        XCTAssertEqual(Set(walked.keys), ["a.txt", "sub", "sub/b"])
        XCTAssertEqual(walked["a.txt"]?.modified, 1_791_925_445)
        let nope = try await st.stat("nope"); XCTAssertNil(nope)
        XCTAssertEqual(DropboxStorage.stamp(1_791_925_445.7), "2026-10-13T21:04:05Z")
    }

    func testOneDriveListingAndPaths() async throws {
        FakeHTTP.install { req, _ in
            let path = req.url!.path
            if path == "/v1.0/me/drive/root:/Backups/Work" { return (200, [:], Data(#"{"id":"1","folder":{"childCount":2}}"#.utf8)) }
            if path == "/v1.0/me/drive/root:/Backups/Work:/children" { return (200, [:], Data(#"{"value":[{"name":"a b.txt","size":12,"file":{},"fileSystemInfo":{"lastModifiedDateTime":"2026-10-13T21:04:05.123Z"}},{"name":"sub","folder":{"childCount":0}}]}"#.utf8)) }
            if path == "/v1.0/me/drive/root:/Backups/Work:/delta" {
                // the folder itself, its children (one deleted), and a grandchild — paths as Graph gives them
                return (200, [:], Data(#"{"value":[{"name":"Work","folder":{},"parentReference":{"path":"/drive/root:/Backups"}},{"name":"a b.txt","size":12,"file":{},"fileSystemInfo":{"lastModifiedDateTime":"2026-10-13T21:04:05.123Z"},"parentReference":{"path":"/drive/root:/Backups/Work"}},{"name":"sub","folder":{"childCount":1},"parentReference":{"path":"/drive/root:/Backups/Work"}},{"name":"deep.txt","size":3,"file":{},"parentReference":{"path":"/drive/root:/Backups/Work/sub"}},{"name":"gone.txt","deleted":{},"parentReference":{"path":"/drive/root:/Backups/Work"}},{"name":"other.txt","size":1,"file":{},"parentReference":{"path":"/drive/root:/Backups/Workshop"}}],"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/drive/root/delta?token=x"}"#.utf8))
            }
            if path == "/v1.0/me/drive/root:/Backups/Work/sub:/children" { return (200, [:], Data(#"{"value":[]}"#.utf8)) }
            if path == "/v1.0/me/drive/root:/Backups/Work/a b.txt" { return (200, [:], Data(#"{"name":"a b.txt","size":12,"file":{},"fileSystemInfo":{"lastModifiedDateTime":"2026-10-13T21:04:05.123Z"}}"#.utf8)) }
            return (404, [:], Data(#"{"error":{"message":"itemNotFound"}}"#.utf8))
        }
        let st = OneDriveStorage(tokens: provider(.oneDrive), folder: "/Backups/Work/", accountLabel: "me@outlook.com")
        try await st.checkReachable()
        let walked = try await st.walk()
        XCTAssertEqual(Set(walked.keys), ["a b.txt", "sub", "sub/deep.txt"], "the folder itself, deleted items and a sibling folder's files are left out")
        XCTAssertEqual(walked["a b.txt"]?.modified ?? 0, 1_791_925_445.123, accuracy: 0.001)
        let listed = try await st.list(""); XCTAssertEqual(listed.count, 2)
        let s = try await st.stat("a b.txt"); XCTAssertEqual(s?.size, 12)
        let gone = try await st.stat("zzz"); XCTAssertNil(gone)
        let other = OneDriveStorage(tokens: provider(.oneDrive), folder: "Elsewhere", accountLabel: "me")
        do { try await other.checkReachable(); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("isn't in this OneDrive"), e.message) }
    }

    func testDropboxHeaderIsASCII() {
        let h = DropboxStorage.headerJSON(["path": "/Work/Résumé 日本 🙂.pdf", "mode": "overwrite"])
        XCTAssertTrue(h.allSatisfy { $0.isASCII }, h)
        XCTAssertTrue(h.contains("\\u00E9") && h.contains("\\u65E5") && h.contains("\\uD83D\\uDE42"), h)
        let back = try! JSONSerialization.jsonObject(with: Data(h.utf8)) as! [String: String]
        XCTAssertEqual(back["path"], "/Work/Résumé 日本 🙂.pdf")
    }

    func testHTTPRetriesWhenThrottledAndMapsCancellation() async throws {
        let calls = Locked(0)
        FakeHTTP.install { _, _ in
            let n = calls.with { $0 += 1; return $0 }
            return n < 3 ? (429, ["Retry-After": "0"], Data()) : (200, [:], Data("ok".utf8))
        }
        let r = try await HTTP.send(URLRequest(url: URL(string: "https://x.test/")!), service: "x")
        XCTAssertEqual(r.status, 200); XCTAssertEqual(calls.value, 3)
        XCTAssertNil(HTTP.retryDelay(HTTPResponse(status: 404, headers: [:], data: Data()), attempt: 0))
        XCTAssertEqual(HTTP.retryDelay(HTTPResponse(status: 503, headers: ["retry-after": "7"], data: Data()), attempt: 1), 7)
        XCTAssertNil(HTTP.retryDelay(HTTPResponse(status: 503, headers: [:], data: Data()), attempt: 3))
        let cancelled = HTTP.explain(URLError(.cancelled), "x")
        XCTAssertTrue(cancelled is CancellationError)
    }

    func testCloudAccountsAndSecrets() throws {
        let s = Scratch()
        let store = CloudAccountStore(url: s.root.appendingPathComponent("accounts.json"))
        let a = CloudAccount(provider: .dropbox, label: "me@x.com", clientId: "appkey", createdAt: Date(timeIntervalSince1970: 1_792_000_000.5))
        try store.save([a])
        XCTAssertEqual(try store.account(a.id.uuidString), a)
        XCTAssertNil(try store.account("nope"))
        let secrets = MemorySecrets()
        let secret = CloudSecret(tokens: OAuthTokens(accessToken: "t", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_792_000_000)))
        try secret.save(a.id, to: secrets)
        XCTAssertEqual(try CloudSecret.load(a.id, from: secrets), secret)
        XCTAssertEqual(SecretAccount.cloudId(try secrets.accounts()[0]), a.id)
        let (v, c) = OAuth.pkce()
        XCTAssertEqual(c, OAuth.base64url(Hashing.sha256(Data(v.utf8))))
        XCTAssertFalse(c.contains("=") || c.contains("+") || c.contains("/"))
    }
}
