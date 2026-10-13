// Settings (the gear at the bottom of the sidebar, or ⌘,): General, Appearance, Accounts, Notifications,
// Run history. Appearance gets its accent colours and custom themes in step 6; Accounts fills in step 5.
import SwiftUI
import DataSyncerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    // development only: DATASYNCER_AUTOSHEET=settings:<tab> opens on that tab
    @State private var tab = ProcessInfo.processInfo.environment["DATASYNCER_AUTOSHEET"]?.split(separator: ":").dropFirst().first.map(String.init) ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
            accounts.tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag("accounts")
            notifications.tabItem { Label("Notifications", systemImage: "bell") }.tag("notifications")
            history.tabItem { Label("Run history", systemImage: "clock") }.tag("history")
        }
        .frame(width: 640, height: 560)
    }

    private var general: some View {
        Form {
            LabeledContent("Data Syncer") { Text(DataSyncerCore.version) }
            LabeledContent("Jobs and settings") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.store.url.deletingLastPathComponent().path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }.buttonStyle(.link).foregroundStyle(Theme.accent).font(.system(size: 12))
                }
            }
            Section("Reading protected folders") {
                Text("If a source is in Desktop, Documents, Downloads or another folder macOS protects and a run says it can't be read, give Data Syncer Full Disk Access.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button("Open Privacy & Security settings…") { FullDiskAccess.openSettings() }
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View { AppearancePane() }

    private var accounts: some View { AccountsPane() }

    private var notifications: some View {
        Form {
            Toggle("Notify me when a run finishes", isOn: $model.settings.notifyWhenFinished)
            Text("A notification with a short summary — what was copied, and any problems — when a job finishes, whether or not Data Syncer is in front.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.history.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.history) {
                    TableColumn("When") { Text(Formatting.When($0.startedAt)) }.width(120)
                    TableColumn("Job", value: \.jobName)
                    TableColumn("Destinations") { r in Text(r.results.map(\.destinationName).joined(separator: " · ")) }
                    TableColumn("Outcome") { r in let o = Formatting.outcome(r); Text(o.text).foregroundStyle(o.color) }.width(100)
                    TableColumn("Took") { Text(Formatting.duration($0.finishedAt.timeIntervalSince($0.startedAt))) }.width(70)
                }
            }
            HStack {
                Text("\(model.history.count) run\(model.history.count == 1 ? "" : "s") kept (the newest 500).").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history…") { model.clearHistory() }.disabled(model.history.isEmpty)
            }
        }
        .padding(16)
    }
}

extension RunReport: Identifiable {
    public var id: Date { startedAt }
}
