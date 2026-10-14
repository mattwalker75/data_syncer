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
        case .localFolder: return shortPath(d.folder)
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
                text = "\(kind) \(when) · \(count(r.copied)) file\(r.copied == 1 ? "" : "s") · \(bytes(r.bytes))"
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

    struct Outcome { var text: String; var color: Color; var needsAttention: Bool }

    /// For a run's row in a table and the notification: "Finished", "1 problem", "Failed"
    static func outcome(_ report: RunReport) -> Outcome {
        let ran = report.results.filter { if case .skipped = $0.status { return false }; return true }
        if ran.isEmpty { return Outcome(text: "Nothing ran", color: .secondary, needsAttention: false) }
        if ran.allSatisfy({ $0.status == .finished }) { return Outcome(text: "Finished", color: Theme.good, needsAttention: false) }
        if ran.contains(where: { $0.status == .cancelled }) { return Outcome(text: "Cancelled", color: Theme.attention, needsAttention: false) }
        let problems = ran.reduce(0) { $0 + max($1.problems.count, $1.status == .finished ? 0 : 1) }
        let failed = ran.contains { if case .failed = $0.status { return true }; return false }
        return Outcome(text: "\(problems) problem\(problems == 1 ? "" : "s")", color: failed ? Theme.problem : Theme.attention, needsAttention: true)
    }

    /// "~/Documents/Work" and "iCloud Drive/Work" instead of the long real paths.
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == icloud { return "iCloud Drive" }
        if path.hasPrefix(icloud + "/") { return "iCloud Drive/" + path.dropFirst(icloud.count + 1) }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    /// Where a destination is on this Mac right now (a folder, a connected drive, a mounted share); nil otherwise.
    static func localURL(of d: Destination) -> URL? {
        switch d.kind {
        case .localFolder:
            let u = URL(fileURLWithPath: (d.folder as NSString).expandingTildeInPath, isDirectory: true)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        case .usbDrive(let v):
            let u = URL(fileURLWithPath: "/Volumes/\(v)", isDirectory: true).appendingPathComponent(d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")), isDirectory: true)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        case .networkShare(let s):
            guard let url = URL(string: s), let m = NetworkShare.mountPoint(for: url) else { return nil }
            let u = m.appendingPathComponent(d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")), isDirectory: true)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        default: return nil
        }
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
