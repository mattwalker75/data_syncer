import XCTest
@testable import DataSyncerCore

final class NamingTests: XCTestCase {
    func testTitlesBecomeSafeFolderNames() {
        XCTAssertEqual(BackupNaming.sanitizeTitle("Work documents"), "Work_documents")
        XCTAssertEqual(BackupNaming.sanitizeTitle("  Photos / 2026: best!  "), "Photos_2026_best_")
        XCTAssertEqual(BackupNaming.sanitizeTitle(""), "backup")
    }

    func testFolderNamesRoundTrip() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 32))!
        let name = BackupNaming.folderName(kind: .full, title: "Work documents", date: date, calendar: cal)
        XCTAssertEqual(name, "2026_10_20_1432_Full_Work_documents")
        let parsed = BackupNaming.parse(name, calendar: cal)!
        XCTAssertEqual(parsed.kind, .full)
        XCTAssertEqual(parsed.title, "Work_documents")
        XCTAssertEqual(parsed.date, date)
        XCTAssertEqual(BackupNaming.parse("2026_10_20_1432_Incremental_X", calendar: cal)?.kind, .incremental)
        XCTAssertNil(BackupNaming.parse("Photos", calendar: cal))
        XCTAssertNil(BackupNaming.parse("2026_10_20_Full_X", calendar: cal))
    }
}

final class PlannerTests: XCTestCase {
    let file = FileMeta(size: 10, modified: 1_000)
    let dir = FileMeta(isDirectory: true)

    func testFirstSyncCopiesEverythingAndMakesFolders() {
        let plan = Planner.sync(source: ["a.txt": file, "sub": dir, "sub/b.txt": file], state: nil, destination: [:], deleteExtras: true)
        XCTAssertEqual(plan.makeDirs, ["sub"])
        XCTAssertEqual(plan.copy.map(\.path), ["a.txt", "sub/b.txt"])
        XCTAssertEqual(plan.bytes, 20)
        XCTAssertEqual(plan.delete, [])
    }

    func testUnchangedFilesAreLeftAlone() {
        let state = SyncState(files: ["a.txt": .init(written: file, source: file)])
        let plan = Planner.sync(source: ["a.txt": file], state: state, destination: ["a.txt": file], deleteExtras: true)
        XCTAssertEqual(plan.copy, [])
        XCTAssertEqual(plan.unchanged, 1)
        XCTAssertEqual(plan.summary, "nothing to do — already in sync")
    }

    func testAChangedSourceOrATamperedCopyIsCopiedAgain() {
        let state = SyncState(files: ["a.txt": .init(written: file, source: file), "b.txt": .init(written: file, source: file)])
        let changed = FileMeta(size: 11, modified: 2_000)
        let plan = Planner.sync(source: ["a.txt": changed, "b.txt": file], state: state,
                                destination: ["a.txt": file, "b.txt": FileMeta(size: 10, modified: 9_999)], deleteExtras: true)
        XCTAssertEqual(plan.copy.map(\.path), ["a.txt", "b.txt"])
    }

    func testModifiedTimesWithinTwoSecondsCountAsTheSame() {
        let state = SyncState(files: ["a.txt": .init(written: FileMeta(size: 10, modified: 1_001.5), source: file)])
        let plan = Planner.sync(source: ["a.txt": file], state: state, destination: ["a.txt": FileMeta(size: 10, modified: 1_001.5)], deleteExtras: true)
        XCTAssertEqual(plan.copy, [])
    }

    func testExtrasAreDeletedDeepestFirstOnlyWhenAsked() {
        let dest: Snapshot = ["a.txt": file, "old": dir, "old/x.txt": file, "old/deeper": dir, "old/deeper/y.txt": file]
        let on = Planner.sync(source: ["a.txt": file], state: nil, destination: dest, deleteExtras: true)
        XCTAssertEqual(on.delete, ["old/deeper/y.txt", "old/x.txt", "old/deeper", "old"])
        let off = Planner.sync(source: ["a.txt": file], state: nil, destination: dest, deleteExtras: false)
        XCTAssertEqual(off.delete, [])
    }

    func testAFullBackupCopiesEverything() {
        let plan = Planner.backup(kind: .full, folderName: "F", source: ["a.txt": file, "sub": dir, "sub/b.txt": file], parent: nil)
        XCTAssertEqual(plan.copy.count, 2)
        XCTAssertEqual(plan.makeDirs, ["sub"])
        XCTAssertNil(plan.basedOn)   // no parent folder given
        XCTAssertEqual(plan.deleted, [])
    }

    func testAnIncrementalCopiesOnlyChangesAndNotesDeletions() {
        let parent = Manifest(kind: .full, createdAt: Date(), jobName: "J", title: "T", basedOn: nil,
                              snapshot: ["a.txt": file, "gone.txt": file, "sub": dir, "sub/b.txt": file], copied: [], deleted: [], fileCount: 3, totalBytes: 30)
        let changed = FileMeta(size: 12, modified: 5_000)
        let plan = Planner.backup(kind: .incremental, folderName: "I", source: ["a.txt": changed, "new.txt": file, "sub": dir, "sub/b.txt": file], parent: parent)
        XCTAssertEqual(plan.copy.map(\.path), ["a.txt", "new.txt"])
        XCTAssertEqual(plan.unchanged, 1)
        XCTAssertEqual(plan.deleted, ["gone.txt"])
        XCTAssertEqual(plan.makeDirs, [])
    }
}
