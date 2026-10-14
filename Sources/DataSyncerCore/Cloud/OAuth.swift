// Signing in to Google Drive, Dropbox and OneDrive: the browser does the sign-in, the service sends the user back
// to a tiny listener on this Mac (http://localhost:45873/callback), and the code is swapped for tokens. PKCE, so
// no secret has to be kept for Dropbox and OneDrive; Google's "desktop" clients come with one and need it.
import Foundation
import Network

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String?, expiresAt: Date) { self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt }
}

public struct OAuthConfig: Sendable {
    public var authURL: String
    public var tokenURL: String
    public var clientId: String
    public var clientSecret: String?
    public var scopes: [String]
    /// extra query items on the sign-in page (Google: access_type=offline&prompt=consent; Dropbox: token_access_type=offline)
    public var extraAuthParams: [String: String] = [:]
    public var service: String
    public init(authURL: String, tokenURL: String, clientId: String, clientSecret: String? = nil, scopes: [String], extraAuthParams: [String: String] = [:], service: String) {
        self.authURL = authURL; self.tokenURL = tokenURL; self.clientId = clientId; self.clientSecret = clientSecret; self.scopes = scopes; self.extraAuthParams = extraAuthParams; self.service = service
    }
}

public enum OAuth {
    /// The one port the services are told about (Dropbox and Microsoft want it registered in advance).
    public static let port: UInt16 = 45873
    public static var redirectURI: String { "http://localhost:\(port)/callback" }

    /// Opens the browser for the sign-in and waits for the service to send the user back. `open` shows the URL
    /// (the app opens it in the default browser); the default runs /usr/bin/open.
    public static func signIn(_ config: OAuthConfig, open: ((URL) -> Void)? = nil) async throws -> OAuthTokens {
        let (verifier, challenge) = pkce()
        let state = UUID().uuidString
        var c = URLComponents(string: config.authURL)!
        var items = [URLQueryItem(name: "client_id", value: config.clientId), URLQueryItem(name: "redirect_uri", value: redirectURI),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "state", value: state)]
        if !config.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " "))) }
        for (k, v) in config.extraAuthParams.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        let url = c.url!
        let listener = try LoopbackListener(port: port)
        defer { listener.stop() }
        if let open { open(url) } else { _ = try? await Shell.run("/usr/bin/open", [url.absoluteString]) }
        try Task.checkCancellation()   // the sheet may have closed while the browser was opening
        // closing the sheet (cancelling the task) frees the port at once instead of five minutes later
        let params = try await withTaskCancellationHandler {
            try await listener.waitForCallback(timeout: 300)
        } onCancel: {
            listener.cancel()
        }
        guard params["state"] == state else { throw DSError("The sign-in came back with the wrong state — try again.") }
        if let err = params["error"] { throw DSError("\(config.service) didn't complete the sign-in: \((params["error_description"] ?? err).replacingOccurrences(of: "+", with: " "))") }
        guard let code = params["code"] else { throw DSError("\(config.service) sent no code back — try again.") }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "client_id": config.clientId, "code_verifier": verifier]
        if let s = config.clientSecret { form["client_secret"] = s }
        return try await tokenRequest(config, form)
    }

    /// New tokens from the refresh token.
    public static func refresh(_ config: OAuthConfig, _ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let r = tokens.refreshToken else { throw DSError("\(config.service): the sign-in has expired and can't be renewed. Sign in again in Settings → Accounts.") }
        var form = ["grant_type": "refresh_token", "refresh_token": r, "client_id": config.clientId]
        if let s = config.clientSecret { form["client_secret"] = s }
        var fresh = try await tokenRequest(config, form)
        if fresh.refreshToken == nil { fresh.refreshToken = r }
        return fresh
    }

    static func tokenRequest(_ config: OAuthConfig, _ form: [String: String]) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: config.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\(HTTP.encode($0.value))" }.joined(separator: "&").utf8)
        let r = try await HTTP.send(req, service: config.service)
        guard r.ok, let json = r.json(), let access = json["access_token"] as? String else {
            let why = (r.json()?["error_description"] as? String) ?? (r.json()?["error"] as? String) ?? r.text
            if r.status == 400 || r.status == 401 {
                throw DSError("\(config.service) refused the sign-in (\(why)). Sign in again in Settings → Accounts; if it keeps happening, check the client ID in the service's developer console.")
            }
            throw DSError("\(config.service) sign-in failed: \(why)")
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: json["refresh_token"] as? String, expiresAt: Date().addingTimeInterval(expires))
    }

    static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64url(Data(bytes))
        let challenge = base64url(Data(Hashing.sha256(Data(verifier.utf8))))
        return (verifier, challenge)
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Keeps an account's tokens fresh and saved: the storages ask it for an access token before every request.
public final class TokenProvider: @unchecked Sendable {
    let config: OAuthConfig
    private var tokens: OAuthTokens
    private let save: @Sendable (OAuthTokens) -> Void
    private let lock = NSLock()
    /// one refresh at a time: two callers must not both refresh (Microsoft rotates refresh tokens)
    private var refreshing: Task<OAuthTokens, Error>?
    /// a refresh the service refused outright (the sign-in is dead): remembered so a 10,000-file run makes one
    /// token request and reports one problem, not 10,000
    private var refused: DSError?

    public init(config: OAuthConfig, tokens: OAuthTokens, save: @escaping @Sendable (OAuthTokens) -> Void) {
        self.config = config; self.tokens = tokens; self.save = save
    }

    public func accessToken() async throws -> String {
        // check-and-set under one lock: two callers must not both start a refresh
        lock.lock()
        let t = tokens
        if t.expiresAt.timeIntervalSinceNow > 60 { lock.unlock(); return t.accessToken }
        if let refused { lock.unlock(); throw refused }
        let task: Task<OAuthTokens, Error>
        let mine: Bool
        if let inFlight = refreshing { task = inFlight; mine = false }
        else { task = Task { [config] in try await OAuth.refresh(config, t) }; refreshing = task; mine = true }
        lock.unlock()
        do {
            let fresh = try await task.value
            if mine {
                lock.lock(); tokens = fresh; refreshing = nil; lock.unlock()
                save(fresh)
            }
            return fresh.accessToken
        } catch {
            if mine {
                lock.lock()
                refreshing = nil
                if let e = error as? DSError, e.message.contains("Sign in again") { refused = e }
                lock.unlock()
            }
            throw error
        }
    }

    /// After a 401: throw the saved token away so the next call refreshes.
    public func invalidate() { lock.lock(); tokens.expiresAt = .distantPast; lock.unlock() }

    /// Is the sign-in known to be dead (a refresh was refused)? The runner stops a destination on this.
    public var signInRefused: Bool { lock.lock(); defer { lock.unlock() }; return refused != nil }
}

/// Waits for the browser to come back to http://localhost:<port>/callback?code=…
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "datasyncer.oauth")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init(port: UInt16) throws {
        // loopback only: nothing on the network may reach it, and macOS's firewall has nothing to ask about
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch { throw DSError("Port \(port) on this Mac is in use, so the sign-in can't come back to Data Syncer. Quit whatever is using it and try again.") }
    }

    /// Stops waiting (the sheet was closed).
    func cancel() { finish(.failure(CancellationError())); listener.cancel() }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state {
                    if case .posix(let code) = e, code == .EADDRINUSE {
                        self?.finish(.failure(DSError("Port \(OAuth.port) on this Mac is in use, so the sign-in can't come back to Data Syncer. Quit whatever is using it (or wait a minute if a previous sign-in was just closed) and try again.")))
                    } else {
                        self?.finish(.failure(DSError("The sign-in listener failed: \(e.localizedDescription)")))
                    }
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(DSError("The sign-in wasn't completed in the browser within five minutes. Try again.")))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = text.split(separator: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            var params: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]) {
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            }
            // a browser preconnect or favicon request is not the callback
            if parts.count >= 2, !parts[1].hasPrefix("/callback") {
                conn.send(content: Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let ok = params["code"] != nil
            let body = ok
                ? "<html><body style='font-family:system-ui;padding:40px'><h2>Signed in</h2><p>You can close this window and go back to Data Syncer.</p></body></html>"
                : "<html><body style='font-family:system-ui;padding:40px'><h2>Sign-in not completed</h2><p>Go back to Data Syncer and try again.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                conn.cancel()
                if !params.isEmpty { self.finish(.success(params)) }
            })
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        guard let c else { return }
        switch result { case .success(let p): c.resume(returning: p); case .failure(let e): c.resume(throwing: e) }
    }

    func stop() { listener.cancel() }
}
