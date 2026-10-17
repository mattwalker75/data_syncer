import Foundation
import XCTest
@testable import DataSyncerCore

/// Matt's rule (Oct 16 2026): a restore goes only into an existing folder that is empty — dot files (.DS_Store)
/// don't count. The window and the restore engine both enforce it.
final class RestoreTargetTests: XCTestCase {
    func testOnlyAnExistingEmptyFolderIsAccepted() throws {
        let s = Scratch()
        let empty = s.dir("empty")
        XCTAssertNil(RestoreEngine.targetProblem(empty))

        let dotted = s.dir("dotted")
        try Data().write(to: dotted.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: dotted.appendingPathComponent(".hidden-folder"), withIntermediateDirectories: true)
        XCTAssertNil(RestoreEngine.targetProblem(dotted), "dot files don't block a restore")

        let full = s.dir("full")
        try Data("x".utf8).write(to: full.appendingPathComponent("notes.txt"))
        XCTAssertTrue(RestoreEngine.targetProblem(full)?.contains("isn't empty") == true)

        XCTAssertTrue(RestoreEngine.targetProblem(s.root.appendingPathComponent("missing"))?.contains("isn't there") == true)

        let file = s.root.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(RestoreEngine.targetProblem(file)?.contains("not a folder") == true)
    }

    func testTheRestoreItselfRefusesAFolderThatIsNotEmpty() async throws {
        let s = Scratch(); let src = s.dir("src"), dst = s.dir("dst")
        makeTree(src, ["a.txt": "A"])
        let job = localJob(source: src, dest: dst, mode: .fullOnly, title: "T")
        _ = await runner(FixedClock()).run(job) { _ in }
        let storage = LocalStorage(root: dst)
        let catalog = try await BackupCatalog.load(from: storage)

        let target = s.dir("restored")
        makeTree(target, ["mine.txt": "KEEP"])
        let refused = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: target, removeDeleted: true) { _ in }
        XCTAssertNotEqual(refused.status, .finished)
        XCTAssertEqual(readTree(target), ["mine.txt": "KEEP"], "nothing was written into it")

        let ok = s.dir("ok")
        try Data().write(to: ok.appendingPathComponent(".DS_Store"))
        let done = await RestoreEngine.restore(from: storage, catalog: catalog, point: catalog.entries[0].folder, to: ok, removeDeleted: true) { _ in }
        XCTAssertEqual(done.status, .finished, done.problems.joined(separator: "; "))
        XCTAssertEqual(readTree(ok)["a.txt"], "A")
    }
}
