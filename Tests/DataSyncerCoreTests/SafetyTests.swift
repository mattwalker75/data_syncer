// The rules that keep user data safe, each with the scenario that would have lost it.
import Foundation
import XCTest
@testable import DataSyncerCore

/// A local storage whose uploads can be held until the test says go — for deterministic cancellation tests.
final class GatedStorage: Storage, @unchecked Sendable {
    let inner: LocalStorage
    let holdAfter: Int
    private var uploads = 0
    private let lock = NSLock()
    let held = Locked(false)
    var describe: String { inner.describe }
    var keepsModifiedDates: Bool { true }
    init(_ inner: LocalStorage, holdAfter: Int) { self.inner = inner; self.holdAfter = holdAfter }
    func checkReachable() async throws { try await inner.checkReachable() }
    func exists(_ p: RelPath) async throws -> Bool { try await inner.exists(p) }
    func stat(_ p: RelPath) async throws -> FileMeta? { try await inner.stat(p) }
    func list(_ d: RelPath) async throws -> [Entry] { try await inner.list(d) }
    func makeDirectory(_ p: RelPath) async throws { try await inner.makeDirectory(p) }
    func remove(_ p: RelPath) async throws { try await inner.remove(p) }
    func upload(localURL: URL, to path: RelPath, meta: FileMeta, progress: (@Sendable (Int64) -> Void)?) async throws {
        lock.lock(); uploads += 1; let n = uploads; lock.unlock()
        if n > holdAfter {
            held.value = true
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        }
        try await inner.upload(localURL: localURL, to: path, meta: meta, progress: progress)
    }
    func download(_ p: RelPath, to l: URL, meta: FileMeta) async throws { try await inner.download(p, to: l, meta: meta) }
    func readData(_ p: RelPath) async throws -> Data { try await inner.readData(p) }
    func writeData(_ d: Data, to p: RelPath) async throws { try await inner.writeData(d, to: p) }
    func freeSpace() async throws -> Int64? { try await inner.freeSpace() }
    func makeSymlink(_ p: RelPath, target: String) async throws { try await inner.makeSymlink(p, target: target) }
    func walk(_ dir: RelPath) async throws -> Snapshot { try await inner.walk(dir) }
    func applyDirectoryMeta(_ p: RelPath, meta: FileMeta) async throws { try await inner.applyDirectoryMeta(p, meta: meta) }
}

struct GatedFactory: StorageFactory {
    let holdAfter: Int
    let gate: Locked<GatedStorage?>
    func storage(for d: Destination) async throws -> Storage {
        let g = GatedStorage(LocalStorage(root: URL(fileURLWithPath: d.folder, isDirectory: true)), holdAfter: holdAfter)
        gate.value = g
        return g
    }
}

final class SafetyTests: XCTestCase {
    func chmod(_ url: URL, _ mode: Int) { try! FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }

    // 1. an unreadable source subfolder is not "deleted"
    func testUnreadableSourceSubfolderIsNeverTreatedAsDeleted() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A", "Private/secret.txt": "S", "Private/more/deep.txt": "D"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        _ = await r.run(job) { _ in }
        XCTAssertEqual(readTree(dst)["Private/secret.txt"], "S")
        chmod(src.appendingPathComponent("Private"), 0o000)
        defer { chmod(src.appendingPathComponent("Private"), 0o755) }
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .finishedWithProblems)
        XCTAssertEqual(report.results[0].deleted, 0)
        XCTAssertEqual(readTree(dst)["Private/secret.txt"], "S", "the copy must survive an unreadable source")
        XCTAssertEqual(readTree(dst)["Private/more/deep.txt"], "D")
        XCTAssertTrue(report.results[0].problems.contains { $0.contains("not deleted at the destination") })
        // the same for an incremental: nothing under Private is recorded as deleted
        let bjob = localJob(source: src, dest: s.dir("bk"), mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5), title: "T")
        chmod(src.appendingPathComponent("Private"), 0o755)
        let clock = FixedClock(); let rr = runner(clock)
        _ = await rr.run(bjob, choices: [bjob.destinations[0].id: .full]) { _ in }
        chmod(src.appendingPathComponent("Private"), 0o000); clock.tick()
        let inc = await rr.run(bjob) { _ in }
        XCTAssertEqual(inc.results[0].deleted, 0)
        let catalog = try await BackupCatalog.load(from: LocalStorage(root: s.dir("bk")))
        XCTAssertEqual(catalog.entries.first?.manifest?.deleted, [])
    }

    // 2. a file a backup could not copy is caught up by the next incremental, and a restore says it is missing
    func testFailedBackupCopyIsCaughtUpByTheNextIncremental() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["ok.txt": "O", "locked.txt": "L"])
        chmod(src.appendingPathComponent("locked.txt"), 0o000)
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5), title: "T")
        let clock = FixedClock(); let r = runner(clock)
        let full = await r.run(job, choices: [job.destinations[0].id: .full]) { _ in }
        XCTAssertEqual(full.results[0].status, .finishedWithProblems)
        let storage = LocalStorage(root: dst)
        var catalog = try await BackupCatalog.load(from: storage)
        XCTAssertEqual(catalog.entries[0].manifest?.failed, ["locked.txt"])
        XCTAssertNil(catalog.entries[0].manifest?.snapshot["locked.txt"], "a file that wasn't copied is not in the snapshot")
        // a restore of the full says what is missing
        let plan = try RestoreEngine.plan(catalog, point: catalog.entries[0].folder)
        XCTAssertEqual(plan.missing, ["locked.txt"])
        // readable again, nothing else changed: the incremental copies it
        chmod(src.appendingPathComponent("locked.txt"), 0o644); clock.tick()
        let inc = await r.run(job) { _ in }
        XCTAssertEqual(inc.results[0].status, .finished)
        XCTAssertEqual(inc.results[0].copied, 1)
        catalog = try await BackupCatalog.load(from: storage)
        XCTAssertEqual(catalog.entries[0].manifest?.copied, ["locked.txt"])
        let target = s.dir("restored")
        let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: target, removeDeleted: true) { _ in }
        XCTAssertEqual(result.status, .finished)
        XCTAssertEqual(readTree(target), ["ok.txt": "O", "locked.txt": "L"])
    }

    // 3. a link at the destination is never written through
    func testWritesNeverEscapeThroughALink() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst"), outside = s.dir("outside")
        makeTree(outside, ["real.txt": "KEEP"])
        makeTree(src, ["Shared": "@" + outside.path])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        _ = await r.run(job) { _ in }
        XCTAssertEqual(readTree(dst)["Shared"], "@" + outside.path)
        // the link becomes a real folder in the source
        try FileManager.default.removeItem(at: src.appendingPathComponent("Shared"))
        makeTree(src, ["Shared/a.txt": "A"])
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .finished, report.results[0].problems.joined(separator: "; "))
        XCTAssertEqual(readTree(dst), ["Shared": "<dir>", "Shared/a.txt": "A"])
        XCTAssertEqual(readTree(outside), ["real.txt": "KEEP"], "nothing outside the destination may change")
        // and the storage itself refuses a path that resolves outside, even if asked directly
        try FileManager.default.removeItem(at: dst.appendingPathComponent("Shared"))
        try FileManager.default.createSymbolicLink(atPath: dst.appendingPathComponent("Shared").path, withDestinationPath: outside.path)
        let st = LocalStorage(root: dst)
        do { try await st.upload(localURL: src.appendingPathComponent("Shared/a.txt"), to: "Shared/real.txt", meta: FileMeta(size: 1), progress: nil); XCTFail() }
        catch let e as DSError { XCTAssertTrue(e.message.contains("outside the destination"), e.message) }
        do { try await st.remove("Shared/real.txt"); XCTFail() } catch let e as DSError { XCTAssertTrue(e.message.contains("outside")) }
        XCTAssertEqual(readTree(outside), ["real.txt": "KEEP"])
    }

    // 3b. the same in a restore
    func testRestoreNeverEscapesThroughALink() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst"), outside = s.dir("outside")
        makeTree(outside, ["real.txt": "KEEP"])
        makeTree(src, ["x": "@" + outside.path])
        let job = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5), title: "T")
        let clock = FixedClock(); let r = runner(clock)
        _ = await r.run(job, choices: [job.destinations[0].id: .full]) { _ in }
        try FileManager.default.removeItem(at: src.appendingPathComponent("x"))
        makeTree(src, ["x/a.txt": "A", "x/real.txt": "R"]); clock.tick()
        _ = await r.run(job) { _ in }
        let storage = LocalStorage(root: dst)
        let catalog = try await BackupCatalog.load(from: storage)
        let target = s.dir("restored")
        let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: target, removeDeleted: true) { _ in }
        XCTAssertEqual(result.status, .finished, result.problems.joined(separator: "; "))
        XCTAssertEqual(readTree(target), ["x": "<dir>", "x/a.txt": "A", "x/real.txt": "R"])
        XCTAssertEqual(readTree(outside), ["real.txt": "KEEP"])
    }

    // 4. a case-only rename keeps the file
    func testCaseOnlyRenameKeepsTheFile() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["docs/Plan.md": "P", "Docs2/x.txt": "X"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        _ = await r.run(job) { _ in }
        try FileManager.default.moveItem(at: src.appendingPathComponent("docs/Plan.md"), to: src.appendingPathComponent("docs/plan.md"))
        try FileManager.default.moveItem(at: src.appendingPathComponent("Docs2"), to: src.appendingPathComponent("docs2"))
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .finished, report.results[0].problems.joined(separator: "; "))
        let tree = readTree(dst)
        XCTAssertEqual(tree["docs/plan.md"], "P")
        XCTAssertEqual(tree["docs2/x.txt"], "X")
        XCTAssertEqual(Set(tree.keys), ["docs", "docs/plan.md", "docs2", "docs2/x.txt"])
        // the names at the destination have the new case
        let names = try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0 != ".datasyncer" }
        XCTAssertEqual(Set(names), ["docs", "docs2"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.appendingPathComponent("docs").path), ["plan.md"])
        // a third run has nothing to do
        let again = await r.run(job) { _ in }
        XCTAssertEqual(again.results[0].copied, 0); XCTAssertEqual(again.results[0].deleted, 0)
    }

    // 5. the old copy survives a failed or cancelled copy
    func testOldCopySurvivesAFailedCopy() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "OLD"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        _ = await r.run(job) { _ in }
        makeTree(src, ["a.txt": "NEW-BUT-UNREADABLE"], modified: Date().addingTimeInterval(100))
        chmod(src.appendingPathComponent("a.txt"), 0o000)
        defer { chmod(src.appendingPathComponent("a.txt"), 0o644) }
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .finishedWithProblems)
        XCTAssertEqual(readTree(dst)["a.txt"], "OLD", "the only good copy must not be removed before the new one is readable")
        XCTAssertFalse(readTree(dst).keys.contains { $0.contains("datasyncer-part") }, "no part file left behind")
    }

    func testCancelMidSyncKeepsTheOldFileAndSavesTheRecord() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A1", "b.txt": "B1"])
        let gate = Locked<GatedStorage?>(nil)
        let r = JobRunner(factory: GatedFactory(holdAfter: 100, gate: gate))
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        _ = await r.run(job) { _ in }
        makeTree(src, ["a.txt": "A2", "b.txt": "B2"], modified: Date().addingTimeInterval(100))
        let r2 = JobRunner(factory: GatedFactory(holdAfter: 1, gate: gate))
        let task = Task { await r2.run(job) { _ in } }
        while gate.value?.held.value != true { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.results[0].status, .cancelled)
        XCTAssertEqual(report.results[0].copied, 1)
        let tree = readTree(dst)
        XCTAssertEqual(tree["a.txt"], "A2")
        XCTAssertEqual(tree["b.txt"], "B1", "the held file keeps its old copy")
        let state = try await Records.loadSyncState(from: LocalStorage(root: dst))
        XCTAssertEqual(state?.files["a.txt"]?.source.size, 2, "the record was saved on the way out")
    }

    func testCancelledBackupLeavesNoHalfFolderDeterministically() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A", "b.txt": "B", "c.txt": "C"])
        let gate = Locked<GatedStorage?>(nil)
        let r = JobRunner(factory: GatedFactory(holdAfter: 1, gate: gate))
        let job = localJob(source: src, dest: dst, mode: .fullOnly)
        let task = Task { await r.run(job) { _ in } }
        while gate.value?.held.value != true { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.results[0].status, .cancelled)
        XCTAssertFalse(readTree(dst).keys.contains { $0.contains("_Full_") }, "the half-made backup is gone before the run reports")
    }

    // 7. a file that becomes a folder, and a folder that becomes a file
    func testTypeChangesSyncAndRestore() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["thing": "FILE", "box/inner.txt": "I"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: false))
        let r = runner(FixedClock())
        _ = await r.run(job) { _ in }
        try FileManager.default.removeItem(at: src.appendingPathComponent("thing"))
        try FileManager.default.removeItem(at: src.appendingPathComponent("box"))
        makeTree(src, ["thing/now.txt": "N", "box": "NOW A FILE"])
        let report = await r.run(job) { _ in }
        XCTAssertEqual(report.results[0].status, .finished, report.results[0].problems.joined(separator: "; "))
        XCTAssertEqual(readTree(dst), ["thing": "<dir>", "thing/now.txt": "N", "box": "NOW A FILE"])
        // the same through a chain restore
        let bk = s.dir("bk")
        let bjob = localJob(source: src, dest: bk, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5), title: "T")
        try FileManager.default.removeItem(at: src.appendingPathComponent("thing")); try FileManager.default.removeItem(at: src.appendingPathComponent("box"))
        makeTree(src, ["thing": "FILE", "box/inner.txt": "I"])
        let clock = FixedClock(); let rr = runner(clock)
        _ = await rr.run(bjob, choices: [bjob.destinations[0].id: .full]) { _ in }
        try FileManager.default.removeItem(at: src.appendingPathComponent("thing")); try FileManager.default.removeItem(at: src.appendingPathComponent("box"))
        makeTree(src, ["thing/now.txt": "N", "box": "NOW A FILE"]); clock.tick()
        _ = await rr.run(bjob) { _ in }
        let storage = LocalStorage(root: bk)
        let catalog = try await BackupCatalog.load(from: storage)
        let target = s.dir("restored")
        let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: target, removeDeleted: true) { _ in }
        XCTAssertEqual(result.status, .finished, result.problems.joined(separator: "; "))
        XCTAssertEqual(readTree(target), ["thing": "<dir>", "thing/now.txt": "N", "box": "NOW A FILE"])
    }

    // 36. an obvious wipe is refused without a preview, and flagged with one
    func testObviousWipeIsRefusedWithoutAPreview() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        _ = await r.run(job) { _ in }
        try FileManager.default.removeItem(at: src.appendingPathComponent("a.txt"))
        let report = await r.run(job) { _ in }
        if case .failed(let why) = report.results[0].status { XCTAssertTrue(why.contains("no files at all"), why) } else { XCTFail("\(report.results[0].status)") }
        XCTAssertEqual(readTree(dst)["a.txt"], "A")
        // with a preview the warning is in the plan and the user decides
        let seen = Locked<String?>(nil)
        r.confirmSync = { _, plan in seen.value = plan.warning; return false }
        _ = await r.run(job) { _ in }
        XCTAssertTrue(seen.value?.contains("no files at all") ?? false)
        // a plan that deletes most of a sizeable destination is flagged too
        var many: [String: String] = [:]; for i in 0..<30 { many["f\(i).txt"] = "x" }
        makeTree(src, many)
        _ = await r.run(job) { _ in }   // declined (returns false), so copy by hand for the test
        r.confirmSync = nil
        _ = await r.run(job) { _ in }
        for i in 0..<25 { try FileManager.default.removeItem(at: src.appendingPathComponent("f\(i).txt")) }
        let big = await r.run(job) { _ in }
        if case .failed(let why) = big.results[0].status { XCTAssertTrue(why.contains("25 of the 30"), why) } else { XCTFail("\(big.results[0].status)") }
    }

    // 17. one folder, two jobs
    func testAFolderUsedByAnotherJobIsRefused() async throws {
        let s = Scratch(); let srcA = s.dir("srcA"), srcB = s.dir("srcB"), dst = s.dir("dst")
        makeTree(srcA, ["a.txt": "A"]); makeTree(srcB, ["b.txt": "B"])
        let jobA = localJob(name: "Photos", source: srcA, dest: dst, mode: .sync(deleteExtras: true))
        let jobB = localJob(name: "Documents", source: srcB, dest: dst, mode: .sync(deleteExtras: true))
        let r = runner(FixedClock())
        r.otherJobIds = { job in job.id == jobA.id ? [jobB.id] : [jobA.id] }
        _ = await r.run(jobA) { _ in }
        let b = await r.run(jobB) { _ in }
        if case .failed(let why) = b.results[0].status { XCTAssertTrue(why.contains("Photos"), why) } else { XCTFail("\(b.results[0].status)") }
        XCTAssertEqual(readTree(dst)["a.txt"], "A", "job A's files are untouched")
        // the check says so too
        let check = await Preflight.check(jobB, jobB.destinations[0], otherJobIds: [jobA.id])
        XCTAssertTrue(check.items.contains { $0.name == "Folder in use" && !$0.ok })
        // job A gone: B takes the folder over
        r.otherJobIds = { _ in [] }
        let taken = await r.run(jobB) { _ in }
        XCTAssertEqual(taken.results[0].status, .finished)
        let record = try await Records.loadDestinationRecord(from: LocalStorage(root: dst))
        XCTAssertEqual(record?.jobName, "Documents")
    }

    // 17b. another job's backups in the same folder are not part of this one's chain
    func testCatalogIsFilteredByTitle() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let mine = localJob(source: src, dest: dst, mode: .fullIncremental(chainStart: .lastIncremental, maxIncrementals: 5), title: "Mine")
        let clock = FixedClock(); let r = runner(clock)
        _ = await r.run(mine, choices: [mine.destinations[0].id: .full]) { _ in }
        // a stray full of another title appears (made by hand or another job)
        clock.tick()
        try FileManager.default.createDirectory(at: dst.appendingPathComponent(BackupNaming.folderName(kind: .full, title: "Other", date: clock.date)), withIntermediateDirectories: true)
        clock.tick()
        let inc = await r.run(mine) { _ in }
        XCTAssertEqual(inc.results[0].status, .finished)
        let storage = LocalStorage(root: dst)
        let all = try await BackupCatalog.load(from: storage)
        let justMine = try await BackupCatalog.load(from: storage, title: "Mine")
        XCTAssertEqual(all.entries.count, 3); XCTAssertEqual(justMine.entries.count, 2)
        XCTAssertTrue(justMine.entries[0].manifest?.basedOn?.contains("_Full_Mine") ?? false)
    }

    // 10. a cancelled run still lists every destination
    func testCancelledRunListsEveryDestination() async throws {
        let s = Scratch(); let src = s.dir("src")
        makeTree(src, ["a.txt": "A", "b.txt": "B"])
        let gate = Locked<GatedStorage?>(nil)
        let r = JobRunner(factory: GatedFactory(holdAfter: 1, gate: gate))
        var job = localJob(source: src, dest: s.dir("d1"), mode: .fullOnly)
        job.destinations.append(Destination(name: "Second", kind: .localFolder, folder: s.dir("d2").path, mode: .fullOnly))
        let task = Task { await r.run(job) { _ in } }
        while gate.value?.held.value != true { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.results.count, 2)
        XCTAssertEqual(report.results[0].status, .cancelled)
        XCTAssertEqual(report.results[1].status, .skipped("the run was cancelled before this destination"))
    }

    // 41. folders keep their dates and permissions
    func testFoldersKeepDatesAndPermissions() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["box/inner.txt": "I"])
        let box = src.appendingPathComponent("box")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: when, .posixPermissions: 0o750], ofItemAtPath: box.path)
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        _ = await runner(FixedClock()).run(job) { _ in }
        let m = LocalStorage.meta(at: dst.appendingPathComponent("box"))!
        XCTAssertEqual(m.modified, 1_700_000_000); XCTAssertEqual(m.permissions, 0o750)
    }

    // 15. the check leaves no trace and reports a corrupt record
    func testCheckLeavesNoTraceAndReportsACorruptRecord() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .sync(deleteExtras: true))
        _ = await Preflight.check(job, job.destinations[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent(".datasyncer").path), "a check must not create the records folder")
        _ = await runner(FixedClock()).run(job) { _ in }
        try Data("not json".utf8).write(to: dst.appendingPathComponent(".datasyncer/sync-state.json"))
        let check = await Preflight.check(job, job.destinations[0])
        XCTAssertTrue(check.items.contains { $0.name == "Last sync" && !$0.ok && $0.detail.contains("could not be read") })
    }
}
