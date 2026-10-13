// Talking to the cloud services' web APIs: one place that sends requests, uploads and downloads files, and turns
// network trouble into sentences. Tests swap the session for one that answers from memory.
import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data
    public var ok: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: data, as: UTF8.self) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public func json() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
}

public enum HTTP {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 24 * 3600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    /// The session every request goes through; tests give it a URLProtocol that answers from memory.
    public static var session: URLSession {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); _session = newValue; lock.unlock() }
    }

    /// Statuses worth a second try, and how long to wait: the service's Retry-After, else 1 s, 2 s, 4 s.
    static func retryDelay(_ r: HTTPResponse, attempt: Int) -> TimeInterval? {
        guard attempt < 3, [429, 500, 502, 503, 504].contains(r.status) else { return nil }
        if let h = r.header("retry-after"), let secs = TimeInterval(h) { return min(secs, 60) }
        return TimeInterval(1 << attempt)
    }

    /// Sends a request and returns what came back (any status; the caller decides what a 404 means).
    /// A throttled or briefly failing service (429, 5xx) is retried a few times with a pause.
    public static func send(_ request: URLRequest, service: String) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let r: HTTPResponse
            do {
                let (data, resp) = try await session.data(for: request)
                r = make(data, resp)
            } catch { throw explain(error, service) }
            guard let delay = retryDelay(r, attempt: attempt) else { return r }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    /// Sends a request whose body is `data` (an upload chunk), with the same retries.
    public static func upload(_ request: URLRequest, data: Data, service: String) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let r: HTTPResponse
            do {
                let (body, resp) = try await session.upload(for: request, from: data)
                r = make(body, resp)
            } catch { throw explain(error, service) }
            guard let delay = retryDelay(r, attempt: attempt) else { return r }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    /// For cleanup after a cancel (aborting an upload, removing a half-made folder): runs outside the cancelled
    /// task so it actually happens. Errors are ignored — it is best effort.
    public static func sendIgnoringCancellation(_ request: URLRequest, service: String) async {
        _ = await Task.detached { try? await send(request, service: service) }.value
    }

    /// Downloads the response body straight to a local file.
    public static func download(_ request: URLRequest, to file: URL, service: String) async throws -> HTTPResponse {
        do {
            let (tmp, r) = try await session.download(for: request)
            let resp = make(Data(), r)
            if resp.ok {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tmp, to: file)
            } else {
                var r2 = resp
                r2.data = (try? Data(contentsOf: tmp)) ?? Data()
                try? FileManager.default.removeItem(at: tmp)
                return r2
            }
            return resp
        } catch let e as DSError { throw e } catch is CancellationError { throw CancellationError() } catch { throw explain(error, service) }
    }

    private static func make(_ data: Data, _ r: URLResponse) -> HTTPResponse {
        let h = r as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in h?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPResponse(status: h?.statusCode ?? 0, headers: headers, data: data)
    }

    /// Network trouble as a sentence; a cancelled request is a cancellation, not a failure.
    static func explain(_ error: Error, _ service: String) -> Error {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled || Task.isCancelled { return CancellationError() }
        switch (e.domain, e.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return DSError("\(service) can't be reached — this Mac seems to be offline.")
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            return DSError("\(service) can't be found. Check the address, or that you're on the right network.")
        case (NSURLErrorDomain, NSURLErrorTimedOut): return DSError("\(service) isn't answering (timed out).")
        default: return DSError("\(service): \(e.localizedDescription)")
        }
    }

    /// A chunk of a local file, for uploads in parts.
    public static func chunk(of file: URL, offset: Int64, length: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        return h.readData(ofLength: length)
    }

    public static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    /// RFC 3339 dates the services use ("2026-10-13T21:04:05.123Z" or without the fraction).
    public static func date(_ s: String?) -> TimeInterval {
        guard let s else { return 0 }
        return Records.parseDate(s)?.timeIntervalSince1970 ?? 0
    }
    public static func dateString(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
