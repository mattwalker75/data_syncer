// SSH destinations: the parsing on its own, and real round trips against a private sshd started by the test
// (the Mac's own /usr/sbin/sshd on a high port, with its own host key and a throwaway client key — Remote Login
// is not needed and nothing in ~/.ssh or System Settings is touched).
import Foundation
import XCTest
@testable import DataSyncerCore

final class SSHParsingTests: XCTestCase {
    func testGNUFindLines() {
        let text = "d\t4096\t1697212345.123\t755\t\t/srv/x/sub\nf\t12\t1697212300\t644\t\t/srv/x/a.txt\nl\t5\t1697212200.5\t777\t../a.txt\t/srv/x/link\n"
        let found = SSHStorage.parseFind(text, flavour: .gnu)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found[0], .init(path: "/srv/x/sub", meta: FileMeta(isDirectory: true, size: 0, modified: 1697212345.123, permissions: 0o755)))
        XCTAssertEqual(found[1], .init(path: "/srv/x/a.txt", meta: FileMeta(size: 12, modified: 1697212300, permissions: 0o644)))
        XCTAssertEqual(found[2].meta.isSymlink, true)
        XCTAssertEqual(found[2].meta.linkTarget, "../a.txt")
        XCTAssertEqual(found[2].meta.size, 0)
    }

    func testBSDStatLines() {
        let text = "Directory\t96\t1697212345\t755\t\t/Users/m/x/sub\nRegular File\t12\t1697212300\t644\t\t/Users/m/x/a.txt\nSymbolic Link\t8\t1697212200\t755\tsub\t/Users/m/x/l\nbroken line\n"
        let found = SSHStorage.parseFind(text, flavour: .bsd)
        XCTAssertEqual(found.map(\.path), ["/Users/m/x/sub", "/Users/m/x/a.txt", "/Users/m/x/l"])
        XCTAssertTrue(found[0].meta.isDirectory)
        XCTAssertEqual(found[1].meta.permissions, 0o644)
        XCTAssertEqual(found[2].meta.linkTarget, "sub")
    }

    func testTouchStampAndQuoting() {
        XCTAssertEqual(SSHStorage.touchStamp(1_792_000_000), "202610141746.40")   // 2026-10-14 17:46:40 UTC
        XCTAssertEqual(Shell.quote("it's here"), "'it'\\''s here'")
    }

    func testErrorsAreSentences() {
        let o = SSHOptions(host: "nas", user: "matt")
        XCTAssertTrue(SSHClient.explain("matt@nas: Permission denied (publickey,password).", o).message.contains("no password is saved"))
        XCTAssertTrue(SSHClient.explain("ssh: Could not resolve hostname nas: nodename nor servname provided", o).message.contains("can't be found"))
        XCTAssertTrue(SSHClient.explain("ssh: connect to host nas port 22: Connection refused", o).message.contains("port 22"))
        XCTAssertTrue(SSHClient.explain("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", o).message.contains("known_hosts"))
        var withKey = o; withKey.keyPath = "/k/id_ed25519"
        XCTAssertTrue(SSHClient.explain("Permission denied (publickey).", withKey).message.contains("authorized_keys"))
    }

    func testConfigParsing() {
        let hosts = SSHInfo.parseConfig("""
        # comment
        Host nas
          HostName nas.local
          User matt
          Port 2222
          IdentityFile ~/.ssh/id_nas
        Host *
          ServerAliveInterval 30
        Host work
            HostName=work.example.com
        """)
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts[0], SSHConfigHost(alias: "nas", hostName: "nas.local", user: "matt", port: 2222, identityFile: "~/.ssh/id_nas"))
        XCTAssertEqual(hosts[1], SSHConfigHost(alias: "work", hostName: "work.example.com"))
    }

    func testKeyDiscovery() throws {
        let s = Scratch()
        let dir = s.dir("ssh")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n".utf8).write(to: dir.appendingPathComponent("id_ed25519"))
        try Data("ssh-ed25519 AAAAC3 matt@mac\n".utf8).write(to: dir.appendingPathComponent("id_ed25519.pub"))
        try Data("-----BEGIN RSA PRIVATE KEY-----\n".utf8).write(to: dir.appendingPathComponent("old_rsa"))
        try Data("Host x\n".utf8).write(to: dir.appendingPathComponent("config"))
        try Data("nas ssh-ed25519 AAAA\n# c\n\nother ssh-rsa BBBB\n".utf8).write(to: dir.appendingPathComponent("known_hosts"))
        let keys = SSHInfo.keys(in: dir)
        XCTAssertEqual(keys.map(\.name), ["id_ed25519", "old_rsa"])
        XCTAssertEqual(keys[0].type, "ssh-ed25519"); XCTAssertEqual(keys[0].comment, "matt@mac"); XCTAssertTrue(keys[0].hasPublicHalf)
        XCTAssertFalse(keys[1].hasPublicHalf)
        XCTAssertEqual(SSHInfo.knownHostsCount(at: dir.appendingPathComponent("known_hosts")), 2)
    }

    func testShareMatching() {
        let url = URL(string: "smb://nas/backups")!
        XCTAssertTrue(NetworkShare.matches(mountedFrom: "//matt@nas._smb._tcp.local/backups", mountedOn: "/Volumes/backups", fsType: "smbfs", url: url))
        XCTAssertTrue(NetworkShare.matches(mountedFrom: "//GUEST:@NAS.local:445/Backups", mountedOn: "/Volumes/Backups", fsType: "smbfs", url: url))
        XCTAssertFalse(NetworkShare.matches(mountedFrom: "//matt@nas/photos", mountedOn: "/Volumes/photos", fsType: "smbfs", url: url))
        XCTAssertFalse(NetworkShare.matches(mountedFrom: "//matt@other/backups", mountedOn: "/Volumes/backups", fsType: "smbfs", url: url))
        XCTAssertFalse(NetworkShare.matches(mountedFrom: "/dev/disk3s1", mountedOn: "/Volumes/backups", fsType: "apfs", url: url))
        XCTAssertTrue(NetworkShare.matches(mountedFrom: "afp_0TQ3x", mountedOn: "/Volumes/backups", fsType: "afpfs", url: url))
        XCTAssertTrue(NetworkShare.matches(mountedFrom: "//m@nas/My%20Share", mountedOn: "/Volumes/My Share", fsType: "smbfs", url: URL(string: "smb://nas/My%20Share")!))
    }

    func testSecretsRoundTripInMemory() throws {
        let s = MemorySecrets()
        let id = UUID()
        try s.set("pw", for: SecretAccount.destination(id))
        XCTAssertEqual(try s.secret(for: SecretAccount.destination(id)), "pw")
        XCTAssertEqual(SecretAccount.destinationId(try s.accounts()[0]), id)
        try s.remove(for: SecretAccount.destination(id))
        XCTAssertNil(try s.secret(for: SecretAccount.destination(id)))
    }
}

// MARK: - a private sshd

/// Starts /usr/sbin/sshd on a free high port with its own keys; stops it when deallocated.
final class TestSSHServer {
    let dir: URL
    let port: Int
    let keyPath: String
    let knownHosts: String
    private var process: Process?

    static func start(in scratch: Scratch) throws -> TestSSHServer? {
        let dir = scratch.dir("sshd")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        func keygen(_ name: String) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent(name).path]
            try p.run(); p.waitUntilExit()
        }
        try keygen("hostkey"); try keygen("clientkey")
        try FileManager.default.copyItem(at: dir.appendingPathComponent("clientkey.pub"), to: dir.appendingPathComponent("authorized_keys"))
        let port = Int.random(in: 20000...40000)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(dir.path)/hostkey
        AuthorizedKeysFile \(dir.path)/authorized_keys
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(dir.path)/sshd.pid
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR
        """
        try Data(config.utf8).write(to: dir.appendingPathComponent("sshd_config"))
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-f", dir.appendingPathComponent("sshd_config").path, "-D", "-e"]
        p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        try p.run()
        let server = TestSSHServer(dir: dir, port: port, keyPath: dir.appendingPathComponent("clientkey").path, knownHosts: dir.appendingPathComponent("known_hosts").path, process: p)
        // wait until it answers
        for _ in 0..<40 {
            if !p.isRunning { return nil }
            if server.ping() { return server }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private init(dir: URL, port: Int, keyPath: String, knownHosts: String, process: Process) {
        self.dir = dir; self.port = port; self.keyPath = keyPath; self.knownHosts = knownHosts; self.process = process
    }

    deinit { process?.terminate() }

    var options: SSHOptions { SSHOptions(host: "127.0.0.1", port: port, user: NSUserName(), keyPath: keyPath, knownHostsFile: knownHosts) }

    private func ping() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-p", String(port), "-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=\(knownHosts)", "-o", "ConnectTimeout=2", "-o", "LogLevel=ERROR", "127.0.0.1", "true"]
        p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

final class SSHRoundTripTests: XCTestCase {
    var scratch: Scratch!
    var server: TestSSHServer!

    override func setUpWithError() throws {
        scratch = Scratch()
        guard let s = try TestSSHServer.start(in: scratch) else { throw XCTSkip("a private sshd could not be started on this Mac") }
        server = s
    }

    override func tearDown() async throws {
        if let server { await SSHClient(server.options).close() }
        server = nil
    }

    func testStorageBasics() async throws {
        let remote = scratch.dir("remote")
        let st = SSHStorage(options: server.options, root: remote.path)
        try await st.checkReachable()
        let existsBefore = try await st.exists("a.txt"); XCTAssertFalse(existsBefore)
        try await st.writeData(Data("hello".utf8), to: "a.txt")
        let read = try await st.readData("a.txt"); XCTAssertEqual(read, Data("hello".utf8))
        try await st.makeDirectory("sub/deeper")
        try await st.makeSymlink("link", target: "a.txt")
        let listed = try await st.list("")
        XCTAssertEqual(Set(listed.map(\.name)), ["a.txt", "sub", "link"])
        let walked = try await st.walk()
        XCTAssertEqual(Set(walked.keys), ["a.txt", "sub", "sub/deeper", "link"])
        XCTAssertEqual(walked["link"]?.linkTarget, "a.txt")
        XCTAssertTrue(walked["sub"]?.isDirectory ?? false)
        let free = try await st.freeSpace(); XCTAssertNotNil(free)
        // upload keeps size, date and permissions; download brings them back
        let local = scratch.dir("local").appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 3 * 1024 * 1024 + 123).write(to: local)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000), .posixPermissions: 0o600], ofItemAtPath: local.path)
        let meta = LocalStorage.meta(at: local)!
        let seen = Locked<[Int64]>([])
        try await st.upload(localURL: local, to: "sub/big.bin", meta: meta, progress: { n in seen.with { $0.append(n) } })
        XCTAssertEqual(seen.with { $0 }.last, Int64(3 * 1024 * 1024 + 123))
        let remoteMeta = try await st.stat("sub/big.bin")!
        XCTAssertEqual(remoteMeta.size, meta.size)
        XCTAssertEqual(remoteMeta.modified, 1_700_000_000)
        XCTAssertEqual(remoteMeta.permissions, 0o600)
        let back = scratch.dir("back").appendingPathComponent("big.bin")
        try await st.download("sub/big.bin", to: back, meta: remoteMeta)
        XCTAssertEqual(try Data(contentsOf: back).count, 3 * 1024 * 1024 + 123)
        XCTAssertEqual(LocalStorage.meta(at: back)?.modified, 1_700_000_000)
        try await st.remove("sub")
        let existsAfter = try await st.exists("sub/big.bin"); XCTAssertFalse(existsAfter)
        // a missing folder fails the check with a plain message
        let missing = SSHStorage(options: server.options, root: remote.appendingPathComponent("nope").path)
        do { try await missing.checkReachable(); XCTFail("should fail") } catch let e as DSError { XCTAssertTrue(e.message.contains("isn't there")) }
    }

    func testSyncBackupAndRestoreOverSSH() async throws {
        let src = scratch.dir("src"), remote = scratch.dir("remote-dest")
        makeTree(src, ["a.txt": "A", "docs/b.txt": "B", "docs/link": "@b.txt"])
        var job = Job(name: "Over SSH", sourcePath: src.path)
        let o = server.options
        job.destinations = [
            Destination(name: "server sync", kind: .sftp(host: o.host, port: o.port, user: o.user, keyPath: o.keyPath), folder: remote.appendingPathComponent("sync").path, mode: .sync(deleteExtras: true)),
            Destination(name: "server backups", kind: .sftp(host: o.host, port: o.port, user: o.user, keyPath: o.keyPath), folder: remote.appendingPathComponent("backups").path, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5), backupTitle: "T"),
        ]
        _ = scratch.dir("remote-dest/sync"); _ = scratch.dir("remote-dest/backups")
        struct Factory: StorageFactory {
            let knownHosts: String
            func storage(for d: Destination) async throws -> Storage {
                guard case .sftp(let h, let p, let u, let k) = d.kind else { throw DSError("x") }
                return SSHStorage(options: SSHOptions(host: h, port: p, user: u, keyPath: k, knownHostsFile: knownHosts), root: d.folder)
            }
        }
        let clock = FixedClock()
        let r = JobRunner(factory: Factory(knownHosts: server.knownHosts)); r.now = { clock.date }
        let first = await r.run(job, choices: [job.destinations[1].id: .full]) { _ in }
        XCTAssertEqual(first.results.map(\.status), [.finished, .finished], first.results.flatMap(\.problems).joined(separator: "; "))
        XCTAssertEqual(readTree(remote.appendingPathComponent("sync")), ["a.txt": "A", "docs": "<dir>", "docs/b.txt": "B", "docs/link": "@b.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("sync/.datasyncer/README.txt").path))
        // change the source, run again: sync mirrors (deletes), the backup is an incremental
        try FileManager.default.removeItem(at: src.appendingPathComponent("a.txt"))
        makeTree(src, ["c.txt": "C"])
        clock.tick()
        let second = await r.run(job) { _ in }
        XCTAssertEqual(second.results.map(\.status), [.finished, .finished], second.results.flatMap(\.problems).joined(separator: "; "))
        XCTAssertEqual(second.results[0].deleted, 1)
        XCTAssertEqual(second.results[0].copied, 1)
        XCTAssertEqual(second.results[0].unchanged, 2)   // b.txt and the link; folders aren't counted
        let backups = try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("backups").path).filter { $0.hasPrefix("2026") }.sorted()
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups[1].contains("_Incremental_T"))
        // restore the incremental over SSH into a local folder
        let storage = try await Factory(knownHosts: server.knownHosts).storage(for: job.destinations[1])
        let catalog = try await BackupCatalog.load(from: storage)
        let target = scratch.dir("restored")
        let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: backups[1], to: target, removeDeleted: true) { _ in }
        XCTAssertEqual(result.status, .finished, result.problems.joined(separator: "; "))
        XCTAssertEqual(readTree(target), ["c.txt": "C", "docs": "<dir>", "docs/b.txt": "B", "docs/link": "@b.txt"])
        // the preflight over SSH
        let check = await Preflight.check(job, job.destinations[1], factory: Factory(knownHosts: server.knownHosts))
        XCTAssertTrue(check.ok, check.items.map(\.detail).joined(separator: "; "))
        XCTAssertTrue(check.items.contains { $0.name == "Backups here" && $0.detail.contains("1 full, 1 incremental") })
    }

    func testWrongKeyGivesAPlainMessage() async throws {
        var o = server.options
        let bad = scratch.dir("badkey").appendingPathComponent("k")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); p.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", bad.path]; try p.run(); p.waitUntilExit()
        o.keyPath = bad.path
        let st = SSHStorage(options: o, root: scratch.root.path)
        do { try await st.checkReachable(); XCTFail("should fail") }
        catch let e as DSError { XCTAssertTrue(e.message.contains("refused the sign-in"), e.message) }
    }
}
