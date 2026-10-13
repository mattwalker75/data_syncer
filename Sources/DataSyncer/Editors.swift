// The sheets that make or change a job and a destination, and the folder picker they share.
import SwiftUI
import AppKit
import DataSyncerCore

enum FolderPicker {
    /// The standard Mac "choose a folder" panel. nil when cancelled.
    @MainActor
    static func choose(title: String, message: String, start: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.message = message
        p.prompt = "Choose"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = false
        p.allowsMultipleSelection = false
        if let start { p.directoryURL = start }
        return p.runModal() == .OK ? p.url : nil
    }

    /// The drives under /Volumes (other than the startup disk), as a person sees them in Finder.
    static func volumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return nil }
            return url.lastPathComponent
        }.sorted()
    }
}

// MARK: - a job

struct JobEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job?
    @State private var name = ""
    @State private var sourcePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(job == nil ? "New job" : "Edit job").font(.title2).fontWeight(.bold)
            Form {
                TextField("Name", text: $name, prompt: Text("Work documents"))
                LabeledContent("Source folder") {
                    HStack {
                        TextField("", text: $sourcePath, prompt: Text("/Users/you/Documents")).font(.system(.body, design: .monospaced))
                        Button("Choose…") {
                            if let url = FolderPicker.choose(title: "Choose the source folder", message: "The folder on this Mac that Data Syncer copies from.", start: sourcePath.isEmpty ? nil : URL(fileURLWithPath: sourcePath)) { sourcePath = url.path }
                        }
                    }
                }
                Text("The source is always a folder on this Mac, and it is the truth: copying only ever goes from it to the destinations.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                if job != nil { Text("Destinations are added on the job's page.").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(job == nil ? "Add job" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || sourcePath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { if let job { name = job.name; sourcePath = job.sourcePath } }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces), s = sourcePath.trimmingCharacters(in: .whitespaces)
        if var job {
            job.name = n; job.sourcePath = s
            model.update(job)
        } else {
            model.add(Job(name: n, sourcePath: s))
        }
        dismiss()
    }
}

