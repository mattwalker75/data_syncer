// SHA-256 and HMAC for request signing (S3) and PKCE, via CryptoKit.
import Foundation
import CryptoKit

enum Hashing {
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The SHA-256 of a whole file, read in pieces.
    static func sha256HexOfFile(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
