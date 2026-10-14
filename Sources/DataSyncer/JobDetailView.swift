// The selected job: its name and last run, the source, the destinations (with their last run and an on/off
// switch), and the job's recent runs.
import SwiftUI
import DataSyncerCore

struct JobDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    let job: Job
    @State private var destinationToDelete: Destination?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                source
                destinations
                recentRuns
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // counted once per job (and again when its source changes); .task(id:) fires for every selected job
        .task(id: "\(job.id)|\(job.sourcePath)") { model.countSource(of: job) }
        .confirmationDialog("Remove the destination “\(destinationToDelete?.name ?? "")” from this job?", isPresented: Binding(get: { destinationToDelete != nil }, set: { if !$0 { destinationToDelete = nil } }), titleVisibility: .visible) {
            Button("Remove destination") { if let d = destinationToDelete { model.remove(d, from: job) }; destinationToDelete = nil }
            Button("Cancel", role: .cancel) { destinationToDelete = nil }.keyboardShortcut(.defaultAction)
        } message: {
            Text("Nothing at the destination is touched: the copies and backups there stay as they are.")
        }
    }

    private var header: some View {
        let last = Formatting.lastRunLine(model.history.lastRun(of: job.id))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(job.name).font(DS.title).lineLimit(1)
                Button("Rename…") { model.sheet = .editJob(job) }.buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
                Spacer()
                JobActions()
            }
            HStack(spacing: 8) { Dot(color: last.color); Text(last.text).foregroundStyle(.secondary) }
            if model.isRunning, !model.isRunning(job) {
                Text("Run… and Restore… are unavailable until \(model.runningName) finishes. You can still look around, edit a job or check destinations.")
                    .font(DS.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Source")
            Card(padding: 12) {
                HStack(spacing: DS.gap) {
                    IconTile(systemName: "folder.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.sourceURL.lastPathComponent).fontWeight(.semibold)
                        Text(Formatting.shortPath(job.sourcePath)).font(DS.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(job.sourcePath)
                    }
                    Spacer()
                    sourceStats
                    Button { NSWorkspace.shared.activateFileViewerSelecting([job.sourceURL]) } label: { Image(systemName: "folder") }
                        .help("Show in Finder").accessibilityLabel("Show the source in Finder")
                    Button("Change…") { pickSource() }
                }
            }
        }
    }

    @ViewBuilder private var sourceStats: some View {
        switch model.sourceStats[job.id]?.state {
        case .counted(let files, let bytes): Text("\(Formatting.count(files)) files · \(Formatting.bytes(bytes))").font(DS.secondary).foregroundStyle(.secondary)
        case .problem(let why):
            HStack(spacing: 6) { Dot(color: Theme.problem); Text(why).font(DS.secondary).lineLimit(2) }.frame(maxWidth: 360)
                .help(why)
        default: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("counting…").font(DS.secondary).foregroundStyle(.secondary) }
        }
    }

    private func pickSource() {
        if let url = FolderPicker.choose(title: "Choose the source folder", message: "The folder on this Mac that Data Syncer copies from.", start: job.sourceURL) {
            var j = job
            j.sourcePath = url.path
            model.update(j)
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Destinations", detail: job.destinations.count > 1 ? "\(job.destinations.count) · they run in this order" : nil)
                Spacer()
                Button { model.sheet = .newDestination(job) } label: { Label("Add destination", systemImage: "plus") }
                    .buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
            }
            if job.destinations.isEmpty {
                Card { Text("No destinations yet. Add a folder on this Mac, a USB drive, a share, a server or a cloud service to copy to.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                GroupedCard {
                    ForEach(Array(job.destinations.enumerated()), id: \.element.id) { i, d in
                        DestinationRow(job: job, destination: d, last: model.history.lastResult(for: d.id))
                            .contextMenu {
                                Button("Edit…") { model.sheet = .editDestination(job, d) }
                                Button(d.enabled ? "Turn off" : "Turn on") { model.setEnabled(!d.enabled, d, in: job) }
                                Divider()
                                Button("Move up") { model.move(d, in: job, by: -1) }.disabled(i == 0)
                                Button("Move down") { model.move(d, in: job, by: 1) }.disabled(i == job.destinations.count - 1)
                                if let url = Formatting.localURL(of: d) {
                                    Divider()
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                                Divider()
                                Button("Remove…", role: .destructive) { destinationToDelete = d }
                            }
                            .onTapGesture(count: 2) { model.sheet = .editDestination(job, d) }
                        if i < job.destinations.count - 1 { RowDivider(inset: 58) }
                    }
                }
            }
        }
    }

    private var recentRuns: some View {
        let all = model.history.filter { $0.jobId == job.id }
        let runs = all.prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Recent runs", detail: runs.isEmpty ? nil : "click one to see what happened")
                Spacer()
                if all.count > runs.count {
                    Button("See all \(all.count) runs") { model.settingsTab = "history"; openSettings() }.buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
                }
            }
            if runs.isEmpty {
                Card { Text("This job hasn't run yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                GroupedCard {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
                        let o = Formatting.outcome(run)
                        Button { model.sheet = .runDetails(run) } label: {
                            HStack(spacing: DS.gap) {
                                Dot(color: o.color)
                                Text(Formatting.When(run.startedAt)).frame(width: 140, alignment: .leading)
                                Text(run.results.filter { if case .skipped = $0.status { return false }; return true }.map(\.destinationName).joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(o.text).foregroundStyle(o.color).fontWeight(.medium).frame(width: 120, alignment: .leading)
                                Text(Formatting.duration(run.finishedAt.timeIntervalSince(run.startedAt))).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .font(DS.secondary)
                            .padding(.horizontal, DS.pad).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .help(Formatting.summary(of: run))
                        .accessibilityLabel("\(Formatting.When(run.startedAt)), \(o.text)")
                        if i < runs.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }
}

struct DestinationRow: View {
    @EnvironmentObject var model: AppModel
    let job: Job
    let destination: Destination
    let last: DestinationResult?

    var body: some View {
        let d = destination
        let badge = Theme.badge(d.mode)
        let status = d.enabled ? Formatting.lastRun(last, mode: d.mode) : ("Off" + (last.map { " · last run \(Formatting.when($0.finishedAt))" } ?? ""), Color.secondary)
        HStack(spacing: DS.gap) {
            IconTile(systemName: Formatting.icon(d.kind), color: d.enabled ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(d.name).fontWeight(.semibold)
                    Button("Edit…") { model.sheet = .editDestination(job, d) }.buttonStyle(.link).foregroundStyle(Theme.accent).font(DS.secondary)
                }
                Text(Formatting.place(d) + (model.accountLabel(d.kind).map { " · \($0)" } ?? "") + (d.copiesSourceFolder ? " · the folder itself" : ""))
                    .font(DS.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Badge(text: d.mode.label, fill: badge.fill, color: badge.text)
                Text(Formatting.modeNote(d.mode)).font(DS.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
            HStack(spacing: 8) {
                Dot(color: status.1)
                Text(status.0).font(DS.secondary).lineLimit(2)
            }
            .frame(width: 220, alignment: .leading)
            .help(last?.problems.joined(separator: "\n") ?? "")
            Toggle("", isOn: Binding(get: { d.enabled }, set: { model.setEnabled($0, d, in: job) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(d.enabled ? "On — this destination runs with the job" : "Off — skipped until you turn it on again")
                .accessibilityLabel("\(d.name) runs with the job")
        }
        .padding(.horizontal, DS.pad).padding(.vertical, 10)
        .opacity(d.enabled ? 1 : 0.65)
        .contentShape(Rectangle())
    }
}
