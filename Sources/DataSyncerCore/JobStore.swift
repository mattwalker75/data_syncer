// The jobs file: every job and its destinations, as JSON in the app's own folder
// (~/Library/Application Support/Data Syncer/jobs.json). Written atomically; secrets never go in here —
// they live in the Keychain (step 5).
import Foundation

public struct JobsFile: Codable, Equatable, Sendable {
    public var version = 1
    public var jobs: [Job]
    public init(jobs: [Job] = []) { self.jobs = jobs }
}

public final class JobStore: @unchecked Sendable {
    public let url: URL

    /// The app's own folder, made on first use. DATASYNCER_HOME in the environment points it somewhere else
    /// (for trying the app out without touching the real jobs).
    public static func defaultURL() -> URL {
        let dir: URL
        if let home = ProcessInfo.processInfo.environment["DATASYNCER_HOME"], !home.isEmpty {
            dir = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = base.appendingPathComponent("Data Syncer", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs.json")
    }

    public init(url: URL = JobStore.defaultURL()) { self.url = url }

    public func load() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try Records.decoder.decode(JobsFile.self, from: Data(contentsOf: url)).jobs }
        catch { throw DSError("The jobs file \(url.path) could not be read: \(error.localizedDescription). Fix it, or move it aside to start with no jobs.") }
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Records.encoder.encode(JobsFile(jobs: jobs))
        try data.write(to: url, options: .atomic)
    }
}
