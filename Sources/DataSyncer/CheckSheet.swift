// "Check destinations": the source and every destination that is turned on, checked without copying anything.
import SwiftUI
import DataSyncerCore

struct CheckSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var source: CheckItem?
    @State private var results: [Destination.ID: DestinationCheck] = [:]
    @State private var running = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Checking “\(job.name)”").font(.title2).fontWeight(.bold)
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let source {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Source")
                            CheckRow(item: source)
                            if !source.ok, source.detail.contains("Full Disk Access") {
                                Button("Open Privacy & Security settings…") { FullDiskAccess.openSettings() }.buttonStyle(.link).foregroundStyle(Theme.accent).font(.system(size: 12.5))
                            }
                        }
                    }
                    ForEach(job.destinations) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SectionLabel(d.name)
                                if !d.enabled { Text("off — skipped").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                            if let r = results[d.id] {
                                ForEach(r.items) { CheckRow(item: $0) }
                                if case .fullIncremental = d.mode, !r.incrementalNote.isEmpty {
                                    CheckRow(item: CheckItem(name: "Next backup", ok: true, detail: r.canIncremental ? r.incrementalNote : r.incrementalNote + " The next backup must be a full one."))
                                }
                            } else if d.enabled {
                                Text("waiting…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(verdict).foregroundStyle(.secondary).font(.system(size: 12.5))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .task { await check() }
    }

    private var verdict: String {
        if running { return "Checking…" }
        let checked = job.destinations.filter(\.enabled)
        let bad = checked.filter { results[$0.id]?.ok == false }.count + ((source?.ok == false) ? 1 : 0)
        if bad == 0 { return checked.isEmpty ? "No destination is turned on." : "Everything is ready." }
        return "\(bad) thing\(bad == 1 ? "" : "s") to look at before running."
    }

    private func check() async {
        source = Preflight.checkSource(job)
        for d in job.destinations where d.enabled {
            let r = await Preflight.check(job, d, factory: DefaultStorageFactory(accounts: model.accountStore), otherJobIds: model.otherJobIds(job))
            results[d.id] = r
        }
        running = false
    }
}

enum FullDiskAccess {
    /// System Settings → Privacy & Security → Full Disk Access.
    @MainActor static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
}
