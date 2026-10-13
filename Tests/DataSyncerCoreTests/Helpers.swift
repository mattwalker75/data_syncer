// Throwaway folders for the tests: build a tree from a dictionary, read one back, and a fixed clock.
import Foundation
import XCTest
@testable import DataSyncerCore

final class Scratch {
    let root: URL
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ds-test-" + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func dir(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Write files: ["a.txt": "hello", "sub/b.txt": "x"]. A value ending in "/" makes an empty folder; "@target" makes a link.
func makeTree(_ root: URL, _ files: [String: String], modified: Date? = nil) {
    let fm = FileManager.default
    for (path, content) in files {
        let url = root.appendingPathComponent(path)
        if path.hasSuffix("/") { try! fm.createDirectory(at: url, withIntermediateDirectories: true); continue }
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if content.hasPrefix("@") { try! fm.createSymbolicLink(atPath: url.path, withDestinationPath: String(content.dropFirst())); continue }
        try! Data(content.utf8).write(to: url)
        if let modified { try! fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }
}

/// Read a tree back as path → content ("<dir>" for folders, "@target" for links), skipping .datasyncer records.
func readTree(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    let fm = FileManager.default
    let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.producesRelativePathURLs])!
    for case let url as URL in e {
        let rel = url.relativePath
        if rel == ".datasyncer" || rel.hasPrefix(".datasyncer/") || rel.contains("/.datasyncer") { e.skipDescendants(); continue }
        let v = try! url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if v.isSymbolicLink == true { out[rel] = "@" + (try! fm.destinationOfSymbolicLink(atPath: url.path)) }
        else if v.isDirectory == true { out[rel] = "<dir>" }
        else { out[rel] = String(data: try! Data(contentsOf: url), encoding: .utf8) ?? "<binary>" }
    }
    return out
}

func modified(_ url: URL) -> Date {
    (try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date)
}

/// A job with one local-folder destination.
func localJob(name: String = "Work", source: URL, dest: URL, mode: DestinationMode, enabled: Bool = true, title: String = "") -> Job {
    Job(name: name, sourcePath: source.path, destinations: [
        Destination(name: "Dest", kind: .localFolder, folder: dest.path, mode: mode, enabled: enabled, backupTitle: title),
    ])
}

/// A runner whose clock the test controls (each call to `tick` moves it a minute).
final class FixedClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14
    func tick(minutes: Int = 1) { date = date.addingTimeInterval(Double(minutes) * 60) }
}

func runner(_ clock: FixedClock) -> JobRunner {
    let r = JobRunner()
    r.now = { clock.date }
    return r
}

extension RunReport {
    var first: DestinationResult { results[0] }
}
