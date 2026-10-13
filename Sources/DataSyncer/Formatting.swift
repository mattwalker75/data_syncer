// Words and colours the windows share: dates the way a person says them, sizes, durations, what each mode and
// kind is called, and the icon for each destination kind.
import SwiftUI
import DataSyncerCore

enum Formatting {
    /// "today 9:14", "yesterday 18:02", "Oct 11", "Sep 28, 2025"
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday \(time)" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Today 9:14", for the start of a sentence or a table row
    static func When(_ date: Date) -> String {
        let s = when(date)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func bytes(_ n: Int64) -> String { ByteCount.string(n) }

    static func count(_ n: Int) -> String { n.formatted(.number) }

    /// "4 min 12 s", "38 min", "1 h 12 min", "15 s"
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60, h = m / 60
        if h > 0 { return m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min" }
        if m >= 10 || s % 60 == 0 { return "\(m) min" }
        return "\(m) min \(s % 60) s"
    }

    /// The small note under a mode badge.
    static func modeNote(_ mode: DestinationMode) -> String {
        switch mode {
        case .sync(let deleteExtras): return deleteExtras ? "deletes what the source lost" : "keeps deleted files"
        case .fullOnly: return "a new full copy every run"
        case .fullIncremental(let start, let max):
            return "chain from \(start == .lastFull ? "last full" : "last incremental") · max \(max)"
        }
    }

    /// The location under a destination's name: the folder, the drive and folder, the share…
    static func place(_ d: Destination) -> String {
        switch d.kind {
        case .localFolder: return d.folder
        case .usbDrive: return "/" + d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .networkShare(let url): return url + (d.folder.isEmpty ? "" : "/" + d.folder)
        case .sftp(let host, _, _, _): return host + ":" + d.folder
        case .s3(_, let bucket, _, _): return bucket + "/" + d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .googleDrive, .dropbox, .oneDrive: return "/" + d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// "Incremental today 9:14 · 212 files · 1.1 GB" — a destination's last run, from the history.
    static func lastRun(_ r: DestinationResult?, mode: DestinationMode) -> (text: String, color: Color) {
        guard let r else { return ("Never run", .secondary) }
        let when = when(r.finishedAt)
        switch r.status {
        case .failed(let why): return ("Failed \(when) — \(why)", Theme.problem)
        case .cancelled: return ("Cancelled \(when)", Theme.attention)
        case .skipped: return ("Skipped \(when)", .secondary)
        case .finished, .finishedWithProblems:
            var text: String
            switch mode {
            case .sync: text = "Synced \(when) · \(count(r.copied)) copied" + (r.deleted > 0 ? ", \(count(r.deleted)) deleted" : "")
            default:
                let kind = (r.backupFolder.flatMap { BackupNaming.parse($0)?.kind } ?? .full) == .full ? "Full" : "Incremental"
                text = "\(kind) \(when) · \(count(r.copied)) files · \(bytes(r.bytes))"
            }
            if r.status == .finishedWithProblems { text += " · \(r.problems.count) problem\(r.problems.count == 1 ? "" : "s")" }
            return (text, r.status == .finished ? Theme.good : Theme.attention)
        }
    }

    /// The one line under a job's name: its last run.
    static func lastRunLine(_ report: RunReport?) -> (text: String, color: Color) {
        guard let report else { return ("Never run yet", .secondary) }
        let ran = report.results.filter { if case .skipped = $0.status { return false }; return true }
        let fine = ran.filter { $0.status == .finished }.count
        let when = "Last run \(when(report.startedAt))"
        let took = duration(report.finishedAt.timeIntervalSince(report.startedAt))
        if ran.isEmpty { return ("\(when) — nothing ran", .secondary) }
        if fine == ran.count {
            let n = ran.count == 1 ? "the destination" : (ran.count == 2 ? "both destinations" : "all \(ran.count) destinations")
            return ("\(when) — \(n) finished without problems · \(took)", Theme.good)
        }
        if ran.contains(where: { $0.status == .cancelled }) { return ("\(when) — cancelled · \(took)", Theme.attention) }
        let bad = ran.count - fine
        return ("\(when) — \(bad) of \(ran.count) destination\(ran.count == 1 ? "" : "s") had problems · \(took)", Theme.problem)
    }

    /// For a run's row in a table and the notification: "Finished", "1 problem", "Failed"
    static func outcome(_ report: RunReport) -> (text: String, color: Color) {
        let ran = report.results.filter { if case .skipped = $0.status { return false }; return true }
        if ran.isEmpty { return ("Nothing ran", .secondary) }
        if ran.allSatisfy({ $0.status == .finished }) { return ("Finished", Theme.good) }
        if ran.contains(where: { $0.status == .cancelled }) { return ("Cancelled", Theme.attention) }
        let problems = ran.reduce(0) { $0 + max($1.problems.count, $1.status == .finished ? 0 : 1) }
        return ("\(problems) problem\(problems == 1 ? "" : "s")", ran.contains { if case .failed = $0.status { return true }; return false } ? Theme.problem : Theme.attention)
    }

    /// The notification's body: one line per destination.
    static func summary(of report: RunReport) -> String {
        report.results.map(line(for:)).joined(separator: "\n")
    }

    /// One destination's outcome in a sentence.
    static func line(for r: DestinationResult) -> String {
        switch r.status {
        case .finished: return "\(r.destinationName): \(count(r.copied)) copied" + (r.deleted > 0 ? ", \(count(r.deleted)) deleted" : "")
        case .finishedWithProblems: return "\(r.destinationName): \(count(r.copied)) copied, \(r.problems.count) problem\(r.problems.count == 1 ? "" : "s")"
        case .failed(let why): return "\(r.destinationName): failed — \(why)"
        case .cancelled: return "\(r.destinationName): cancelled"
        case .skipped(let why): return "\(r.destinationName): skipped (\(why))"
        }
    }

    /// The symbol for a destination kind.
    static func icon(_ kind: DestinationKind) -> String {
        switch kind {
        case .localFolder: return "folder"
        case .usbDrive: return "externaldrive"
        case .networkShare: return "server.rack"
        case .sftp: return "terminal"
        case .s3: return "shippingbox"
        case .googleDrive, .dropbox, .oneDrive: return "cloud"
        }
    }
}

// MARK: - small shared views

/// "DESTINATIONS · 3"
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct Badge: View {
    let text: String
    let fill: Color
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2).background(fill, in: Capsule())
    }
}

struct CheckRow: View {
    let item: CheckItem
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.ok ? "checkmark" : "xmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(item.ok ? Theme.good : Theme.problem).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text(item.detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.font(.system(size: 12.5))
    }
}

/// A card with the mockups' 10-pt corners and hairline border.
struct Card<Content: View>: View {
    var tinted = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(tinted ? Color(nsColor: .controlBackgroundColor).opacity(0.6) : (Theme.cardTint?.opacity(0.35) ?? Color.clear), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
