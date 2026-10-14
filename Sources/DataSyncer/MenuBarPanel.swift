// The menu bar item (by the clock): a small panel that says whether a job is running and how far it is, shows
// the last run, starts a job, cancels the running one, opens the app, or quits it. No logs and no settings
// here — those are one click away in the app. It is part of the app, not a separate program: it appears when
// the app starts and goes when the app quits (the owner's decision: closing the window leaves the app in the
// Dock and the menu bar; Quit here ends everything).
import SwiftUI
import ServiceManagement
import DataSyncerCore

struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    @State private var confirmQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            Divider()
            lastRun
            Divider()
            runList
            Divider()
            HStack {
                Button { openApp() } label: { Label("Open Data Syncer", systemImage: "macwindow") }
                Spacer()
                if confirmQuit {
                    Text("A run is going.").font(DS.secondary).foregroundStyle(.secondary)
                    Button("Keep running") { confirmQuit = false }
                    Button("Quit anyway") { NSApp.terminate(nil) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Quit") { if model.isRunning { confirmQuit = true } else { NSApp.terminate(nil) } }
                        .help("Quits Data Syncer — the window and this menu bar item both go")
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .font(DS.body)
        .onDisappear { confirmQuit = false }
    }

    // MARK: what is happening now

    @ViewBuilder private var status: some View {
        if let s = model.session, s.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running \(s.job.name)").fontWeight(.semibold)
                    Spacer()
                    Button(s.cancelRequested ? "Cancelling…" : "Cancel") { model.cancelRun() }.disabled(s.cancelRequested).controlSize(.small)
                }
                if model.preview != nil {
                    Text("Waiting for your answer to a sync preview — open Data Syncer to see it.").font(DS.secondary).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
                } else if let c = s.current {
                    ProgressView(value: c.progress.fraction)
                    Text(detail(c, position: s.position, of: s.enabledCount)).font(DS.secondary).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Getting ready…").font(DS.secondary).foregroundStyle(.secondary)
                }
            }
        } else if let r = model.restoreSession, r.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Restoring \(r.job.name)").fontWeight(.semibold)
                    Spacer()
                    Button(r.cancelRequested ? "Cancelling…" : "Cancel") { model.cancelRun() }.disabled(r.cancelRequested).controlSize(.small)
                }
                ProgressView(value: r.progress.fraction)
                Text(r.progress.filesTotal > 0 ? "\(Formatting.count(r.progress.filesDone)) of \(Formatting.count(r.progress.filesTotal)) files" : "checking…")
                    .font(DS.secondary).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Dot(color: .secondary)
                Text("Nothing is running").fontWeight(.semibold)
                Spacer()
                Text("Data Syncer \(DataSyncerCore.version)").font(DS.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ c: DestinationRun, position: Int, of count: Int) -> String {
        var s = "\(c.destination.name) · destination \(max(position, 1)) of \(count)"
        let p = c.progress
        if p.filesTotal > 0 { s += " · \(Formatting.count(p.filesDone)) of \(Formatting.count(p.filesTotal)) files" }
        else if !c.plan.isEmpty { s += " · \(c.plan)" } else { s += " · checking…" }
        return s
    }

    // MARK: the last run

    @ViewBuilder private var lastRun: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last run").font(DS.secondary).foregroundStyle(.secondary)
            if let r = model.history.max(by: { $0.startedAt < $1.startedAt }) {
                let o = Formatting.outcome(r)
                HStack(spacing: 8) {
                    Dot(color: o.color)
                    Text("\(r.jobName) · \(o.text.lowercased()) · \(Formatting.when(r.finishedAt))").lineLimit(1)
                }
                .help(Formatting.summary(of: r))
            } else {
                HStack(spacing: 8) { Dot(color: .secondary); Text("No run yet").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: starting a job

    @ViewBuilder private var runList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run").font(DS.secondary).foregroundStyle(.secondary)
            if model.jobs.isEmpty {
                Text("No jobs yet — make one in Data Syncer.").foregroundStyle(.secondary)
            }
            ForEach(model.jobs) { job in
                let ready = !job.destinations.filter(\.enabled).isEmpty
                Button {
                    start(job)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(job.name).lineLimit(1)
                        Spacer()
                        Text(ready ? "\(job.destinations.filter(\.enabled).count) on" : "nothing on").font(DS.secondary).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall))
                .disabled(model.isRunning || !ready)
                .opacity(model.isRunning || !ready ? 0.5 : 1)
                .help(ready ? "Starts the job now. Full + incremental destinations get an incremental when the chain allows one; a sync destination shows its preview in the app first." : "This job has no destination turned on")
            }
            if !model.jobs.isEmpty {
                Text("Full + incremental: an incremental when the chain allows one, else a full. A sync shows its preview in the app before anything is copied or deleted.")
                    .font(DS.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func start(_ job: Job) {
        // a sync destination asks for a preview, and that answer is a deliberate click in the app
        if job.destinations.contains(where: { $0.enabled && { if case .sync = $0.mode { return true }; return false }($0) }) { openApp() }
        model.startFromMenuBar(job)
    }

    private func openApp() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The symbol in the menu bar: what the app is doing at a glance.
enum MenuBarIcon {
    @MainActor static func name(_ model: AppModel) -> String {
        if model.isRunning { return "arrow.triangle.2.circlepath" }
        if let r = model.history.max(by: { $0.startedAt < $1.startedAt }), Formatting.outcome(r).needsAttention { return "externaldrive.badge.exclamationmark" }
        return "externaldrive"
    }
}

/// "Open Data Syncer at login": the app in the menu bar from the moment you sign in. Nothing runs on its own.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS may need the user's say-so in System Settings → General → Login Items; the status says so
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
