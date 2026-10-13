// A run as the windows see it: built up from the runner's events, one destination at a time.
import Foundation
import DataSyncerCore

/// One destination's part of the run.
struct DestinationRun: Identifiable {
    enum Phase: Equatable { case waiting, running, done(DestinationStatus) }
    let destination: Destination
    var phase: Phase = .waiting
    var checks: [CheckItem] = []
    var plan: String = ""
    var progress = RunProgress()
    var copied = 0, deleted = 0, failed = 0, skipped = 0
    var result: DestinationResult?
    var id: Destination.ID { destination.id }

    var isRunning: Bool { phase == .running }
    var statusLabel: String {
        switch phase {
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .done(let s): return s.label
        }
    }
}

/// A line in the "Now" log.
struct LogLine: Identifiable {
    let id: Int
    let path: String
    let action: FileAction
    var text: String {
        switch action {
        case .copied: return "copied"
        case .linked: return "linked"
        case .madeFolder: return "folder made"
        case .deleted: return "deleted"
        case .skipped(let why): return "skipped — \(why)"
        case .failed(let why): return "failed — \(why)"
        }
    }
}

@MainActor
final class RunSession: ObservableObject, Identifiable {
    let id = UUID()
    let job: Job
    let startedAt = Date()
    @Published var destinations: [DestinationRun]
    @Published var log: [LogLine] = []
    @Published var report: RunReport?
    @Published var cancelRequested = false
    /// the destination being worked on
    @Published var currentId: Destination.ID?
    private var lineCount = 0
    private var lastProgressShown = Date.distantPast

    init(job: Job) {
        self.job = job
        destinations = job.destinations.map { d in
            var r = DestinationRun(destination: d)
            if !d.enabled { r.phase = .done(.skipped("turned off for this job")) }
            return r
        }
    }

    var isRunning: Bool { report == nil }
    var current: DestinationRun? { destinations.first { $0.id == currentId } }
    var enabledCount: Int { destinations.filter { $0.destination.enabled }.count }
    /// "destination 1 of 2", counting only the ones that run
    var position: Int {
        guard let currentId, let i = destinations.firstIndex(where: { $0.id == currentId }) else { return 0 }
        return destinations[...i].filter { $0.destination.enabled }.count
    }
    /// what comes after the current destination
    var next: DestinationRun? {
        guard let currentId, let i = destinations.firstIndex(where: { $0.id == currentId }) else { return nil }
        return destinations[(i + 1)...].first { $0.destination.enabled }
    }

    private func index(_ id: Destination.ID) -> Int? { destinations.firstIndex { $0.id == id } }

    func apply(_ event: RunEvent) {
        switch event {
        case .destinationStarted(let id, _):
            currentId = id
            if let i = index(id) { destinations[i].phase = .running }
        case .check(let id, let name, let ok, let detail):
            if let i = index(id) { destinations[i].checks.append(CheckItem(name: name, ok: ok, detail: detail)) }
        case .planned(let id, let summary):
            if let i = index(id) { destinations[i].plan = summary }
        case .progress(let id, let p):
            // progress arrives for every few MB; the window needs it ten times a second at most
            let now = Date()
            if p.currentPath.isEmpty || now.timeIntervalSince(lastProgressShown) > 0.1 {
                lastProgressShown = now
                if let i = index(id) { destinations[i].progress = p }
            }
        case .file(let id, let path, let action):
            if let i = index(id) {
                switch action {
                case .copied, .linked: destinations[i].copied += 1
                case .deleted: destinations[i].deleted += 1
                case .skipped: destinations[i].skipped += 1
                case .failed: destinations[i].failed += 1
                case .madeFolder: break
                }
            }
            if case .madeFolder = action { return }
            lineCount += 1
            log.append(LogLine(id: lineCount, path: path, action: action))
            if log.count > 400 { log.removeFirst(log.count - 400) }
        case .destinationFinished(let result):
            if let i = index(result.destinationId) {
                destinations[i].phase = .done(result.status)
                destinations[i].result = result
                if case .failed = result.status {} else { destinations[i].progress.currentPath = "" }
            }
        }
    }

    func finish(_ report: RunReport) {
        self.report = report
        currentId = nil
        // a run cancelled before a destination started leaves it "waiting"; say so
        for i in destinations.indices where destinations[i].phase == .waiting {
            destinations[i].phase = .done(.skipped(cancelRequested ? "the run was cancelled first" : "not reached"))
        }
    }
}
