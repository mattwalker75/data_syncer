// Cloud accounts: the sign-ins a user adds once and then picks for any number of destinations. What isn't secret
// (which service, the label, the client ID) is in accounts.json beside the jobs; the tokens, the client secret
// and the S3 secret key are in the Keychain under "cloud:<account id>".
import Foundation

public enum CloudProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case s3, googleDrive, dropbox, oneDrive
    public var id: String { rawValue }
    public var label: String {
        switch self { case .s3: return "Amazon S3"; case .googleDrive: return "Google Drive"; case .dropbox: return "Dropbox"; case .oneDrive: return "OneDrive" }
    }
}

public struct CloudAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: CloudProvider
    /// what the user sees: the e-mail address or display name the service reported, or the S3 access key id
    public var label: String
    /// the OAuth client ID (Google, Dropbox app key, Microsoft application ID) or the S3 access key id
    public var clientId: String
    public var createdAt: Date
    public init(id: UUID = UUID(), provider: CloudProvider, label: String, clientId: String, createdAt: Date = Date()) {
        self.id = id; self.provider = provider; self.label = label; self.clientId = clientId; self.createdAt = createdAt
    }
}

/// What the Keychain holds for a cloud account (as JSON).
public struct CloudSecret: Codable, Equatable, Sendable {
    public var tokens: OAuthTokens?
    public var clientSecret: String?
    public var s3SecretKey: String?
    public init(tokens: OAuthTokens? = nil, clientSecret: String? = nil, s3SecretKey: String? = nil) { self.tokens = tokens; self.clientSecret = clientSecret; self.s3SecretKey = s3SecretKey }

    public static func load(_ accountId: UUID, from secrets: SecretStore) throws -> CloudSecret? {
        guard let s = try secrets.secret(for: SecretAccount.cloud(accountId)), let data = s.data(using: .utf8) else { return nil }
        return try? Records.decoder.decode(CloudSecret.self, from: data)
    }
    public func save(_ accountId: UUID, to secrets: SecretStore) throws {
        try secrets.set(String(decoding: try Records.encoder.encode(self), as: UTF8.self), for: SecretAccount.cloud(accountId))
    }
}

public extension SecretAccount {
    static func cloud(_ id: UUID) -> String { "cloud:\(id.uuidString)" }
    static func cloudId(_ account: String) -> UUID? {
        account.hasPrefix("cloud:") ? UUID(uuidString: String(account.dropFirst("cloud:".count))) : nil
    }
}

public struct CloudAccountsFile: Codable, Equatable, Sendable {
    public var version = 1
    public var accounts: [CloudAccount]
    public init(accounts: [CloudAccount] = []) { self.accounts = accounts }
}

public final class CloudAccountStore: @unchecked Sendable {
    public let url: URL
    public static func defaultURL() -> URL { JobStore.defaultURL().deletingLastPathComponent().appendingPathComponent("accounts.json") }
    public init(url: URL = CloudAccountStore.defaultURL()) { self.url = url }

    public func load() throws -> [CloudAccount] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try Records.decoder.decode(CloudAccountsFile.self, from: Data(contentsOf: url)).accounts }
        catch { throw DSError("The accounts file \(url.path) could not be read: \(error.localizedDescription).") }
    }

    public func save(_ accounts: [CloudAccount]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Records.encoder.encode(CloudAccountsFile(accounts: accounts)).write(to: url, options: .atomic)
    }

    public func account(_ id: String) throws -> CloudAccount? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try load().first { $0.id == uuid }
    }
}

// MARK: - the OAuth settings of each service

public extension CloudProvider {
    func oauthConfig(clientId: String, clientSecret: String?) -> OAuthConfig? {
        switch self {
        case .googleDrive:
            return OAuthConfig(authURL: "https://accounts.google.com/o/oauth2/v2/auth", tokenURL: "https://oauth2.googleapis.com/token",
                               clientId: clientId, clientSecret: clientSecret, scopes: ["https://www.googleapis.com/auth/drive.file"],
                               extraAuthParams: ["access_type": "offline", "prompt": "consent"], service: "Google Drive")
        case .dropbox:
            return OAuthConfig(authURL: "https://www.dropbox.com/oauth2/authorize", tokenURL: "https://api.dropboxapi.com/oauth2/token",
                               clientId: clientId, clientSecret: nil, scopes: [], extraAuthParams: ["token_access_type": "offline"], service: "Dropbox")
        case .oneDrive:
            return OAuthConfig(authURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                               clientId: clientId, clientSecret: nil, scopes: ["Files.ReadWrite", "offline_access", "User.Read"], service: "OneDrive")
        case .s3: return nil
        }
    }
}
