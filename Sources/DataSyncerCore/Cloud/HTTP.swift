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

    /// Sends a request and returns what came back (any status; the caller decides what a 404 means).
    public static func send(_ request: URLRequest, service: String) async throws -> HTTPResponse {
        do {
            let (data, r) = try await session.data(for: request)
            return make(data, r)
        } catch { throw explain(error, service) }
    }

    /// Sends a request whose body is `data` (an upload chunk).
    public static func upload(_ request: URLRequest, data: Data, service: String) async throws -> HTTPResponse {
        do {
            let (body, r) = try await session.upload(for: request, from: data)
            return make(body, r)
        } catch { throw explain(error, service) }
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
        } catch let e as DSError { throw e } catch { throw explain(error, service) }
    }

    private static func make(_ data: Data, _ r: URLResponse) -> HTTPResponse {
        let h = r as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in h?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPResponse(status: h?.statusCode ?? 0, headers: headers, data: data)
    }

    static func explain(_ error: Error, _ service: String) -> DSError {
        let e = error as NSError
        switch (e.domain, e.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return DSError("\(service) can't be reached — this Mac seems to be offline.")
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            return DSError("\(service) can't be found. Check the address, or that you're on the right network.")
        case (NSURLErrorDomain, NSURLErrorTimedOut): return DSError("\(service) isn't answering (timed out).")
        case (NSURLErrorDomain, NSURLErrorCancelled): return DSError("cancelled")
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
