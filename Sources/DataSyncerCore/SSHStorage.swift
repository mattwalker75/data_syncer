// A destination on an SSH server, through the Mac's own `ssh` (owner decision: the built-in tools, working
// with ~/.ssh — keys, config, known_hosts and the agent — exactly as Terminal does). One connection is kept open
// (ControlMaster) and every operation is a short remote command over it. Linux (GNU) and BSD/macOS servers.
import Foundation

public struct SSHOptions: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    /// a private key file; nil = ssh's own choice (the agent, ~/.ssh/config, the default keys)
    public var keyPath: String?
    /// the password, or the key's passphrase; nil = no secret (keys or the agent must do)
    public var secret: String?
    /// tests point this at their own file; nil = ~/.ssh/known_hosts
    public var knownHostsFile: String?
    public init(host: String, port: Int = 22, user: String, keyPath: String? = nil, secret: String? = nil, knownHostsFile: String? = nil) {
        self.host = host; self.port = port; self.user = user; self.keyPath = keyPath; self.secret = secret; self.knownHostsFile = knownHostsFile
    }
    public var label: String { "\(user)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

/// The connection: builds the ssh command line and runs remote commands over the shared master connection.
public final class SSHClient: @unchecked Sendable {
    public let options: SSHOptions
    private let controlDir: URL
    private var flavour: Flavour?
    private let lock = NSLock()

    enum Flavour { case gnu, bsd }

    public init(_ options: SSHOptions) {
        self.options = options
        // a short path: control sockets have a ~100-character limit
        controlDir = URL(fileURLWithPath: "/tmp/datasyncer-ssh-\(getuid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public var baseArguments: [String] {
        var a = ["-p", String(options.port),
                 "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDir.path)/%C", "-o", "ControlPersist=120",
                 "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "LogLevel=ERROR", "-o", "NumberOfPasswordPrompts=1"]
        if let k = options.knownHostsFile { a += ["-o", "UserKnownHostsFile=\(k)"] }
        if let key = options.keyPath, !key.isEmpty { a += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if options.secret == nil { a += ["-o", "BatchMode=yes"] }
        return a
    }

    /// With a password or passphrase, ssh asks an "askpass" program for it; ours prints it from the environment.
    public var environment: [String: String] {
        guard let secret = options.secret else { return [:] }
        let script = controlDir.appendingPathComponent("askpass.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try? Data("#!/bin/sh\nprintf '%s\\n' \"$DATASYNCER_SSH_SECRET\"\n".utf8).write(to: script)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        return ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "DATASYNCER_SSH_SECRET": secret]
    }

    private var target: String { "\(options.user)@\(options.host)" }

    /// Runs a shell command on the server.
    public func run(_ command: String, stdin: Data? = nil) async throws -> ShellResult {
        let r = try await Shell.run("/usr/bin/ssh", baseArguments + [target, command], environment: environment, stdin: stdin)
        if r.status == 255 { throw SSHClient.explain(r.stderr, options) }
        return r
    }

    /// Runs a command on the server with a local file on its stdin.
    public func feed(_ command: String, file: URL, progress: (@Sendable (Int64) -> Void)?) async throws -> ShellResult {
        let r = try await Shell.feed("/usr/bin/ssh", baseArguments + [target, command], environment: environment, file: file, progress: progress)
        if r.status == 255 { throw SSHClient.explain(r.stderr, options) }
        return r
    }

    /// Runs a command on the server and saves its output to a local file.
    public func drain(_ command: String, to file: URL) async throws -> ShellResult {
        let r = try await Shell.drain("/usr/bin/ssh", baseArguments + [target, command], environment: environment, to: file)
        if r.status == 255 { throw SSHClient.explain(r.stderr, options) }
        return r
    }

    /// Closes the shared connection (it would close itself after two idle minutes anyway).
    public func close() async {
        _ = try? await Shell.run("/usr/bin/ssh", baseArguments + ["-O", "exit", target], environment: environment)
    }

    /// GNU (Linux) or BSD (macOS, FreeBSD) tools on the server; found out once.
    func serverFlavour() async throws -> Flavour {
        lock.lock(); let known = flavour; lock.unlock()
        if let known { return known }
        let r = try await run("uname -s")
        let name = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let f: Flavour = ["Darwin", "FreeBSD", "OpenBSD", "NetBSD", "DragonFly"].contains(name) ? .bsd : .gnu
        lock.lock(); flavour = f; lock.unlock()
        return f
    }

    /// ssh's complaint, as a sentence for the user.
    public static func explain(_ stderr: String, _ o: SSHOptions) -> DSError {
        let s = stderr.lowercased()
        let who = o.label
        if s.contains("permission denied") {
            if o.keyPath != nil { return DSError("The server \(o.host) refused the sign-in for \(o.user) with the key \(o.keyPath!). Check the user name, that the key's public half is in the server's authorized_keys, and the passphrase if it has one.") }
            if o.secret != nil { return DSError("The server \(o.host) refused the password for \(o.user). Check the user name and password.") }
            return DSError("The server \(o.host) refused the sign-in for \(o.user): none of your keys (ssh-agent, ~/.ssh) were accepted and no password is saved. Add a password or a key to this destination.")
        }
        if s.contains("could not resolve") || s.contains("name or service not known") || s.contains("nodename nor servname") {
            return DSError("The server \(o.host) can't be found. Check the host name, or that you're on the right network.")
        }
        if s.contains("connection refused") { return DSError("\(o.host) isn't accepting SSH connections on port \(o.port). Check the port, and that SSH (Remote Login) is on at the server.") }
        if s.contains("timed out") || s.contains("no route to host") || s.contains("network is unreachable") {
            return DSError("\(o.host) isn't answering (port \(o.port)). Check that it's on and reachable from this network.")
        }
        if s.contains("host identification has changed") || (s.contains("host key") && (s.contains("changed") || s.contains("differs") || s.contains("mismatch"))) {
            return DSError("The identity of \(o.host) has changed since it was last used (its host key doesn't match ~/.ssh/known_hosts). If the server was rebuilt, remove its old line from known_hosts; if not, don't connect.")
        }
        if s.contains("host key verification failed") { return DSError("The identity of \(o.host) could not be verified (~/.ssh/known_hosts). Connect to it once in Terminal to accept it, then try again.") }
        if s.contains("incorrect passphrase") || s.contains("bad passphrase") { return DSError("The passphrase for the key \(o.keyPath ?? "") is wrong.") }
        if s.contains("control socket") || s.contains("mux") { return DSError("The SSH connection to \(who) broke: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let line = stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "no details"
        return DSError("SSH to \(who) failed: \(line)")
    }
}

// MARK: - the storage

public final class SSHStorage: Storage, @unchecked Sendable {
    public let client: SSHClient
    /// the destination folder on the server (absolute, or relative to the user's home)
    public let root: String
    public let describe: String
    public let keepsModifiedDates = true

    public init(options: SSHOptions, root: String) {
        client = SSHClient(options)
        self.root = root.isEmpty ? "." : root
        describe = "\(options.label), \(self.root)"
    }

    private func q(_ path: RelPath) -> String { Shell.quote(joinPath(root, path)) }

    public func checkReachable() async throws {
        let r = try await client.run("if test -d \(q("")); then if test -w \(q("")); then echo ok; else echo unwritable; fi; else echo missing; fi")
        switch r.text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ok": return
        case "unwritable": throw DSError("The folder \(root) on \(client.options.host) is there but \(client.options.user) can't write to it. Check its permissions.")
        default: throw DSError("The folder \(root) isn't there on \(client.options.host). Data Syncer never creates the destination folder itself — make it first, then try again.")
        }
    }

    public func exists(_ path: RelPath) async throws -> Bool {
        let r = try await client.run("test -e \(q(path)) || test -L \(q(path))")
        return r.status == 0
    }

    public func stat(_ path: RelPath) async throws -> FileMeta? {
        let entries = try await find(joinPath(root, path), depth: 0)
        return entries.first?.meta
    }

    public func list(_ dir: RelPath) async throws -> [Entry] {
        try await find(joinPath(root, dir), depth: 1).map { Entry(name: ($0.path as NSString).lastPathComponent, meta: $0.meta) }
    }

    /// One remote `find` for the whole tree, instead of one per folder.
    public func walk(_ dir: RelPath) async throws -> Snapshot {
        let base = joinPath(root, dir)
        let prefix = base == "." ? "./" : base + "/"
        var out: Snapshot = [:]
        for f in try await find(base, depth: nil) {
            guard f.path.hasPrefix(prefix) else { continue }
            let rel = String(f.path.dropFirst(prefix.count))
            if dir.isEmpty, rel == Records.folderName || rel.hasPrefix(Records.folderName + "/") { continue }
            out[rel] = f.meta
        }
        return out
    }

    public func makeDirectory(_ path: RelPath) async throws {
        let r = try await client.run("mkdir -p \(q(path))")
        guard r.ok else { throw DSError("The folder \(path) could not be made on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        let r = try await client.run("rm -rf \(q(path))")
        guard r.ok else { throw DSError("\(path) could not be removed on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let perms = String(format: "%o", Int(meta.permissions ?? 0o644) & 0o777)
        let stamp = SSHStorage.touchStamp(meta.modified)
        let command = "rm -rf \(q(path)) 2>/dev/null; cat > \(q(path)) && chmod \(perms) \(q(path)) && TZ=UTC touch -m -t \(stamp) \(q(path))"
        let r = try await client.feed(command, file: localURL, progress: progress)
        guard r.ok else { throw DSError("\(path) could not be written on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: localURL.path) { try? FileManager.default.removeItem(at: localURL) }
        let r = try await client.drain("cat \(q(path))", to: localURL)
        guard r.ok else { throw DSError("\(path) could not be read from \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        try LocalStorage.apply(meta, to: localURL)
    }

    public func readData(_ path: RelPath) async throws -> Data {
        let r = try await client.run("cat \(q(path))")
        guard r.ok else { throw DSError("\(path) could not be read from \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return r.stdout
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        let r = try await client.run("cat > \(q(path))", stdin: data)
        guard r.ok else { throw DSError("\(path) could not be written on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func freeSpace() async throws -> Int64? {
        let r = try await client.run("df -Pk \(q(""))")
        guard r.ok, let last = r.text.split(separator: "\n").last else { return nil }
        let cols = last.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 4, let kb = Int64(cols[3]) else { return nil }
        return kb * 1024
    }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        let r = try await client.run("rm -rf \(q(path)) 2>/dev/null; ln -s \(Shell.quote(target)) \(q(path))")
        guard r.ok else { throw DSError("The link \(path) could not be made on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    // MARK: listing

    struct Found: Equatable { var path: String; var meta: FileMeta }

    /// `depth` nil = the whole tree below `path`; 0 = the path itself; 1 = its children.
    private func find(_ path: String, depth: Int?) async throws -> [Found] {
        let flavour = try await client.serverFlavour()
        let qp = Shell.quote(path)
        let depthArgs: String
        switch depth {
        case 0: depthArgs = "-maxdepth 0"
        case .some(let d): depthArgs = "-mindepth \(d) -maxdepth \(d)"
        case nil: depthArgs = "-mindepth 1"
        }
        let command: String
        switch flavour {
        case .gnu: command = "find \(qp) \(depthArgs) -printf '%y\\t%s\\t%T@\\t%m\\t%l\\t%p\\n'"
        case .bsd: command = "find \(qp) \(depthArgs) -exec stat -f '%HT%t%z%t%m%t%OLp%t%Y%t%N' {} +"
        }
        let r = try await client.run(command)
        if !r.ok {
            if r.stderr.lowercased().contains("no such file") { return [] }
            if r.stdout.isEmpty { throw DSError("Listing \(path) on \(client.options.host) failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        return SSHStorage.parseFind(r.text, flavour: flavour)
    }

    /// Parses the lines `find` printed: type, size, modified, permissions, link target, path.
    static func parseFind(_ text: String, flavour: SSHClient.Flavour) -> [Found] {
        var out: [Found] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 6 else { continue }
            let type = cols[0], size = Int64(cols[1]) ?? 0, modified = Double(cols[2]) ?? 0
            let perms = Int16(cols[3], radix: 8), target = cols[4], path = cols[5]
            var meta = FileMeta(size: size, modified: modified, permissions: perms)
            switch flavour {
            case .gnu:
                meta.isDirectory = type == "d"; meta.isSymlink = type == "l"
            case .bsd:
                meta.isDirectory = type == "Directory"; meta.isSymlink = type == "Symbolic Link"
            }
            if meta.isDirectory || meta.isSymlink { meta.size = 0 }
            if meta.isSymlink { meta.linkTarget = target }
            out.append(Found(path: path, meta: meta))
        }
        return out
    }

    /// `touch -t` wants [[CC]YY]MMDDhhmm[.SS], read in the TZ we set (UTC).
    static func touchStamp(_ modified: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm.ss"
        return f.string(from: Date(timeIntervalSince1970: max(0, modified.rounded(.down))))
    }
}
