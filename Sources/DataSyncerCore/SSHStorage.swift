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

    /// The control folder must be ours alone: not a link, owned by us, mode 0700 — another account must never be
    /// able to plant an askpass script that would see the password.
    func checkControlDir() throws {
        var st = Darwin.stat()
        guard lstat(controlDir.path, &st) == 0 else { throw DSError("The SSH working folder \(controlDir.path) could not be made.") }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        guard isDir, st.st_uid == getuid() else {
            throw DSError("The SSH working folder \(controlDir.path) belongs to someone else or is a link. Remove it and try again.")
        }
        // ours but with the wrong mode (something touched /tmp): put it right rather than refuse
        if (st.st_mode & 0o777) != 0o700 { chmod(controlDir.path, 0o700) }
        guard lstat(controlDir.path, &st) == 0, (st.st_mode & 0o777) == 0o700 else {
            throw DSError("The SSH working folder \(controlDir.path) could not be made private. Remove it and try again.")
        }
    }

    /// Each client gets its own master connection, so closing one never cuts another's command to the same server.
    private let instance = String(UUID().uuidString.prefix(8))

    public var baseArguments: [String] {
        var a = ["-p", String(options.port),
                 "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDir.path)/%C-\(instance)", "-o", "ControlPersist=120",
                 "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "LogLevel=ERROR", "-o", "NumberOfPasswordPrompts=1"]
        if let k = options.knownHostsFile { a += ["-o", "UserKnownHostsFile=\(k)"] }
        if let key = options.keyPath, !key.isEmpty { a += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if options.secret == nil { a += ["-o", "BatchMode=yes"] }
        return a
    }

    static let askpassText = "#!/bin/sh\nprintf '%s\\n' \"$DATASYNCER_SSH_SECRET\"\n"
    private static let askpassLock = NSLock()

    /// With a password or passphrase, ssh asks an "askpass" program for it; ours prints it from the environment.
    /// The script's content never changes, so it is written once (atomically, under a lock) and only replaced
    /// when it is missing or differs — rewriting it on every call made a parallel client's ssh find no script.
    public var environment: [String: String] {
        guard let secret = options.secret else { return [:] }
        let script = controlDir.appendingPathComponent("askpass.sh")
        SSHClient.askpassLock.lock(); defer { SSHClient.askpassLock.unlock() }
        var st = Darwin.stat()
        let fine = lstat(script.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_uid == getuid() && (st.st_mode & 0o777) == 0o700
            && (try? String(contentsOf: script, encoding: .utf8)) == SSHClient.askpassText
        if !fine {
            let tmp = controlDir.appendingPathComponent("askpass.sh.\(getpid()).tmp")
            try? Data(SSHClient.askpassText.utf8).write(to: tmp)
            chmod(tmp.path, 0o700)
            _ = rename(tmp.path, script.path)
        }
        return ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "DATASYNCER_SSH_SECRET": secret]
    }

    /// Every remote command runs under `sh`, whatever the user's login shell is (csh, fish…).
    static func wrapped(_ command: String) -> String { "sh -c " + Shell.quote(command) }

    private var target: String { "\(options.user)@\(options.host)" }

    /// Runs a shell command on the server.
    public func run(_ command: String, stdin: Data? = nil) async throws -> ShellResult {
        try checkControlDir()
        let r = try await Shell.run("/usr/bin/ssh", baseArguments + [target, SSHClient.wrapped(command)], environment: environment, stdin: stdin)
        if r.status == 255 { throw SSHClient.explain(r.stderr, options) }
        return r
    }

    /// Runs a command on the server with a local file on its stdin.
    public func feed(_ command: String, file: URL, progress: (@Sendable (Int64) -> Void)?) async throws -> ShellResult {
        try checkControlDir()
        let r = try await Shell.feed("/usr/bin/ssh", baseArguments + [target, SSHClient.wrapped(command)], environment: environment, file: file, progress: progress)
        if r.status == 255 { throw SSHClient.explain(r.stderr, options) }
        return r
    }

    /// Runs a command on the server and saves its output to a local file.
    public func drain(_ command: String, to file: URL) async throws -> ShellResult {
        try checkControlDir()
        let r = try await Shell.drain("/usr/bin/ssh", baseArguments + [target, SSHClient.wrapped(command)], environment: environment, to: file)
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
        if s.contains("too many authentication failures") { return DSError("\(o.host) gave up after too many keys were offered (ssh-agent holds several). Choose the key file for this destination so only that one is tried.") }
        if s.contains("kex_exchange_identification") || s.contains("connection closed by remote host") || s.contains("connection reset") {
            return DSError("\(o.host) closed the connection as soon as it opened — often rate limiting after failed sign-ins, or a firewall. Wait a minute and try again.")
        }
        if s.contains("control socket") || s.contains("mux") { return DSError("The SSH connection to \(who) broke: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let line = stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return DSError("The SSH connection to \(who) was lost part-way through. Check the network and try again.") }
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
        self.root = SSHStorage.normalise(root)
        describe = "\(options.label), \(self.root)"
    }

    /// "/srv/x/" → "/srv/x"; "~/backups" → "backups" (relative to the home folder ssh lands in); "" → "."
    static func normalise(_ root: String) -> String {
        var r = root.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("~/") { r = String(r.dropFirst(2)) } else if r == "~" { r = "" }
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        if r.isEmpty || r == "." { return "." }
        // a relative root that starts with "-" would read as an option to find/rm
        return r.hasPrefix("-") ? "./" + r : r
    }

    /// Closes the shared connection when a run is done with this destination.
    public func close() async { await client.close() }

    /// Quoted for the remote `sh -c`, with "!" spelled so a csh/tcsh login shell (which expands history even inside
    /// single quotes) never sees it: the inner sh rebuilds it from printf.
    static func rq(_ s: String) -> String { Shell.quote(s).replacingOccurrences(of: "!", with: "'\"$(printf '\\041')\"'") }
    private func q(_ path: RelPath) -> String { SSHStorage.rq(joinPath(root, path)) }

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
        // a file or link in the way must go; mkdir -p would "succeed" on a link to a folder
        let r = try await client.run("if test -L \(q(path)) || { test -e \(q(path)) && ! test -d \(q(path)); }; then rm -rf -- \(q(path)); fi; mkdir -p -- \(q(path))")
        guard r.ok else { throw DSError("The folder \(path) could not be made on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func remove(_ path: RelPath) async throws {
        guard !path.isEmpty else { throw DSError("Refusing to remove the destination folder itself.") }
        let r = try await client.run("rm -rf -- \(q(path))")
        guard r.ok else { throw DSError("\(path) could not be removed on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        let perms = String(format: "%o", Int(meta.permissions ?? 0o644) & 0o777)
        let stamp = SSHStorage.touchStamp(meta.modified)
        // written under a temporary name and moved into place only when complete, so the old copy survives a
        // dropped connection or a cancel and nothing half-written ever sits under the real name
        let tmp = SSHStorage.rq(joinPath(root, path) + ".datasyncer-part")
        // the remote `cat` cannot tell a finished transfer from a cut one (it just sees end-of-file), so the server
        // checks the byte count before the file is moved into place; a short file is removed, never installed
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? meta.size
        let command = "rm -rf -- \(tmp); cat > \(tmp) && test \"$(wc -c < \(tmp))\" -eq \(size) && chmod \(perms) \(tmp) && TZ=UTC touch -m -t \(stamp) -- \(tmp) && { if test -L \(q(path)) || test -d \(q(path)); then rm -rf -- \(q(path)); fi; mv -f -- \(tmp) \(q(path)); } || { rm -f -- \(tmp); exit 1; }"
        let r: ShellResult
        do { r = try await client.feed(command, file: localURL, progress: progress) }
        catch {
            // the transfer was cut (cancel, dropped connection): remove the part file, outside the cancelled task
            let c = client, t = tmp
            await Task.detached { _ = try? await c.run("rm -f -- \(t)") }.value
            throw error
        }
        guard r.ok else { throw DSError("\(path) could not be written on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "the transfer did not complete" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func download(_ path: RelPath, to localURL: URL, meta: FileMeta) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = localURL.deletingLastPathComponent().appendingPathComponent(LocalStorage.partName(for: localURL.lastPathComponent))
        let r: ShellResult
        do { r = try await client.drain("cat -- \(q(path))", to: tmp) } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        guard r.ok else { try? FileManager.default.removeItem(at: tmp); throw DSError("\(path) could not be read from \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        try LocalStorage.apply(meta, to: tmp)
        if let m = LocalStorage.meta(at: localURL), m.isDirectory || m.isSymlink { try? FileManager.default.removeItem(at: localURL) }
        guard rename(tmp.path, localURL.path) == 0 else { try? FileManager.default.removeItem(at: tmp); throw DSError("Could not put \(localURL.lastPathComponent) in place.") }
    }

    public func readData(_ path: RelPath) async throws -> Data {
        let r = try await client.run("cat -- \(q(path))")
        guard r.ok else { throw DSError("\(path) could not be read from \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return r.stdout
    }

    public func writeData(_ data: Data, to path: RelPath) async throws {
        let tmp = SSHStorage.rq(joinPath(root, path) + ".datasyncer-part")
        let r = try await client.run("cat > \(tmp) && test \"$(wc -c < \(tmp))\" -eq \(data.count) && mv -f -- \(tmp) \(q(path))", stdin: data)
        guard r.ok else { _ = try? await client.run("rm -f -- \(tmp)"); throw DSError("\(path) could not be written on \(client.options.host): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func freeSpace() async throws -> Int64? {
        let r = try await client.run("df -Pk -- \(q(""))")
        guard r.ok, let last = r.text.split(separator: "\n").last else { return nil }
        let cols = last.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 4, let kb = Int64(cols[3]) else { return nil }
        return kb * 1024
    }

    public func applyDirectoryMeta(_ path: RelPath, meta: FileMeta) async throws {
        let perms = String(format: "%o", Int(meta.permissions ?? 0o755) & 0o777)
        _ = try await client.run("chmod \(perms) \(q(path)) && TZ=UTC touch -m -t \(SSHStorage.touchStamp(meta.modified)) -- \(q(path))")
    }

    public func makeSymlink(_ path: RelPath, target: String) async throws {
        let r = try await client.run("rm -rf -- \(q(path)) 2>/dev/null; ln -s -- \(SSHStorage.rq(target)) \(q(path))")
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
        // -H: a root that is itself a link to a folder (common on NAS boxes) is followed; entries below are not
        let follow = depth == 0 ? "" : "-H "
        let command: String
        switch flavour {
        case .gnu: command = "find \(follow)\(qp) \(depthArgs) -printf '%y\\t%s\\t%T@\\t%m\\t%l\\t%p\\n'"
        case .bsd: command = "find \(follow)\(qp) \(depthArgs) -exec stat -f '%HT%t%z%t%m%t%OLp%t%Y%t%N' {} +"
        }
        let r = try await client.run(command)
        if !r.ok {
            // find carries on after an entry it could not read and exits 1: keep what it listed. Only a listing
            // that produced nothing is taken as "not there" (or as a failure when it says more than that)
            if r.stdout.isEmpty {
                if r.stderr.lowercased().contains("no such file") { return [] }
                throw DSError("Listing \(path) on \(client.options.host) failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
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
