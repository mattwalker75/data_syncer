// The selected job: its name and last run, the source, the destinations (with their last run and an on/off
// switch), and the job's recent runs.
import SwiftUI
import DataSyncerCore

struct JobDetailView: View {
    @EnvironmentObject var model: AppModel
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
        .onAppear { model.countSource(of: job) }
        .onChange(of: job.sourcePath) { _, _ in model.countSource(of: job, force: true) }
        .confirmationDialog("Remove the destination “\(destinationToDelete?.name ?? "")” from this job?", isPresented: Binding(get: { destinationToDelete != nil }, set: { if !$0 { destinationToDelete = nil } }), titleVisibility: .visible) {
            Button("Remove destination", role: .destructive) { if let d = destinationToDelete { model.remove(d, from: job) }; destinationToDelete = nil }
            Button("Cancel", role: .cancel) { destinationToDelete = nil }
        } message: {
            Text("Nothing at the destination is touched: the copies and backups there stay as they are.")
        }
    }

    private var header: some View {
        let last = Formatting.lastRunLine(model.history.lastRun(of: job.id))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(job.name).font(.system(size: 24, weight: .bold))
                Button("Edit…") { model.sheet = .editJob(job) }.buttonStyle(.link).font(.system(size: 12.5))
            }
            HStack(spacing: 8) { Dot(color: last.color); Text(last.text) }.foregroundStyle(.primary)
            if model.isRunning, model.session?.job.id != job.id {
                Text("Run… is unavailable until \(model.session?.job.name ?? "the running job") finishes. You can still look around, edit a job or check destinations.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var source: some View {
        Card(tinted: true) {
            HStack(spacing: 14) {
                Image(systemName: "folder").font(.system(size: 24)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Source")
                    Text(job.sourcePath).font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                sourceStats
                Button("Change…") { pickSource() }
            }
        }
    }

    @ViewBuilder private var sourceStats: some View {
        switch model.sourceStats[job.id]?.state {
        case .counted(let files, let bytes): Text("\(Formatting.count(files)) files · \(Formatting.bytes(bytes))")
        case .problem(let why):
            HStack(spacing: 6) { Dot(color: Theme.problem); Text(why).lineLimit(2) }.frame(maxWidth: 360)
                .help(why)
        default: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("counting…").foregroundStyle(.secondary) }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Destinations · \(job.destinations.count)")
                Spacer()
                Button { model.sheet = .newDestination(job) } label: { Label("Add destination", systemImage: "plus") }
                    .buttonStyle(.link)
            }
            if job.destinations.isEmpty {
                Card { Text("No destinations yet. Add a folder on this Mac or a USB drive to copy to.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
            ForEach(job.destinations) { d in
                DestinationRow(job: job, destination: d, last: model.history.lastResult(for: d.id))
                    .contextMenu {
                        Button("Edit…") { model.sheet = .editDestination(job, d) }
                        Button(d.enabled ? "Turn off" : "Turn on") { model.setEnabled(!d.enabled, d, in: job) }
                        Divider()
                        Button("Remove…", role: .destructive) { destinationToDelete = d }
                    }
                    .onTapGesture(count: 2) { model.sheet = .editDestination(job, d) }
            }
        }
    }

    private var recentRuns: some View {
        let runs = model.history.filter { $0.jobId == job.id }.prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Recent runs")
            if runs.isEmpty {
                Text("This job hasn't run yet.").foregroundStyle(.secondary).font(.system(size: 12.5))
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.startedAt) { i, run in
                        let o = Formatting.outcome(run)
                        GridRow {
                            Text(Formatting.When(run.startedAt)).gridColumnAlignment(.leading)
                            Text(run.results.filter { if case .skipped = $0.status { return false }; return true }.map(\.destinationName).joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
                            Text(o.text).foregroundStyle(o.color).fontWeight(.semibold)
                            Text(Formatting.duration(run.finishedAt.timeIntervalSince(run.startedAt))).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12.5))
                        .padding(.vertical, 7)
                        .help(Formatting.summary(of: run))
                        if i < runs.count - 1 { Divider() }
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
        let status = d.enabled ? Formatting.lastRun(last, mode: d.mode) : ("Paused" + (last.map { " · last run \(Formatting.when($0.finishedAt))" } ?? ""), Color.secondary)
        Card {
            HStack(spacing: 14) {
                Image(systemName: Formatting.icon(d.kind)).font(.system(size: 20)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).fontWeight(.semibold)
                    Text(Formatting.place(d)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Badge(text: d.mode.label, fill: badge.fill, color: badge.text)
                    Text(Formatting.modeNote(d.mode)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(width: 180, alignment: .leading)
                HStack(spacing: 8) {
                    Dot(color: status.1)
                    Text(status.0).font(.system(size: 12.5)).lineLimit(2)
                }
                .frame(width: 240, alignment: .leading)
                .help(last?.problems.joined(separator: "\n") ?? "")
                Toggle("", isOn: Binding(get: { d.enabled }, set: { model.setEnabled($0, d, in: job) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(d.enabled ? "On — this destination runs with the job" : "Off — skipped until you turn it on again")
            }
        }
        .opacity(d.enabled ? 1 : 0.6)
    }
}
