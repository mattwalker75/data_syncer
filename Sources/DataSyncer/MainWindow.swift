// The main window (Theme 1 "Sidebar"): jobs down the left, the selected job on the right, Run / Check / Restore
// in the toolbar, New job and the Settings gear at the bottom of the sidebar. While a job runs, a strip under
// the toolbar shows where it is, with Watch and Cancel run; the run screen takes the whole window. When it
// finishes the strip stays until the summary has been seen or dismissed.
import SwiftUI
import DataSyncerCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if model.screen == .run, let session = model.session {
                RunScreen(session: session)
            } else if model.screen == .restore, let session = model.restoreSession {
                RestoreScreen(session: session)
            } else {
                jobsScreen
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newJob: JobEditor(job: nil)
            case .editJob(let job): JobEditor(job: job)
            case .newDestination(let job): DestinationEditor(job: job, destination: nil)
            case .editDestination(let job, let d): DestinationEditor(job: job, destination: d)
            case .check(let job): CheckSheet(job: job)
            case .runOptions(let job): RunOptionsSheet(job: job)
            case .restore(let job): RestoreSheet(job: job)
            case .runDetails(let report): RunDetailsSheet(report: report)
            }
        }
        // the sync preview belongs to the window, not the run screen: it must appear whichever screen is showing
        .sheet(item: $model.preview) { SyncPreviewSheet(request: $0) }
        .alert(item: $model.notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK")))
        }
        .onAppear(perform: placeWindowForDevelopment)
    }

    /// development only: DATASYNCER_WINDOW=x,y,w,h puts the window there (screen coordinates, origin top-left)
    private func placeWindowForDevelopment() {
        if ProcessInfo.processInfo.environment["DATASYNCER_AUTOSHEET"]?.hasPrefix("settings") == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSettings() }
        }
        guard let spec = ProcessInfo.processInfo.environment["DATASYNCER_WINDOW"] else { return }
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4, let screen = NSScreen.screens.first, let window = NSApp.windows.first(where: { $0.title == "Data Syncer" }) ?? NSApp.windows.first else { return }
        let y = screen.frame.height - n[1] - n[3]
        DispatchQueue.main.async { window.setFrame(NSRect(x: n[0], y: y, width: n[2], height: n[3]), display: true) }
    }

    private var jobsScreen: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let session = model.session { RunningStrip(session: session) }
                if let restore = model.restoreSession { RestoringStrip(session: restore) }
                if let job = model.selectedJob {
                    JobDetailView(job: job)
                } else {
                    EmptyJobs()
                }
            }
            .navigationTitle("Data Syncer")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.checkDestinations() } label: { Label("Check destinations", systemImage: "checkmark") }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.selectedJob == nil)
                    .help("See that every destination is reachable and writable, without copying anything")
                Button { model.askToRestore() } label: { Label("Restore…", systemImage: "arrow.counterclockwise") }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.selectedJob == nil || model.isRunning)
                    .help(model.isRunning ? "Restore… is unavailable until \(model.runningName) finishes" : "Put a full or incremental backup back into a folder you choose")
                Button { model.askToRun() } label: { Label("Run…", systemImage: "play.fill") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRun)
                    .help(model.isRunning ? "Run… is unavailable until \(model.runningName) finishes" : "Run this job")
            }
        }
    }
}

// MARK: - the sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var jobToDelete: Job?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedJobId) {
                Section("Jobs") {
                    ForEach(model.jobs) { job in
                        SidebarRow(job: job)
                            .tag(job.id)
                            .contextMenu {
                                Button("Rename or change the source…") { model.sheet = .editJob(job) }
                                Button("Duplicate") { model.duplicate(job) }
                                Button("Run…") { model.selectedJobId = job.id; model.askToRun() }.disabled(model.isRunning)
                                Divider()
                                Button("Delete…", role: .destructive) { jobToDelete = job }.disabled(model.isRunning(job))
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(Theme.sidebarTint == nil ? .automatic : .hidden)
            .background(Theme.sidebarTint?.opacity(0.25) ?? Color.clear)
            .onDeleteCommand { if let j = model.selectedJob, !model.isRunning(j) { jobToDelete = j } }
            Divider()
            HStack {
                Button { model.newJob() } label: { Label("New job", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).fontWeight(.medium)
                Spacer()
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Settings")
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .confirmationDialog("Delete the job “\(jobToDelete?.name ?? "")”?", isPresented: Binding(get: { jobToDelete != nil }, set: { if !$0 { jobToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete job", role: .destructive) { if let j = jobToDelete { model.delete(j) }; jobToDelete = nil }
            Button("Cancel", role: .cancel) { jobToDelete = nil }
        } message: {
            Text("Only the job is removed from Data Syncer. Nothing at its source or destinations is touched; the backups stay where they are.")
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let job: Job

    var body: some View {
        let running = model.isRunning(job)
        let last = model.history.lastRun(of: job.id)
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(job.name).fontWeight(.medium).lineLimit(1)
                    if !running, let last, Formatting.outcome(last).needsAttention { Dot(color: Theme.attention, size: 7) }
                }
                if running, let s = model.session {
                    Text(runningText(s)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                } else {
                    Text(subtitle(last)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if running { Spacer(); ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ last: RunReport?) -> String {
        let n = job.destinations.count
        var s = "\(n) destination\(n == 1 ? "" : "s")"
        if let last {
            let o = Formatting.outcome(last)
            s += o.needsAttention ? " · needs attention" : " · \(o.text == "Cancelled" ? "cancelled" : "ran") \(Formatting.when(last.startedAt))"
        } else {
            s += " · never run"
        }
        return s
    }

    private func runningText(_ s: RunSession) -> String {
        if model.preview != nil { return "Waiting for your answer" }
        guard let c = s.current else { return "Running…" }
        return "Running · \(c.destination.name) \(Int(c.progress.fraction * 100))%"
    }
}

// MARK: - the strip while a job runs, and after it finishes

struct RunningStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RunSession

    var body: some View {
        HStack(spacing: 14) {
            if session.isRunning {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).fontWeight(.semibold).foregroundStyle(Theme.accent)
                    HStack(spacing: 10) {
                        ProgressView(value: session.current?.progress.fraction ?? 0).frame(width: 260)
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // a preview waiting behind another sheet (Check, an editor) appears once that sheet closes
                Button(model.preview != nil ? "Answer" : "Watch") { if model.preview != nil { model.sheet = nil } else { model.watchRun() } }.buttonStyle(.borderedProminent).controlSize(.regular)
                Button(session.cancelRequested ? "Cancelling…" : "Cancel run") { model.cancelRun() }.disabled(session.cancelRequested)
            } else if let r = session.report {
                let o = Formatting.outcome(r)
                Dot(color: o.color)
                Text("\(session.job.name) \(o.text == "Finished" ? "finished" : "finished — \(o.text.lowercased())") · \(Formatting.duration(r.finishedAt.timeIntervalSince(r.startedAt)))")
                    .fontWeight(.semibold).foregroundStyle(o.color)
                Spacer()
                Button("See summary") { model.watchRun() }.buttonStyle(.borderedProminent)
                Button("Dismiss") { model.session = nil }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(session.isRunning ? Theme.accent.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var headline: String {
        if let p = model.preview { return "\(session.job.name) is waiting for your answer — the preview for \(p.destination.name)" }
        guard let c = session.current else { return "\(session.job.name) is running — getting ready" }
        let verb: String
        if case .sync = c.destination.mode { verb = "syncing to" } else { verb = "backing up to" }
        return "\(session.job.name) is running — \(verb) \(c.destination.name), destination \(session.position) of \(session.enabledCount)"
    }

    private var detail: String {
        guard let c = session.current else { return "" }
        let p = c.progress
        var s = p.filesTotal > 0 ? "\(Formatting.count(p.filesDone)) of \(Formatting.count(p.filesTotal)) files" : "checking…"
        if p.bytesTotal > 0 { s += " · \(Formatting.bytes(p.bytesDone)) of \(Formatting.bytes(p.bytesTotal))" }
        if let next = session.next { s += " · then \(next.destination.name)" }
        return s
    }
}

/// The strip while a restore runs, and after it finishes.
struct RestoringStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RestoreSession

    var body: some View {
        HStack(spacing: 14) {
            if session.isRunning {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restoring \(session.job.name) from \(session.destination.name) into \(session.target.lastPathComponent)" + (session.applying.map { " — backup \($0.index) of \($0.of)" } ?? ""))
                        .fontWeight(.semibold).foregroundStyle(Theme.accent)
                    HStack(spacing: 10) {
                        ProgressView(value: session.progress.fraction).frame(width: 260)
                        Text(session.progress.filesTotal > 0 ? "\(Formatting.count(session.progress.filesDone)) of \(Formatting.count(session.progress.filesTotal)) files" : "checking…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Watch") { model.watchRun() }.buttonStyle(.borderedProminent)
                Button(session.cancelRequested ? "Cancelling…" : "Cancel restore") { model.cancelRun() }.disabled(session.cancelRequested)
            } else {
                Dot(color: session.outcome.color)
                Text("Restore of \(session.job.name) \(session.outcome.sentence)").fontWeight(.semibold).foregroundStyle(session.outcome.color)
                Spacer()
                Button("See summary") { model.watchRun() }.buttonStyle(.borderedProminent)
                Button("Dismiss") { model.restoreSession = nil }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(session.isRunning ? Theme.accent.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct EmptyJobs: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            if model.jobs.isEmpty {
                Image(systemName: "folder.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("No jobs yet").font(.title2).fontWeight(.semibold)
                Text("A job copies one folder on this Mac to one or more destinations, when you run it.\nMake your first one to get started.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("New job…") { model.newJob() }.buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "sidebar.left").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Choose a job on the left").font(.title2).fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - a past run's details

struct RunDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: RunReport

    var body: some View {
        let o = Formatting.outcome(report)
        VStack(alignment: .leading, spacing: 14) {
            Text("\(report.jobName) — \(Formatting.When(report.startedAt))").font(.title2).fontWeight(.bold)
            HStack(spacing: 8) {
                Dot(color: o.color); Text(o.text).fontWeight(.semibold).foregroundStyle(o.color)
                Text("· \(Formatting.duration(report.finishedAt.timeIntervalSince(report.startedAt)))").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(report.results, id: \.destinationId) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Formatting.line(for: d)).fontWeight(.medium)
                            if let f = d.backupFolder { Text(f).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                            if d.unchanged > 0 || d.skipped > 0 {
                                Text("\(Formatting.count(d.unchanged)) unchanged · \(Formatting.count(d.skipped)) skipped · \(Formatting.bytes(d.bytes)) · \(Formatting.duration(d.duration))").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(Array(d.problems.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 12)).foregroundStyle(Theme.attention).textSelection(.enabled) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy report") {
                    let text = ([report.jobName + " — " + Formatting.When(report.startedAt) + " — " + o.text] + report.results.flatMap { [Formatting.line(for: $0)] + $0.problems.map { "   " + $0 } }).joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}
