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
            Section("Theme") {
                ForEach(Appearance.allCases, id: \.self) { a in
                    let on = model.settings.activeThemeId == nil && model.settings.appearance == a
                    themeRow(on: on, name: a.label, detail: a == .system ? "switches with your Mac's Appearance setting, including automatic dark mode at night" : nil) {
                        model.settings.activeThemeId = nil; model.settings.appearance = a
                    }
                }
                ForEach(model.settings.themes) { t in
                    let on = model.settings.activeThemeId == t.id
                    themeRow(on: on, name: t.name, detail: t.look.label.lowercased()) { model.settings.activeThemeId = t.id } extra: {
                        HStack(spacing: 4) {
                            Circle().fill(t.accent.color).frame(width: 12, height: 12)
                            Circle().fill(t.good.color).frame(width: 12, height: 12)
                            Circle().fill(t.attention.color).frame(width: 12, height: 12)
                            Circle().fill(t.problem.color).frame(width: 12, height: 12)
                        }
                    } trailing: {
                        Button("Edit…") { editing = t }
                        Button { themeToDelete = t } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete this theme").accessibilityLabel("Delete the theme \(t.name)")
                    }
                }
                HStack {
                    Text("Your own theme sets the look, the accent, the good / attention / problem colours, and tints for the sidebar and cards.")
                        .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("New…") { editing = CustomTheme(name: "", look: model.settings.appearance, accent: model.settings.accent) }
                        .help("Make a theme of your own")
                }
            }
            Section("Accent colour") {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { a in
                        Button {
                            model.settings.accent = a.color
                            customAccent = a.color.color
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
                     ? "The theme “\(model.settings.activeTheme!.name)” sets the accent. Choose Light, Dark or Follow the system above to pick one here."
                     : "\(accentName) — buttons, the selected job, badges and progress bars.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { customAccent = model.settings.accent.color; DispatchQueue.main.async { loaded = true } }
        .sheet(item: $editing) { t in ThemeEditor(theme: t) }
        .confirmationDialog("Delete the theme “\(themeToDelete?.name ?? "")”?", isPresented: Binding(get: { themeToDelete != nil }, set: { if !$0 { themeToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete theme") { if let t = themeToDelete { delete(t) }; themeToDelete = nil }
            Button("Cancel", role: .cancel) { themeToDelete = nil }.keyboardShortcut(.defaultAction)
        }
    }

    /// One line of the theme list: a check mark, the name, a detail, and whatever the caller adds. Clicking the line picks it.
    @ViewBuilder private func themeRow<Extra: View, Trailing: View>(on: Bool, name: String, detail: String?, pick: @escaping () -> Void,
                                                                   @ViewBuilder extra: () -> Extra = { EmptyView() },
                                                                   @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.accent : Color.secondary)
            Text(name).fontWeight(on ? .semibold : .regular)
            extra()
            if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            trailing()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
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
                Field("Name", $theme.name, "Midnight")
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
                Text("The main window shows the theme while you adjust it.").font(.system(size: 13.5)).foregroundStyle(.secondary)
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
        .onDisappear { model.previewLook = nil; if !saved { Theme.apply(model.settings); model.objectWillChange.send() } }
    }

    private var preview: some View {
        HStack(spacing: 10) {
            Badge(text: "Full + incremental", fill: accent.opacity(0.16), color: accent)
            HStack(spacing: 6) { Dot(color: good); Text("Finished") }
            HStack(spacing: 6) { Dot(color: attention); Text("1 problem") }
            HStack(spacing: 6) { Dot(color: problem); Text("Failed") }
            Spacer()
            Button("Run…") {}.buttonStyle(.borderedProminent).tint(accent).allowsHitTesting(false).accessibilityHidden(true)
        }
        .font(.system(size: 14))
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
        model.previewLook = theme.look
        model.objectWillChange.send()
    }

    private func save() {
        saved = true
        model.settings = previewSettings
        dismiss()
    }
}
