// Settings (the gear at the bottom of the sidebar, or ⌘,): General, Appearance, Accounts, Notifications,
// Run history. Appearance gets its accent colours and custom themes in step 6; Accounts fills in step 5.
import SwiftUI
import DataSyncerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            accounts.tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            history.tabItem { Label("Run history", systemImage: "clock") }
        }
        .frame(width: 620, height: 440)
    }

    private var general: some View {
        Form {
            LabeledContent("Data Syncer") { Text(DataSyncerCore.version) }
            LabeledContent("Jobs and settings") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.store.url.deletingLastPathComponent().path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }.buttonStyle(.link).font(.system(size: 12))
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

    private var appearance: some View {
        Form {
            Picker("Look", selection: $model.settings.appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Follow the system switches with your Mac's Appearance setting, including automatic dark mode at night.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            Section("Accent colour and your own themes") {
                Text("Coming in a later step: pick the accent colour, and save named themes of your own.").foregroundStyle(.secondary).font(.system(size: 12.5))
            }
        }
        .formStyle(.grouped)
    }

    private var accounts: some View {
        Form {
            Section("Cloud and server accounts") {
                Text("Google Drive, Dropbox, OneDrive, Amazon S3 and SSH sign-ins are kept here, in your Mac's Keychain. They arrive with those destination kinds in a later step.")
                    .foregroundStyle(.secondary).font(.system(size: 12.5))
            }
        }
        .formStyle(.grouped)
    }

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
