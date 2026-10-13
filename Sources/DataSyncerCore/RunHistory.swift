// The run history: every run's report, newest first, as JSON beside the jobs file
// (~/Library/Application Support/Data Syncer/runs.json). The main window's "Recent runs", the sidebar's
// "ran today 9:14" and each destination's "Synced Oct 11 · 212 copied" come from here. Capped so it never grows
// without end; the user can clear it in Settings.
import Foundation

public struct RunHistoryFile: Codable, Equatable, Sendable {
    public var version = 1
    public var runs: [RunReport]
    public init(runs: [RunReport] = []) { self.runs = runs }
}

public final class RunHistory: @unchecked Sendable {
    public let url: URL
    /// how many runs are kept (the newest)
    public let limit: Int

    public static func defaultURL() -> URL {
        JobStore.defaultURL().deletingLastPathComponent().appendingPathComponent("runs.json")
    }

    public init(url: URL = RunHistory.defaultURL(), limit: Int = 500) { self.url = url; self.limit = limit }

    /// Newest first. An unreadable file is reported, not fatal: the app runs with an empty history.
    public func load() throws -> [RunReport] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try Records.decoder.decode(RunHistoryFile.self, from: Data(contentsOf: url)).runs }
        catch { throw DSError("The run history \(url.path) could not be read: \(error.localizedDescription). It will be started afresh.") }
    }

    public func save(_ runs: [RunReport]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let kept = Array(runs.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
        try Records.encoder.encode(RunHistoryFile(runs: kept)).write(to: url, options: .atomic)
    }

    /// Adds a report and saves; returns the new list (newest first).
    @discardableResult
    public func append(_ report: RunReport) throws -> [RunReport] {
        var runs = (try? load()) ?? []
        runs.insert(report, at: 0)
        try save(runs)
        return Array(runs.prefix(limit))
    }
}

public extension Array where Element == RunReport {
    /// The newest run of a job.
    func lastRun(of jobId: Job.ID) -> RunReport? { first { $0.jobId == jobId } }

    /// The newest result for a destination that actually ran (skipped ones don't count as a run).
    func lastResult(for destinationId: Destination.ID) -> DestinationResult? {
        for run in self {
            if let r = run.results.first(where: { $0.destinationId == destinationId }) {
                if case .skipped = r.status { continue }
                return r
            }
        }
        return nil
    }
}
