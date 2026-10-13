// Running a job: the Run… sheet (full or incremental per destination), the run screen that takes the whole
// window, and the sync preview the run waits on.
import SwiftUI
import DataSyncerCore

// MARK: - before: what kind of backup, per destination

struct RunOptionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job
    enum Choice: String, CaseIterable, Identifiable { case auto = "Let Data Syncer choose", full = "Full", incremental = "Incremental"; var id: String { rawValue } }
    @State private var choices: [Destination.ID: Choice] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run “\(job.name)”").font(.title2).fontWeight(.bold)
            Text("Destinations run one after another, in this order. A destination that fails doesn't stop the next one.")
                .foregroundStyle(.secondary).font(.system(size: 12.5))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(job.destinations.enumerated()), id: \.element.id) { i, d in
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: Formatting.icon(d.kind)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(i + 1) · \(d.name)").fontWeight(.semibold)
                                Text(d.enabled ? what(d) : "off — skipped this run").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.enabled, case .fullIncremental = d.mode {
                                Picker("", selection: Binding(get: { choices[d.id] ?? .auto }, set: { choices[d.id] = $0 })) {
                                    ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
                                }.labelsHidden().frame(width: 200)
                            }
                        }
                    }.opacity(d.enabled ? 1 : 0.6)
                }
            }
            Text("“Let Data Syncer choose” makes an incremental when the chain allows one, otherwise a full backup. Sync destinations show a preview before anything is copied or deleted.")
                .foregroundStyle(.secondary).font(.system(size: 12))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func what(_ d: Destination) -> String {
        switch d.mode {
        case .sync(let del): return "Sync · " + (del ? "deletes what the source lost" : "keeps deleted files")
        case .fullOnly: return "Full only · a new dated folder"
        case .fullIncremental(let start, let max): return "Full + incremental · chain from \(start == .lastFull ? "last full" : "last incremental"), max \(max)"
        }
    }

    private func start() {
        var picks: [Destination.ID: BackupChoice] = [:]
        for (id, c) in choices {
            switch c { case .full: picks[id] = .full; case .incremental: picks[id] = .incremental; case .auto: break }
        }
        model.start(job, choices: picks)
    }
}

// MARK: - the run screen

struct RunScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RunSession

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                leftColumn.frame(width: 340)
                Divider()
                rightColumn
            }
        }
        .sheet(item: $model.preview) { SyncPreviewSheet(request: $0) }
    }

    private var titleBar: some View {
        HStack {
            Text("Run · \(session.job.name)").font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 8) {
                if session.isRunning {
                    Dot(color: Theme.accent)
                    Text("Running · destination \(max(session.position, 1)) of \(session.enabledCount) · started \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                } else if let r = session.report {
                    let o = Formatting.outcome(r)
                    Dot(color: o.color)
                    Text("\(o.text) · \(Formatting.duration(r.finishedAt.timeIntervalSince(r.startedAt)))")
                }
            }.foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Checks")
                    let checks = session.destinations.flatMap { d in d.checks.map { (d.destination.name, $0) } }
                    if checks.isEmpty { Text("Starting…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: c.1.ok ? "checkmark" : "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(c.1.ok ? Theme.good : Theme.problem).frame(width: 14)
                            Text("\(c.1.name == "Source" ? "" : c.0 + " · ")\(c.1.name): \(c.1.detail)").font(.system(size: 12)).lineLimit(4)
                        }
                        if !c.1.ok, c.1.detail.contains("Full Disk Access") {
                            Button("Give Data Syncer Full Disk Access…") { FullDiskAccess.openSettings() }.buttonStyle(.link).foregroundStyle(Theme.accent).font(.system(size: 12))
                                .help("Opens System Settings → Privacy & Security → Full Disk Access; add Data Syncer there, then run again")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Destinations")
                    ForEach(Array(session.destinations.enumerated()), id: \.element.id) { i, d in
                        destinationCard(i + 1, d)
                    }
                }
                Spacer(minLength: 0)
                Text(session.isRunning ? "Your Mac won't sleep while this runs. You'll get a notification and a summary when it finishes." : "")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func destinationCard(_ n: Int, _ d: DestinationRun) -> some View {
        let color: Color = {
            switch d.phase {
            case .waiting: return .secondary
            case .running: return Theme.accent
            case .done(let s):
                switch s { case .finished: return Theme.good; case .finishedWithProblems, .cancelled: return Theme.attention; case .failed: return Theme.problem; case .skipped: return .secondary }
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(n) · \(d.destination.name)").fontWeight(.semibold)
                Spacer()
                Badge(text: d.statusLabel, fill: color.opacity(0.14), color: color)
            }
            Text(d.plan.isEmpty ? Formatting.modeNote(d.destination.mode) : d.plan).font(.system(size: 12)).foregroundStyle(.secondary)
            if let f = d.result?.backupFolder { Text(f).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
            if case .done(let s) = d.phase {
                switch s {
                case .failed(let why), .skipped(let why): Text(why).font(.system(size: 12)).foregroundStyle(color)
                default: EmptyView()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(d.isRunning ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: d.isRunning ? 2 : 1))
    }

    private var rightColumn: some View {
        // the destination being worked on, or afterwards the last one that actually ran
        let shown = session.current ?? session.destinations.last { d in
            if case .done(let s) = d.phase { if case .skipped = s { return false }; return true }
            return false
        }
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline(shown)).font(.system(size: 20, weight: .bold))
                Text(subline(shown)).foregroundStyle(.secondary)
            }
            if let d = shown {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: session.isRunning ? d.progress.fraction : 1)
                    HStack {
                        Text(progressText(d)).font(.system(size: 12.5))
                        Spacer()
                    }
                }
                HStack(spacing: 12) {
                    tile("Copied", d.copied)
                    tile("Unchanged", d.result?.unchanged ?? planUnchanged(d))
                    tile(isSync(d) ? "Deleted" : "Deleted since", d.result?.deleted ?? d.deleted)
                    tile("Problems", d.failed + d.skipped)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(session.isRunning ? "Now" : "What happened")
                logView
            }
            if let r = session.report { summary(r) }
            HStack {
                Spacer()
                if session.isRunning {
                    Button("Back to jobs") { model.showJobs() }
                    Button(session.cancelRequested ? "Cancelling…" : "Cancel") { model.cancelRun() }.disabled(session.cancelRequested)
                } else {
                    Button("Back to jobs") { model.dismissRun() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.log) { line in
                        HStack(spacing: 6) {
                            Text(line.path).lineLimit(1).truncationMode(.middle)
                            Text(line.text).foregroundStyle(lineColor(line.action))
                        }
                        .font(.system(size: 12, design: .monospaced)).id(line.id)
                    }
                    if session.isRunning, let c = session.current, !c.progress.currentPath.isEmpty {
                        HStack(spacing: 6) {
                            Text(c.progress.currentPath).lineLimit(1).truncationMode(.middle)
                            Text("copying…")
                        }.font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).id(-1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.log.count) { _, _ in withAnimation(nil) { proxy.scrollTo(session.isRunning ? -1 : session.log.last?.id, anchor: .bottom) } }
            .onChange(of: session.current?.progress.currentPath ?? "") { _, _ in withAnimation(nil) { proxy.scrollTo(-1, anchor: .bottom) } }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func summary(_ r: RunReport) -> some View {
        let o = Formatting.outcome(r)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) { Dot(color: o.color); Text(o.text).fontWeight(.semibold).foregroundStyle(o.color) }
            ForEach(r.results, id: \.destinationId) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatting.line(for: d)).font(.system(size: 12.5))
                    ForEach(d.problems.prefix(10), id: \.self) { Text("   \($0)").font(.system(size: 12)).foregroundStyle(Theme.attention).textSelection(.enabled) }
                    if d.problems.count > 10 { Text("   …and \(d.problems.count - 10) more").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func tile(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Formatting.count(n)).font(.system(size: 20, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func isSync(_ d: DestinationRun) -> Bool { if case .sync = d.destination.mode { return true }; return false }

    private func planUnchanged(_ d: DestinationRun) -> Int {
        // "copy 212, delete 3 · 12,268 unchanged" → 12268, until the result arrives
        guard let r = d.plan.range(of: #"(\d[\d,]*) unchanged"#, options: .regularExpression) else { return 0 }
        return Int(d.plan[r].split(separator: " ")[0].replacingOccurrences(of: ",", with: "")) ?? 0
    }

    private func headline(_ d: DestinationRun?) -> String {
        guard let d else { return session.isRunning ? "Getting ready…" : "Finished" }
        let verb = isSync(d) ? "Syncing to" : "Backing up to"
        if session.isRunning, d.isRunning { return "\(verb) \(d.destination.name)" }
        return "\(d.destination.name): \(d.statusLabel.lowercased())"
    }

    private func subline(_ d: DestinationRun?) -> String {
        guard let d else { return "Checking the source and the first destination." }
        if !d.plan.isEmpty { return d.plan }
        return d.isRunning ? "Checking and planning…" : Formatting.modeNote(d.destination.mode)
    }

    private func progressText(_ d: DestinationRun) -> String {
        let p = d.progress
        if session.isRunning, d.isRunning {
            guard p.filesTotal > 0 else { return "Planning…" }
            var s = "\(Formatting.count(p.filesDone)) of \(Formatting.count(p.filesTotal)) files"
            if p.bytesTotal > 0 { s += " · \(Formatting.bytes(p.bytesDone)) of \(Formatting.bytes(p.bytesTotal))" }
            return s
        }
        if let r = d.result { return "\(Formatting.count(r.copied)) copied · \(Formatting.bytes(r.bytes)) · \(Formatting.duration(r.duration))" }
        return ""
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

// MARK: - the sync preview

struct SyncPreviewSheet: View {
    let request: SyncPreviewRequest

    var body: some View {
        let plan = request.plan
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync to \(request.destination.name)").font(.title2).fontWeight(.bold)
            Text(plan.summary.prefix(1).uppercased() + plan.summary.dropFirst()).fontWeight(.medium)
            if plan.copy.isEmpty && plan.delete.isEmpty && plan.makeDirs.isEmpty {
                Text("Nothing needs copying or deleting — the destination already matches the source.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    column("Copy · \(Formatting.count(plan.copy.count)) · \(Formatting.bytes(plan.bytes))", plan.copy.map(\.path), Theme.good)
                    column("Delete at the destination · \(Formatting.count(plan.delete.count))", plan.delete, Theme.problem)
                }
                .frame(height: 300)
            }
            if !plan.delete.isEmpty {
                Text("Deleting is on for this destination: files the source no longer has are removed from the copy. Turn it off in the destination's settings to keep them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Skip this destination") { request.answer(false) }.keyboardShortcut(.cancelAction)
                Button("Go ahead") { request.answer(true) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 720)
        .interactiveDismissDisabled()
    }

    private func column(_ title: String, _ paths: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { Dot(color: color); Text(title).font(.system(size: 12, weight: .semibold)) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(paths.prefix(2000), id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
                    if paths.count > 2000 { Text("…and \(Formatting.count(paths.count - 2000)) more").foregroundStyle(.secondary).font(.system(size: 12)) }
                    if paths.isEmpty { Text("nothing").foregroundStyle(.secondary).font(.system(size: 12)) }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(maxWidth: .infinity)
    }
}
