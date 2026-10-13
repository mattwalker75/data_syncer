// Settings → Appearance: the look, the accent colour, and the user's own named themes with a live preview.
import SwiftUI
import DataSyncerCore

struct AppearancePane: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: CustomTheme?
    @State private var customAccent = Color.blue
    @State private var loaded = false
    @State private var themeToDelete: CustomTheme?

    var body: some View {
        Form {
            Section {
                Picker("Look", selection: $model.settings.appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.settings.activeTheme != nil)
                Text(model.settings.activeTheme != nil
                     ? "The theme “\(model.settings.activeTheme!.name)” sets the look. Choose “System colours” below to set it here."
                     : "Follow the system switches with your Mac's Appearance setting, including automatic dark mode at night.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Section("Accent colour") {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { a in
                        Button {
                            model.settings.accent = a.color
                        } label: {
                            Circle().fill(a.color.color).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(model.settings.accent == a.color ? 0.8 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain).help(a.label)
                    }
                    ColorPicker("", selection: $customAccent, supportsOpacity: false).labelsHidden()
                        .onChange(of: customAccent) { _, c in
                            // only a change the user made (not the value loaded on open) is saved
                            guard loaded else { return }
                            let t = ThemeColor(c)
                            if t != model.settings.accent { model.settings.accent = t }
                        }
                        .help("Any other colour").accessibilityLabel("A colour of your own")
                }
                .disabled(model.settings.activeTheme != nil)
                Text(model.settings.activeTheme != nil
                     ? "The theme sets the accent."
                     : "\(accentName) — buttons, the selected job, badges and progress bars.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Your own themes").fontWeight(.semibold)
                    Spacer()
                    Button("New theme…") { editing = CustomTheme(name: "", look: model.settings.appearance, accent: model.settings.accent) }
                }
                HStack {
                    Image(systemName: model.settings.activeThemeId == nil ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                    Text("System colours").fontWeight(model.settings.activeThemeId == nil ? .semibold : .regular)
                    Text("the look and accent above").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if model.settings.activeThemeId != nil { Button("Use") { model.settings.activeThemeId = nil } }
                }
                ForEach(model.settings.themes) { t in
                    let active = model.settings.activeThemeId == t.id
                    HStack {
                        Image(systemName: active ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                        Text(t.name).fontWeight(active ? .semibold : .regular)
                        HStack(spacing: 4) {
                            Circle().fill(t.accent.color).frame(width: 12, height: 12)
                            Circle().fill(t.good.color).frame(width: 12, height: 12)
                            Circle().fill(t.attention.color).frame(width: 12, height: 12)
                            Circle().fill(t.problem.color).frame(width: 12, height: 12)
                        }
                        Text(t.look.label.lowercased()).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        if !active { Button("Use") { model.settings.activeThemeId = t.id } }
                        Button("Edit…") { editing = t }
                        Button { themeToDelete = t } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete this theme").accessibilityLabel("Delete the theme \(t.name)")
                    }
                }
                Text("A theme sets the look, the accent, the good / attention / problem colours, and tints for the sidebar and cards. Changes preview live while you adjust them.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { customAccent = model.settings.accent.color; DispatchQueue.main.async { loaded = true } }
        .sheet(item: $editing) { t in ThemeEditor(theme: t) }
        .confirmationDialog("Delete the theme “\(themeToDelete?.name ?? "")”?", isPresented: Binding(get: { themeToDelete != nil }, set: { if !$0 { themeToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete theme", role: .destructive) { if let t = themeToDelete { delete(t) }; themeToDelete = nil }
            Button("Cancel", role: .cancel) { themeToDelete = nil }
        }
    }

    private var accentName: String {
        AccentChoice.allCases.first { $0.color == model.settings.accent }?.label ?? "A colour of your own"
    }

    private func delete(_ t: CustomTheme) {
        model.settings.themes.removeAll { $0.id == t.id }
        if model.settings.activeThemeId == t.id { model.settings.activeThemeId = nil }
    }
}

/// Make or change a theme; the window follows along as the colours change.
struct ThemeEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var theme: CustomTheme
    @State private var accent: Color = .blue
    @State private var good: Color = .green
    @State private var attention: Color = .orange
    @State private var problem: Color = .red
    @State private var tintSidebar = false
    @State private var sidebar: Color = .gray
    @State private var tintCards = false
    @State private var cards: Color = .gray
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(theme.name.isEmpty ? "New theme" : "Edit “\(theme.name)”").font(.title2).fontWeight(.bold)
            Form {
                TextField("Name", text: $theme.name, prompt: Text("Midnight"))
                Picker("Look", selection: $theme.look) { ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) } }
                Section("Colours") {
                    ColorPicker("Accent", selection: $accent, supportsOpacity: false)
                    ColorPicker("Good (finished, in sync)", selection: $good, supportsOpacity: false)
                    ColorPicker("Attention (problems, cancelled)", selection: $attention, supportsOpacity: false)
                    ColorPicker("Problem (failed)", selection: $problem, supportsOpacity: false)
                }
                Section("Tints") {
                    Toggle("Tint the sidebar", isOn: $tintSidebar)
                    if tintSidebar { ColorPicker("Sidebar tint", selection: $sidebar, supportsOpacity: false) }
                    Toggle("Tint the cards", isOn: $tintCards)
                    if tintCards { ColorPicker("Card tint", selection: $cards, supportsOpacity: false) }
                }
                preview
            }
            .formStyle(.grouped)
            HStack {
                Text("The main window shows the theme while you adjust it.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and use") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(theme.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .onAppear {
            accent = theme.accent.color; good = theme.good.color; attention = theme.attention.color; problem = theme.problem.color
            tintSidebar = theme.sidebarTint != nil; sidebar = theme.sidebarTint?.color ?? Color(nsColor: .systemIndigo)
            tintCards = theme.cardTint != nil; cards = theme.cardTint?.color ?? Color(nsColor: .systemIndigo)
        }
        .onChange(of: accent) { _, _ in live() }.onChange(of: good) { _, _ in live() }.onChange(of: attention) { _, _ in live() }
        .onChange(of: problem) { _, _ in live() }.onChange(of: tintSidebar) { _, _ in live() }.onChange(of: sidebar) { _, _ in live() }
        .onChange(of: tintCards) { _, _ in live() }.onChange(of: cards) { _, _ in live() }.onChange(of: theme.look) { _, _ in live() }
        // closing the sheet any other way (⌘W, quitting) puts the saved settings back
        .onDisappear { if !saved { Theme.apply(model.settings); model.objectWillChange.send() } }
    }

    private var preview: some View {
        HStack(spacing: 10) {
            Badge(text: "Full + incremental", fill: accent.opacity(0.16), color: accent)
            HStack(spacing: 6) { Dot(color: good); Text("Finished") }
            HStack(spacing: 6) { Dot(color: attention); Text("1 problem") }
            HStack(spacing: 6) { Dot(color: problem); Text("Failed") }
            Spacer()
            Button("Run…") {}.buttonStyle(.borderedProminent).tint(accent)
        }
        .font(.system(size: 12.5))
    }

    private var built: CustomTheme {
        var t = theme
        t.accent = ThemeColor(accent); t.good = ThemeColor(good); t.attention = ThemeColor(attention); t.problem = ThemeColor(problem)
        t.sidebarTint = tintSidebar ? ThemeColor(sidebar) : nil
        t.cardTint = tintCards ? ThemeColor(cards) : nil
        return t
    }

    /// The settings as they would be with this theme saved and in use.
    private var previewSettings: AppSettings {
        var s = model.settings
        let t = built
        if let i = s.themes.firstIndex(where: { $0.id == t.id }) { s.themes[i] = t } else { s.themes.append(t) }
        s.activeThemeId = t.id
        return s
    }

    /// Shows the theme in the windows as it is being adjusted, without saving anything (Cancel just closes).
    private func live() {
        Theme.apply(previewSettings)
        model.objectWillChange.send()
    }

    private func save() {
        saved = true
        model.settings = previewSettings
        dismiss()
    }
}
