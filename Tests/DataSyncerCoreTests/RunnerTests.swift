import XCTest
@testable import DataSyncerCore

final class SyncRunTests: XCTestCase {
    func testASyncMirrorsTheSourceAndLeavesRecords() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        makeTree(src, ["a.txt": "A", "docs/b.md": "B", "empty/": "", "link": "@a.txt"], modified: when)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("a.txt").path)
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        var events: [RunEvent] = []
        let report = await JobRunner().run(job) { events.append($0) }
        XCTAssertEqual(report.first.status, .finished, "\(report.first.problems)")
        XCTAssertEqual(report.first.copied, 3)
        XCTAssertEqual(readTree(dst), ["a.txt": "A", "docs": "<dir>", "docs/b.md": "B", "empty": "<dir>", "link": "@a.txt"])
        XCTAssertEqual(modified(dst.appendingPathComponent("a.txt")).timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        let perms = try FileManager.default.attributesOfItem(atPath: dst.appendingPathComponent("a.txt").path)[.posixPermissions] as! Int
        XCTAssertEqual(perms, 0o755)
        // the records
        let readme = try String(contentsOf: dst.appendingPathComponent(".datasyncer/README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.hasPrefix("This is metadata used by the Data Syncer tool"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent(".datasyncer/destination.json").path))
        let state = try await Records.loadSyncState(from: LocalStorage(root: dst))
        XCTAssertEqual(state?.files.count, 3)
        // the plan was announced before copying
        XCTAssertTrue(events.contains { if case .planned(_, let s) = $0 { return s.contains("copy 3") } else { return false } })

        // a second run has nothing to do
        let again = await JobRunner().run(job) { _ in }
        XCTAssertEqual(again.first.copied, 0)
        XCTAssertEqual(again.first.unchanged, 3) // two files and the link
    }

    func testDeletingAtTheDestinationIsPerJobSwitch() async throws {
        let s = Scratch()
        let src = s.dir("src"), keep = s.dir("keep"), mirror = s.dir("mirror")
        makeTree(src, ["a.txt": "A", "old/x.txt": "X"])
        let job = Job(name: "J", sourcePath: src.path, destinations: [
            Destination(name: "Keep", kind: .localFolder, folder: keep.path, mode: .sync(deleteExtras: false)),
            Destination(name: "Mirror", kind: .localFolder, folder: mirror.path, mode: .sync(deleteExtras: true)),
        ])
        _ = await JobRunner().run(job) { _ in }
        try FileManager.default.removeItem(at: src.appendingPathComponent("old"))
        let report = await JobRunner().run(job) { _ in }
        XCTAssertEqual(report.results[0].deleted, 0)
        XCTAssertEqual(readTree(keep)["old/x.txt"], "X")
        XCTAssertEqual(report.results[1].deleted, 2)
        XCTAssertNil(readTree(mirror)["old"])
    }

    func testAChangedCopyAtTheDestinationIsPutRight() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        _ = await JobRunner().run(job) { _ in }
        try Data("tampered".utf8).write(to: dst.appendingPathComponent("a.txt"))
        let report = await JobRunner().run(job) { _ in }
        XCTAssertEqual(report.first.copied, 1)
        XCTAssertEqual(readTree(dst)["a.txt"], "A")
    }

    func testAMissingDestinationFolderStopsThatDestinationAndTheRunCarriesOn() async throws {
        let s = Scratch()
        let src = s.dir("src"), good = s.dir("good")
        makeTree(src, ["a.txt": "A"])
        let missing = s.root.appendingPathComponent("not-made").path
        let job = Job(name: "J", sourcePath: src.path, destinations: [
            Destination(name: "Missing", kind: .localFolder, folder: missing, mode: .sync(deleteExtras: true)),
            Destination(name: "Off", kind: .localFolder, folder: good.path, mode: .sync(deleteExtras: true), enabled: false),
            Destination(name: "Good", kind: .localFolder, folder: good.path, mode: .sync(deleteExtras: true)),
        ])
        let report = await JobRunner().run(job) { _ in }
        guard case .failed(let why) = report.results[0].status else { return XCTFail("expected a failure") }
        XCTAssertTrue(why.contains("isn't there") && why.contains("never creates"), why)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        guard case .skipped = report.results[1].status else { return XCTFail("expected skipped") }
        XCTAssertEqual(report.results[2].status, .finished)
        XCTAssertFalse(report.allFine)
    }

    func testAUsbDriveThatIsNotConnectedSaysSo() async throws {
        let d = Destination(name: "U", kind: .usbDrive(volumeName: "NoSuchDrive-\(UUID().uuidString.prefix(6))"), folder: "/backup", mode: .fullOnly)
        do { _ = try await DefaultStorageFactory().storage(for: d); XCTFail("expected an error") }
        catch let e as DSError { XCTAssertTrue(e.message.contains("isn't connected"), e.message) }
    }
}

final class BackupRunTests: XCTestCase {
    func testFullAndIncrementalsChainAndRespectTheLimit() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A", "dog.txt": "woof", "sub/b.txt": "B"])
        let clock = FixedClock()
        let r = runner(clock)
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 2), title: "Work docs")
        let destId = job.destinations[0].id

        // 1. nothing here yet: an incremental is not possible, so the first run becomes a full
        let full = await r.run(job) { _ in }
        XCTAssertEqual(full.first.status, .finished, "\(full.first.problems)")
        let fullName = full.first.backupFolder!
        XCTAssertTrue(fullName.hasSuffix("_Full_Work_docs"), fullName)
        XCTAssertEqual(readTree(dst.appendingPathComponent(fullName)), ["a.txt": "A", "dog.txt": "woof", "sub": "<dir>", "sub/b.txt": "B"])
        // asking for an incremental outright is refused with the reason
        let storage = LocalStorage(root: dst)
        let empty = BackupCatalog(entries: [])
        XCTAssertNotNil(empty.incrementalParent(chainStart: .lastIncremental, maxIncrementals: 2).reason)

        // 2. change, add, delete; incremental since the full
        clock.tick()
        try Data("A2".utf8).write(to: src.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: src.appendingPathComponent("a.txt").path)
        makeTree(src, ["new.txt": "N"])
        try FileManager.default.removeItem(at: src.appendingPathComponent("dog.txt"))
        let inc1 = await r.run(job, choices: [destId: .incremental]) { _ in }
        XCTAssertEqual(inc1.first.status, .finished, "\(inc1.first.problems)")
        let inc1Name = inc1.first.backupFolder!
        XCTAssertTrue(inc1Name.contains("_Incremental_"))
        XCTAssertEqual(readTree(dst.appendingPathComponent(inc1Name)), ["a.txt": "A2", "new.txt": "N"]) // only what changed
        let m1 = try await Records.loadManifest(of: inc1Name, from: storage)!
        XCTAssertEqual(m1.basedOn, fullName)
        XCTAssertEqual(m1.deleted, ["dog.txt"])
        XCTAssertEqual(Set(m1.copied), ["a.txt", "new.txt"])
        XCTAssertEqual(m1.snapshot.count, 4) // a.txt, new.txt, sub, sub/b.txt

        // 3. a second incremental chains from the first
        clock.tick()
        makeTree(src, ["later.txt": "L"])
        let inc2 = await r.run(job) { _ in }
        let m2 = try await Records.loadManifest(of: inc2.first.backupFolder!, from: storage)!
        XCTAssertEqual(m2.basedOn, inc1Name)
        XCTAssertEqual(m2.copied, ["later.txt"])

        // 4. the chain is at its limit of 2: an explicit incremental is refused, the default becomes a full
        clock.tick()
        let refused = await r.run(job, choices: [destId: .incremental]) { _ in }
        guard case .failed(let why) = refused.first.status else { return XCTFail("expected a refusal") }
        XCTAssertTrue(why.contains("limit is 2"), why)
        clock.tick()
        let forced = await r.run(job) { _ in }
        XCTAssertTrue(forced.first.backupFolder!.contains("_Full_"))
        let all = try await BackupCatalog.load(from: storage)
        XCTAssertEqual(all.entries.count, 4)
    }

    func testChainFromLastFullMeasuresEveryIncrementalAgainstTheFull() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let clock = FixedClock()
        let r = runner(clock)
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastFull, maxIncrementals: 10))
        let full = await r.run(job) { _ in }
        clock.tick(); makeTree(src, ["b.txt": "B"])
        let i1 = await r.run(job) { _ in }
        clock.tick(); makeTree(src, ["c.txt": "C"])
        let i2 = await r.run(job) { _ in }
        let storage = LocalStorage(root: dst)
        let m2 = try await Records.loadManifest(of: i2.first.backupFolder!, from: storage)!
        XCTAssertEqual(m2.basedOn, full.first.backupFolder)
        XCTAssertEqual(Set(m2.copied), ["b.txt", "c.txt"]) // everything since the full, not just since i1
        _ = i1
    }

    func testFullOnlyMakesANewFolderEveryRun() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let clock = FixedClock()
        let r = runner(clock)
        let job = localJob(source: src, dest: dst, mode: .fullOnly)
        _ = await r.run(job, choices: [job.destinations[0].id: .incremental]) { _ in } // ignored: full only
        clock.tick()
        _ = await r.run(job) { _ in }
        let names = try await BackupCatalog.load(from: LocalStorage(root: dst)).entries.map(\.folder)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { $0.contains("_Full_") })
    }

    func testTwoBackupsInTheSameMinuteAreRefused() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let r = runner(FixedClock())
        let job = localJob(source: src, dest: dst, mode: .fullOnly)
        _ = await r.run(job) { _ in }
        let second = await r.run(job) { _ in }
        guard case .failed(let why) = second.first.status else { return XCTFail("expected a refusal") }
        XCTAssertTrue(why.contains("same minute"), why)
    }

    func testACancelledBackupLeavesNoHalfFolder() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        var files: [String: String] = [:]
        for i in 0..<40 { files["f\(i).txt"] = String(repeating: "x", count: 2000) }
        makeTree(src, files)
        let job = localJob(source: src, dest: dst, mode: .fullOnly)
        let r = runner(FixedClock())
        let task = Task { await r.run(job) { _ in } }
        // cancel as soon as the first file lands
        let watcher = Task {
            while !(readTree(dst).keys.contains { $0.contains("_Full_") && $0.contains("/f") }) { try? await Task.sleep(nanoseconds: 2_000_000) }
            task.cancel()
        }
        let report = await task.value
        watcher.cancel()
        XCTAssertEqual(report.first.status, .cancelled)
        try? await Task.sleep(nanoseconds: 200_000_000) // the cleanup is a detached task
        let left = try await BackupCatalog.load(from: LocalStorage(root: dst))
        XCTAssertEqual(left.entries.count, 0)
        XCTAssertFalse(readTree(dst).keys.contains { $0.contains("_Full_") })
    }
}

final class RestoreTests: XCTestCase {
    /// Full with "dog", an incremental that recorded dog as deleted, then restore both ways.
    func testRestoreRebuildsTheChainAndHonoursTheDeletedSwitch() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A", "dog.txt": "woof", "sub/b.txt": "B"])
        let clock = FixedClock()
        let r = runner(clock)
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5))
        _ = await r.run(job) { _ in }
        clock.tick()
        try FileManager.default.removeItem(at: src.appendingPathComponent("dog.txt"))
        try Data("A2".utf8).write(to: src.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: src.appendingPathComponent("a.txt").path)
        makeTree(src, ["cat.txt": "meow"])
        let inc = await r.run(job) { _ in }
        let storage = LocalStorage(root: dst)
        let catalog = try await BackupCatalog.load(from: storage)
        let point = inc.first.backupFolder!

        let plan = try RestoreEngine.plan(catalog, point: point)
        XCTAssertEqual(plan.chain.count, 2)
        XCTAssertEqual(plan.deletions, 1)

        let keep = s.dir("restore-keep")
        let kept = await RestoreEngine.restore(from: storage, catalog: catalog, point: point, to: keep, removeDeleted: false) { _ in }
        XCTAssertEqual(kept.status, .finished, "\(kept.problems)")
        XCTAssertEqual(readTree(keep), ["a.txt": "A2", "cat.txt": "meow", "dog.txt": "woof", "sub": "<dir>", "sub/b.txt": "B"])

        let clean = s.dir("restore-clean")
        let removed = await RestoreEngine.restore(from: storage, catalog: catalog, point: point, to: clean, removeDeleted: true) { _ in }
        XCTAssertEqual(removed.removed, 1)
        XCTAssertEqual(readTree(clean), ["a.txt": "A2", "cat.txt": "meow", "sub": "<dir>", "sub/b.txt": "B"])

        // restoring the full alone gives the older state
        let old = s.dir("restore-old")
        let fullName = catalog.newestFull!.folder
        _ = await RestoreEngine.restore(from: storage, catalog: catalog, point: fullName, to: old, removeDeleted: true) { _ in }
        XCTAssertEqual(readTree(old)["a.txt"], "A")
        XCTAssertEqual(readTree(old)["dog.txt"], "woof")
    }

    func testADeletedFullBackupBreaksOnlyTheIncrementalsThatNeedIt() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let clock = FixedClock()
        let r = runner(clock)
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5))
        let full1 = await r.run(job) { _ in }
        clock.tick(); makeTree(src, ["b.txt": "B"])
        let inc1 = await r.run(job) { _ in }
        clock.tick(minutes: 60)
        let full2 = await r.run(job, choices: [job.destinations[0].id: .full]) { _ in }
        // the user deletes the first full in Finder
        try FileManager.default.removeItem(at: dst.appendingPathComponent(full1.first.backupFolder!))
        let catalog = try await BackupCatalog.load(from: LocalStorage(root: dst))
        XCTAssertThrowsError(try RestoreEngine.plan(catalog, point: inc1.first.backupFolder!)) { e in
            XCTAssertTrue((e as! DSError).message.contains("missing"), (e as! DSError).message)
        }
        XCTAssertNoThrow(try RestoreEngine.plan(catalog, point: full2.first.backupFolder!))
        // and the next incremental still works, from the newest full
        clock.tick(); makeTree(src, ["c.txt": "C"])
        let inc2 = await r.run(job) { _ in }
        XCTAssertEqual(inc2.first.status, .finished)
        let m = try await Records.loadManifest(of: inc2.first.backupFolder!, from: LocalStorage(root: dst))!
        XCTAssertEqual(m.basedOn, full2.first.backupFolder)
    }
}

final class PreflightAndStoreTests: XCTestCase {
    func testChecksSayWhatIsWrongInPlainWords() async throws {
        let s = Scratch()
        let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let bad = Destination(name: "Bad", kind: .localFolder, folder: s.root.appendingPathComponent("nope").path, mode: .fullOnly)
        let badCheck = await Preflight.check(localJob(source: src, dest: dst, mode: .fullOnly), bad)
        XCTAssertFalse(badCheck.ok)
        XCTAssertTrue(badCheck.items[0].detail.contains("isn't there"))
        let good = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastFull, maxIncrementals: 3))
        let goodCheck = await Preflight.check(good, good.destinations[0])
        XCTAssertTrue(goodCheck.ok, "\(goodCheck.items)")
        XCTAssertFalse(goodCheck.canIncremental)
        XCTAssertTrue(goodCheck.incrementalNote.contains("no full backup here yet"))
        XCTAssertTrue(Preflight.checkSource(good).ok)
        XCTAssertFalse(Preflight.checkSource(Job(name: "x", sourcePath: "/nope/nothing")).ok)
    }

    func testJobsSaveAndLoad() throws {
        let s = Scratch()
        let store = JobStore(url: s.root.appendingPathComponent("jobs.json"))
        XCTAssertEqual(try store.load(), [])
        let job = Job(name: "Work", sourcePath: "~/Documents/Work", destinations: [
            Destination(name: "USB", kind: .usbDrive(volumeName: "Backup2TB"), folder: "/backup/Work", mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 10)),
            Destination(name: "S3", kind: .s3(bucket: "mw-backups", region: "us-east-1", endpoint: nil), folder: "work/", mode: .fullOnly, enabled: false),
        ], createdAt: Date(timeIntervalSince1970: 1_792_000_000.5)) // dates are kept to the millisecond
        try store.save([job])
        XCTAssertEqual(try store.load(), [job])
    }
}

// MARK: - the sync preview and the run history (step 2)

final class HistoryAndPreviewTests: XCTestCase {
    func testDeclinedPreviewLeavesTheDestinationAlone() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        r.confirmSync = { _, plan in plan.copy.count == 0 }   // "no" the first time (one file to copy)
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .skipped("you chose not to go ahead after the preview"))
        XCTAssertEqual(readTree(dst), [:])
        XCTAssertTrue(report.allFine)
        r.confirmSync = { _, _ in true }
        let second = await r.run(job) { _ in }
        XCTAssertEqual(second.results[0].status, .finished)
        XCTAssertEqual(readTree(dst), ["a.txt": "A"])
    }

    func testHistoryKeepsNewestFirstAndCapped() throws {
        let s = Scratch()
        let h = RunHistory(url: s.root.appendingPathComponent("runs.json"), limit: 3)
        let jobId = UUID(), destId = UUID()
        func report(_ t: TimeInterval, _ status: DestinationStatus) -> RunReport {
            let d = Date(timeIntervalSince1970: t)
            return RunReport(jobId: jobId, jobName: "Work", startedAt: d, finishedAt: d.addingTimeInterval(5),
                             results: [DestinationResult(destinationId: destId, destinationName: "Dest", status: status, copied: 2, startedAt: d, finishedAt: d, backupFolder: "x", problems: ["p"])])
        }
        for i in 0..<5 { try h.append(report(1_792_000_000 + Double(i) * 60, i == 4 ? .skipped("off") : .failed("boom"))) }
        let runs = try h.load()
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.map(\.startedAt.timeIntervalSince1970), [1_792_000_240, 1_792_000_180, 1_792_000_120])
        XCTAssertEqual(runs.lastRun(of: jobId)?.results[0].status, .skipped("off"))
        XCTAssertEqual(runs.lastResult(for: destId)?.status, .failed("boom"))   // skipped doesn't count as a run
        XCTAssertEqual(runs[1].results[0].problems, ["p"])
        XCTAssertNil(runs.lastRun(of: UUID()))
    }
}

// MARK: - deleting backups and the restore checks (step 3)

final class BackupDeletionTests: XCTestCase {
    func testDependentsAndDeleteFromTheApp() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 10), title: "T")
        let clock = FixedClock(); let r = runner(clock)
        _ = await r.run(job, choices: [job.destinations[0].id: .full]) { _ in }           // full
        makeTree(src, ["b.txt": "B"]); clock.tick()
        _ = await r.run(job) { _ in }                                                       // inc 1
        makeTree(src, ["c.txt": "C"]); clock.tick()
        _ = await r.run(job) { _ in }                                                       // inc 2 (based on inc 1)
        let storage = LocalStorage(root: dst, describe: "dst")
        var catalog = try await BackupCatalog.load(from: storage)
        let full = catalog.entries.first { $0.parsed.kind == .full }!.folder
        let inc1 = catalog.entries.first { $0.manifest?.basedOn == full }!.folder
        let inc2 = catalog.entries.first { $0.manifest?.basedOn == inc1 }!.folder
        XCTAssertEqual(catalog.dependents(of: full).map(\.folder), [inc2, inc1])
        XCTAssertEqual(catalog.dependents(of: inc1).map(\.folder), [inc2])
        XCTAssertEqual(catalog.dependents(of: inc2), [])
        // delete the middle one: only inc 2 is stranded; the full still restores
        let stranded = try await RestoreEngine.delete(inc1, from: storage, catalog: catalog)
        XCTAssertEqual(stranded.map(\.folder), [inc2])
        catalog = try await BackupCatalog.load(from: storage)
        XCTAssertNil(catalog.entry(inc1))
        XCTAssertThrowsError(try RestoreEngine.plan(catalog, point: inc2))
        XCTAssertEqual(try RestoreEngine.plan(catalog, point: full).chain, [full])
        do { try await RestoreEngine.delete(inc1, from: storage, catalog: catalog); XCTFail("deleted twice") }
        catch let e as DSError { XCTAssertTrue(e.message.contains("isn't at the destination")) }
    }

    func testRestoreReportsAFreeSpaceCheck() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst"), target = s.dir("target")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .fullOnly, title: "T")
        _ = await runner(FixedClock()).run(job) { _ in }
        let storage = LocalStorage(root: dst, describe: "dst")
        let catalog = try await BackupCatalog.load(from: storage)
        let checks = Locked<[String]>([])
        let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: target, removeDeleted: true) { e in
            if case .check(let name, let ok, _) = e { checks.with { $0.append("\(name):\(ok)") } }
        }
        XCTAssertEqual(result.status, .finished)
        XCTAssertEqual(checks.with { $0 }, ["Free space:true"])
        XCTAssertEqual(readTree(target), ["a.txt": "A"])
    }
}

/// A tiny lock for collecting events from a @Sendable closure in tests.
final class Locked<T>: @unchecked Sendable {
    private var value: T; private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}
