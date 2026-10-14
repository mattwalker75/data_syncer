// A restore as the window sees it, and the screen that shows it (the run screen's shape, for one destination).
import SwiftUI
import DataSyncerCore

@MainActor
final class RestoreSession: ObservableObject, Identifiable {
    let id = UUID()
    let job: Job
    let destination: Destination
    let point: String
    let target: URL
    let startedAt = Date()
    @Published var checks: [CheckItem] = []
    @Published var plan: RestorePlan?
    @Published var applying: (index: Int, of: Int, backup: String)?
    @Published var progress = RunProgress()
    @Published var log: [LogLine] = []
    @Published var restored = 0
    @Published var removed = 0
    @Published var failed = 0
    @Published var result: RestoreResult?
    @Published var cancelRequested = false
    private var lineCount = 0
    private var lastProgressShown = Date.distantPast

    init(job: Job, destination: Destination, point: String, target: URL) {
        self.job = job; self.destination = destination; self.point = point; self.target = target
    }

    var isRunning: Bool { result == nil }

    func apply(_ event: RestoreEvent) {
        switch event {
        case .check(let name, let ok, let detail): checks.append(CheckItem(name: name, ok: ok, detail: detail))
        case .planned(let p): plan = p
        case .applying(let backup, let index, let of): applying = (index, of, backup)
        case .progress(let p):
            let now = Date()
            if p.currentPath.isEmpty || now.timeIntervalSince(lastProgressShown) > 0.1 { lastProgressShown = now; progress = p }
        case .file(let path, let action):
            switch action {
            case .copied, .linked: restored += 1
            case .deleted: removed += 1
            case .failed, .skipped: failed += 1
            case .madeFolder: return
            }
            lineCount += 1
            log.append(LogLine(id: lineCount, path: path, action: action))
            if log.count > 400 { log.removeFirst(log.count - 400) }
        }
    }

    func finish(_ r: RestoreResult) { result = r; progress.currentPath = "" }

    struct Outcome { var text: String; var color: Color; var sentence: String }
    var outcome: Outcome {
        guard let r = result else { return Outcome(text: "Restoring", color: Theme.accent, sentence: "is going") }
        switch r.status {
        case .finished: return Outcome(text: "Finished", color: Theme.good, sentence: "finished")
        case .finishedWithProblems:
            let n = r.problems.count
            return Outcome(text: "\(n) problem\(n == 1 ? "" : "s")", color: Theme.attention, sentence: "finished with \(n) problem\(n == 1 ? "" : "s")")
        case .cancelled: return Outcome(text: "Cancelled", color: Theme.attention, sentence: "was cancelled")
        case .failed: return Outcome(text: "Failed", color: Theme.problem, sentence: "failed")
        case .skipped: return Outcome(text: "Skipped", color: .secondary, sentence: "was skipped")
        }
    }
    /// did the backup being applied when the restore stopped get through?
    var currentApplied: Bool {
        guard let r = result else { return false }
        return r.status == .finished || r.status == .finishedWithProblems
    }
}

struct RestoreScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RestoreSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Restore · \(session.job.name) from \(session.destination.name)").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 8) {
                    Dot(color: session.outcome.color)
                    if session.isRunning, let a = session.applying { Text("Restoring · backup \(a.index) of \(a.of) · started \(session.startedAt.formatted(date: .omitted, time: .shortened))") }
                    else if let r = session.result { Text("\(session.outcome.text) · \(Formatting.duration(r.finishedAt.timeIntervalSince(r.startedAt)))") }
                    else { Text("Checking…") }
                }.foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 52)
            Divider()
            HStack(spacing: 0) {
                left.frame(width: 340)
                Divider()
                right
            }
        }
    }

    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Checks")
                    CheckRow(item: CheckItem(name: "Restore point", ok: true, detail: session.point))
                    CheckRow(item: CheckItem(name: "Into", ok: true, detail: session.target.path))
                    ForEach(session.checks) { CheckRow(item: $0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Backups to apply, in order")
                    if let p = session.plan {
                        ForEach(Array(p.chain.enumerated()), id: \.offset) { i, folder in
                            let state: (String, Color) = {
                                guard let a = session.applying else { return ("Waiting", .secondary) }
                                if i + 1 < a.index || (!session.isRunning && i + 1 == a.index && session.currentApplied) { return ("Applied", Theme.good) }
                                if i + 1 == a.index { return (session.isRunning ? "Applying" : session.outcome.text, session.isRunning ? Theme.accent : session.outcome.color) }
                                return ("Waiting", .secondary)
                            }()
                            HStack {
                                Text("\(i + 1) · \(folder)").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Badge(text: state.0, fill: state.1.opacity(0.14), color: state.1)
                            }
                            .padding(10)
                            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(state.0 == "Applying" ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: state.0 == "Applying" ? 2 : 1))
                        }
                    } else {
                        Text("Working out the chain…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                if session.isRunning {
                    Text("Your Mac won't sleep while this runs.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.isRunning ? "Restoring into \(session.target.lastPathComponent)" : "Restore \(session.outcome.sentence)").font(.system(size: 20, weight: .bold))
                Text(session.plan?.summary ?? "Checking the destination and the folder to restore into.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: session.isRunning ? session.progress.fraction : 1)
                Text(progressText).font(.system(size: 12.5))
            }
            HStack(spacing: 12) {
                tile("Restored", session.restored)
                tile("Removed", session.removed)
                tile("Problems", session.failed)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(session.isRunning ? "Now" : "What happened")
                logView
            }
            if let r = session.result {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) { Dot(color: session.outcome.color); Text(session.outcome.text).fontWeight(.semibold).foregroundStyle(session.outcome.color) }
                    if case .failed(let why) = r.status { Text(why).font(.system(size: 12.5)).textSelection(.enabled) }
                    ForEach(Array(r.problems.prefix(10).enumerated()), id: \.offset) { Text($0.element).font(.system(size: 12)).foregroundStyle(Theme.attention).textSelection(.enabled) }
                    if r.problems.count > 10 { Text("…and \(r.problems.count - 10) more").font(.system(size: 12)).foregroundStyle(.secondary) }
                    if r.status == .finished { Text("The files are in \(session.target.path).").font(.system(size: 12.5)) }
                }
            }
            HStack {
                Spacer()
                if session.isRunning {
                    Button("Back to jobs") { model.showJobs() }
                    Button(session.cancelRequested ? "Cancelling…" : "Cancel") { model.cancelRun() }.disabled(session.cancelRequested)
                } else {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.target]) }
                    Button("Back to jobs") { model.dismissRestore() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var progressText: String {
        let p = session.progress
        if session.isRunning {
            guard p.filesTotal > 0 else { return "Planning…" }
            return "\(Formatting.count(p.filesDone)) of \(Formatting.count(p.filesTotal)) files · \(Formatting.bytes(p.bytesDone)) of \(Formatting.bytes(p.bytesTotal))"
        }
        if let r = session.result { return "\(Formatting.count(r.restored)) restored · \(Formatting.count(r.removed)) removed · \(Formatting.duration(r.finishedAt.timeIntervalSince(r.startedAt)))" }
        return ""
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.log) { line in
                        HStack(spacing: 6) {
                            Text(line.path).lineLimit(1).truncationMode(.middle)
                            Text(line.text == "copied" ? "restored" : line.text).foregroundStyle(lineColor(line.action))
                        }.font(.system(size: 12, design: .monospaced)).id(line.id)
                    }
                    if session.isRunning, !session.progress.currentPath.isEmpty {
                        HStack(spacing: 6) { Text(session.progress.currentPath).lineLimit(1).truncationMode(.middle); Text("restoring…") }
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).id(-1)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.log.count) { _, _ in withAnimation(nil) { proxy.scrollTo(session.isRunning ? -1 : session.log.last?.id, anchor: .bottom) } }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func tile(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Formatting.count(n)).font(.system(size: 20, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lineColor(_ a: FileAction) -> Color {
        switch a {
        case .copied, .linked, .madeFolder: return Theme.good
        case .deleted: return .secondary
        case .skipped: return Theme.attention
        case .failed: return Theme.problem
        }
    }
}
