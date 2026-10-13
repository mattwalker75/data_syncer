// The one object the windows watch: the jobs, the run history, the run in progress, and the settings.
// It owns the jobs file and the history file, starts and cancels runs, and turns the runner's events into
// the RunSession the run screen and the running strip show.
import SwiftUI
import UserNotifications
import DataSyncerCore

/// Which screen the main window shows.
enum Screen { case jobs, run, restore }

/// What the user is being asked, as a sheet on the main window.
enum MainSheet: Identifiable {
    case newJob
    case editJob(Job)
    case newDestination(Job)
    case editDestination(Job, Destination)
    case check(Job)
    case runOptions(Job)
    case restore(Job)
    var id: String {
        switch self {
        case .newJob: return "newJob"
        case .editJob(let j): return "editJob-\(j.id)"
        case .newDestination(let j): return "newDest-\(j.id)"
        case .editDestination(_, let d): return "editDest-\(d.id)"
        case .check(let j): return "check-\(j.id)"
        case .runOptions(let j): return "run-\(j.id)"
        case .restore(let j): return "restore-\(j.id)"
        }
    }
}

/// A plain message for the user (a problem reading a file, something not built yet).
struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var selectedJobId: Job.ID?
    @Published var history: [RunReport] = []
    @Published var screen: Screen = .jobs
    @Published var sheet: MainSheet?
    @Published var notice: Notice?
    @Published var settings = AppSettings.load() { didSet { settings.save() } }
    /// the run in progress, or the last one until the user leaves the run screen
    @Published var session: RunSession?
    /// the restore in progress, or the last one until the user leaves the restore screen
    @Published var restoreSession: RestoreSession?
    /// a sync preview waiting for the user's answer
    @Published var preview: SyncPreviewRequest?
    /// the source folder's size, per job, counted in the background
    @Published var sourceStats: [Job.ID: SourceStats] = [:]

    let store = JobStore()
    let historyStore = RunHistory()
    /// passwords, passphrases and tokens: the Keychain
    let secrets: SecretStore = KeychainSecrets()
    /// the cloud accounts (accounts.json); their tokens are in the Keychain
    let accountStore = CloudAccountStore()
    @Published var cloudAccounts: [CloudAccount] = []
    private var runTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    init() {
        do { jobs = try store.load() } catch let e as DSError { notice = Notice(title: "The jobs file could not be read", message: e.message) } catch {}
        do { history = try historyStore.load() } catch let e as DSError { notice = Notice(title: "The run history could not be read", message: e.message) } catch {}
        do { cloudAccounts = try accountStore.load() } catch let e as DSError { notice = Notice(title: "The accounts file could not be read", message: e.message) } catch {}
        selectedJobId = jobs.first?.id
        // development only: DATASYNCER_AUTOSTART=<job name> runs that job as soon as the window is up
        if let name = ProcessInfo.processInfo.environment["DATASYNCER_AUTOSTART"], let job = jobs.first(where: { $0.name == name }) {
            selectedJobId = job.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start(job, choices: [:]) }
        }
        // development only: DATASYNCER_AUTOSHEET=newJob|newDestination|check|run|settings opens that for the first job
        if let what = ProcessInfo.processInfo.environment["DATASYNCER_AUTOSHEET"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let job = self.selectedJob
                switch what {
                case "newJob": self.sheet = .newJob
                case "newDestination": if let job { self.sheet = .newDestination(job) }
                case "check": if let job { self.sheet = .check(job) }
                case "run": if let job { self.sheet = .runOptions(job) }
                default: break
                }
            }
        }
        // development only: DATASYNCER_AUTORESTORE="<job name>" opens Restore… for that job;
        // "<job name>|<destination name>|<folder>" restores the newest backup there straight away
        if let spec = ProcessInfo.processInfo.environment["DATASYNCER_AUTORESTORE"] {
            let parts = spec.split(separator: "|").map(String.init)
            if let job = jobs.first(where: { $0.name == parts[0] }) {
                selectedJobId = job.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    guard parts.count == 3, let d = job.destinations.first(where: { $0.name == parts[1] }) else { self.sheet = .restore(job); return }
                    Task {
                        guard let storage = try? await DefaultStorageFactory().storage(for: d), let catalog = try? await BackupCatalog.load(from: storage),
                              let point = catalog.entries.first(where: { $0.manifest != nil })?.folder else { return }
                        self.startRestore(job: job, destination: d, storage: storage, catalog: catalog, point: point, target: URL(fileURLWithPath: parts[2], isDirectory: true), removeDeleted: true)
                    }
                }
            }
        }
    }

    // MARK: jobs

    var selectedJob: Job? { jobs.first { $0.id == selectedJobId } }
    /// a job or a restore is going; only one at a time
    var isRunning: Bool { (session?.isRunning ?? false) || (restoreSession?.isRunning ?? false) }
    /// what is going, for the strip and the sidebar
    var runningName: String { session?.isRunning == true ? (session?.job.name ?? "") : "Restore" }
    var canRun: Bool { selectedJob != nil && !isRunning }

    func saveJobs() {
        do { try store.save(jobs) } catch { notice = Notice(title: "The jobs could not be saved", message: error.localizedDescription) }
    }

    func newJob() { sheet = .newJob }

    func add(_ job: Job) {
        jobs.append(job)
        selectedJobId = job.id
        saveJobs()
    }

    func update(_ job: Job) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i] = job
        saveJobs()
    }

    func delete(_ job: Job) {
        for d in job.destinations { try? secrets.remove(for: SecretAccount.destination(d.id)) }
        jobs.removeAll { $0.id == job.id }
        if selectedJobId == job.id { selectedJobId = jobs.first?.id }
        sourceStats.removeValue(forKey: job.id)
        saveJobs()
    }

    func upsert(_ destination: Destination, in job: Job) {
        var job = job
        if let i = job.destinations.firstIndex(where: { $0.id == destination.id }) { job.destinations[i] = destination }
        else { job.destinations.append(destination) }
        update(job)
    }

    func remove(_ destination: Destination, from job: Job) {
        try? secrets.remove(for: SecretAccount.destination(destination.id))
        var job = job
        job.destinations.removeAll { $0.id == destination.id }
        update(job)
    }

    func setEnabled(_ enabled: Bool, _ destination: Destination, in job: Job) {
        var d = destination
        d.enabled = enabled
        upsert(d, in: job)
    }

    func move(_ job: Job, from: IndexSet, to: Int) {
        var job = job
        job.destinations.move(fromOffsets: from, toOffset: to)
        update(job)
    }

    // MARK: cloud accounts

    func add(_ account: CloudAccount) {
        cloudAccounts.append(account)
        saveAccounts()
    }

    /// Forgets an account and its tokens. Destinations that used it say so the next time they run.
    func remove(_ account: CloudAccount) {
        cloudAccounts.removeAll { $0.id == account.id }
        try? secrets.remove(for: SecretAccount.cloud(account.id))
        saveAccounts()
    }

    private func saveAccounts() {
        do { try accountStore.save(cloudAccounts) } catch { notice = Notice(title: "The accounts could not be saved", message: error.localizedDescription) }
    }

    /// The name of the account a destination uses, for the destination's row.
    func accountLabel(_ kind: DestinationKind) -> String? {
        guard let id = kind.cloudAccount else { return nil }
        return cloudAccounts.first { $0.id.uuidString == id }?.label
    }

    // MARK: the source folder's size (shown on the job's page; counted once per job per session)

    func countSource(of job: Job, force: Bool = false) {
        if !force, let s = sourceStats[job.id], s.path == job.sourcePath { return }
        sourceStats[job.id] = SourceStats(path: job.sourcePath, state: .counting)
        let url = job.sourceURL, id = job.id, path = job.sourcePath
        Task.detached(priority: .utility) {
            let result: SourceStats.State
            do { let r = try Scanner.scan(url); result = .counted(files: r.fileCount, bytes: r.totalBytes) }
            catch let e as DSError { result = .problem(e.message) }
            catch { result = .problem(error.localizedDescription) }
            await MainActor.run { [self] in
                if self.sourceStats[id]?.path == path { self.sourceStats[id] = SourceStats(path: path, state: result) }
            }
        }
    }

    // MARK: checks

    func checkDestinations() {
        guard let job = selectedJob else { return }
        sheet = .check(job)
    }

    // MARK: running

    /// Opens the "Run…" sheet for the selected job (the per-destination full/incremental choice, then Start).
    func askToRun() {
        guard let job = selectedJob, !isRunning else { return }
        if job.destinations.filter(\.enabled).isEmpty {
            notice = Notice(title: "Nothing to run", message: "This job has no destination turned on. Add a destination, or turn one on, and try again.")
            return
        }
        sheet = .runOptions(job)
    }

    func start(_ job: Job, choices: [Destination.ID: BackupChoice]) {
        guard !isRunning else { return }
        let session = RunSession(job: job)
        self.session = session
        screen = .run
        sheet = nil
        let runner = JobRunner()
        runner.confirmSync = { [weak self] destination, plan in
            // the preview: shown on the run screen; the run waits for the answer
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    guard let self else { cont.resume(returning: false); return }
                    self.preview = SyncPreviewRequest(destination: destination, plan: plan) { answer in
                        self.preview = nil
                        cont.resume(returning: answer)
                    }
                }
            }
        }
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Data Syncer is copying files")
        runTask = Task { [weak self] in
            let report = await runner.run(job, choices: choices) { event in
                Task { @MainActor in session.apply(event) }
            }
            await MainActor.run { [weak self] in self?.finished(report, session) }
        }
    }

    private func finished(_ report: RunReport, _ session: RunSession) {
        session.finish(report)
        runTask = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a); sleepActivity = nil }
        do { history = try historyStore.append(report) } catch { notice = Notice(title: "The run history could not be saved", message: error.localizedDescription) }
        if settings.notifyWhenFinished { notify(report) }
    }

    func cancelRun() {
        runTask?.cancel()
        session?.cancelRequested = true
        restoreSession?.cancelRequested = true
        preview?.answer(false)
    }

    // MARK: restoring

    func askToRestore() {
        guard let job = selectedJob else { return }
        sheet = .restore(job)
    }

    func startRestore(job: Job, destination: Destination, storage: Storage, catalog: BackupCatalog, point: String, target: URL, removeDeleted: Bool) {
        guard !isRunning else { return }
        let session = RestoreSession(job: job, destination: destination, point: point, target: target)
        restoreSession = session
        screen = .restore
        sheet = nil
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Data Syncer is restoring files")
        runTask = Task { [weak self] in
            let result = await RestoreEngine.restore(from: storage, catalog: catalog, point: point, to: target, removeDeleted: removeDeleted) { event in
                Task { @MainActor in session.apply(event) }
            }
            await MainActor.run { [weak self] in
                session.finish(result)
                self?.runTask = nil
                if let a = self?.sleepActivity { ProcessInfo.processInfo.endActivity(a); self?.sleepActivity = nil }
            }
        }
    }

    func dismissRestore() {
        if restoreSession?.isRunning == false { restoreSession = nil }
        screen = .jobs
    }

    /// Back to the jobs list; the run (if still going) carries on and shows in the strip.
    func showJobs() { screen = .jobs }
    func watchRun() {
        if restoreSession?.isRunning == true { screen = .restore } else if session != nil { screen = .run }
    }

    /// Clears the finished run from the window.
    func dismissRun() {
        if session?.isRunning == false { session = nil }
        screen = .jobs
    }

    private func notify(_ report: RunReport) {
        // notifications need a real app bundle; running the bare program (swift run) has none
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = report.allFine ? "\(report.jobName) finished" : "\(report.jobName) finished with problems"
            content.body = Formatting.summary(of: report)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: history

    func clearHistory() {
        history = []
        try? historyStore.save([])
    }
}

/// The size of a job's source folder, counted in the background.
struct SourceStats: Equatable {
    enum State: Equatable { case counting, counted(files: Int, bytes: Int64), problem(String) }
    var path: String
    var state: State
}

/// A sync preview on the run screen: the plan, and how the user answered.
struct SyncPreviewRequest: Identifiable {
    let id = UUID()
    let destination: Destination
    let plan: SyncPlan
    let answer: (Bool) -> Void
}

// MARK: - Settings

enum Appearance: String, Codable, CaseIterable {
    case system, light, dark
    var label: String {
        switch self { case .system: return "Follow the system"; case .light: return "Light"; case .dark: return "Dark" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

/// The app's own settings (not the jobs): saved as JSON beside the jobs file.
struct AppSettings: Codable, Equatable {
    var appearance: Appearance = .system
    var notifyWhenFinished = true
    var confirmBeforeDeleting = true

    static var url: URL { JobStore.defaultURL().deletingLastPathComponent().appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: AppSettings.url, options: .atomic)
    }
}
