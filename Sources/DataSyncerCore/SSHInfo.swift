// What this Mac already has for SSH — the keys in ~/.ssh, the hosts in ~/.ssh/config, what the agent holds and
// how many servers known_hosts remembers — so the Accounts settings can show it and the destination editor
// can offer the keys. Read only; Data Syncer never changes ~/.ssh.
import Foundation

public struct SSHKey: Equatable, Identifiable, Sendable {
    public var id: String { path }
    /// the private key's path
    public var path: String
    public var hasPublicHalf: Bool
    /// "ssh-ed25519", "ssh-rsa"… from the .pub file
    public var type: String
    /// the comment at the end of the .pub line (usually user@machine)
    public var comment: String
    public var name: String { (path as NSString).lastPathComponent }
}

public struct SSHConfigHost: Equatable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
}

public struct SSHOverview: Equatable, Sendable {
    public var sshDir: String
    public var keys: [SSHKey]
    public var configHosts: [SSHConfigHost]
    public var knownHostsCount: Int
    /// what `ssh-add -l` says, one line per key; nil = no agent reachable
    public var agentKeys: [String]?
}

public enum SSHInfo {
    public static var sshDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true) }

    public static func overview() async -> SSHOverview {
        let dir = sshDir
        let agent: [String]?
        if let r = try? await Shell.run("/usr/bin/ssh-add", ["-l"]) {
            agent = r.ok ? r.text.split(separator: "\n").map(String.init) : (r.stderr.lowercased().contains("no identities") || r.text.lowercased().contains("no identities") ? [] : nil)
        } else { agent = nil }
        return SSHOverview(sshDir: dir.path, keys: keys(in: dir), configHosts: configHosts(at: dir.appendingPathComponent("config")),
                           knownHostsCount: knownHostsCount(at: dir.appendingPathComponent("known_hosts")), agentKeys: agent)
    }

    /// Private keys in a folder: a file that starts with "-----BEGIN" and isn't a .pub, config or known_hosts.
    public static func keys(in dir: URL) -> [SSHKey] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [SSHKey] = []
        for name in names.sorted() where !name.hasSuffix(".pub") && !["config", "known_hosts", "known_hosts.old", "authorized_keys", "agent", "environment", "rc"].contains(name) {
            let url = dir.appendingPathComponent(name)
            guard let h = FileHandle(forReadingAtPath: url.path), let head = try? h.read(upToCount: 40), String(decoding: head, as: UTF8.self).hasPrefix("-----BEGIN") else { continue }
            let pub = url.appendingPathExtension("pub")
            var type = "", comment = ""
            if let line = try? String(contentsOf: pub, encoding: .utf8).split(separator: "\n").first {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                type = parts.first ?? ""
                comment = parts.count > 2 ? parts[2] : ""
            }
            out.append(SSHKey(path: url.path, hasPublicHalf: FileManager.default.fileExists(atPath: pub.path), type: type, comment: comment))
        }
        return out
    }

    /// The Host entries of an ssh config file (the keywords Data Syncer cares about).
    public static func configHosts(at url: URL) -> [SSHConfigHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseConfig(text)
    }

    public static func parseConfig(_ text: String) -> [SSHConfigHost] {
        var out: [SSHConfigHost] = []
        var current: SSHConfigHost?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.replacingOccurrences(of: "=", with: " ").split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            switch key {
            case "host":
                if let c = current { out.append(c) }
                current = value.contains("*") || value.contains("?") ? nil : SSHConfigHost(alias: value)
            case "match":
                if let c = current { out.append(c) }
                current = nil
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": current?.identityFile = value
            default: break
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    public static func knownHostsCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.count
    }
}
