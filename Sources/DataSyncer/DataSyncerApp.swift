// The app: one main window (jobs, or the run screen while a job runs) and the Settings window.
// Everything the windows show comes from AppModel; everything that copies lives in DataSyncerCore.
import SwiftUI
import DataSyncerCore

@main
struct DataSyncerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Data Syncer", id: "main") {
            MainWindow()
                .environmentObject(model)
                .preferredColorScheme(model.lookInForce.colorScheme)
                .tint(Theme.accent)
                .font(.system(size: 14))
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Job…") { model.newJob() }.keyboardShortcut("n")
                Button("Duplicate Job") { if let j = model.selectedJob { model.duplicate(j) } }.keyboardShortcut("d").disabled(model.selectedJob == nil)
            }
            CommandMenu("Job") {
                Button("Run…") { model.askToRun() }.keyboardShortcut("r").disabled(!model.canRun)
                Button("Check Destinations") { model.checkDestinations() }.keyboardShortcut("k").disabled(model.selectedJob == nil)
                Button("Restore…") { model.askToRestore() }.disabled(model.selectedJob == nil || model.isRunning)
                Divider()
                Button("Show Last Run") { model.watchRun() }.keyboardShortcut("l").disabled(!model.hasLastRun)
                Button("Cancel Run or Restore") { model.cancelRun() }.keyboardShortcut(".").disabled(!model.isRunning)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.lookInForce.colorScheme)
                .tint(Theme.accent)
                .font(.system(size: 14))
        }
    }
}
