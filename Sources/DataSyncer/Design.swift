// The design tokens every window uses — one type scale, the surfaces (cards, panels, rows), the icon tiles and
// the small shared views. Modelled on what current Mac utilities do (System Settings, Carbon Copy Cloner, Arq,
// CleanShot): the system typeface in five sizes, semantic system colours, 10-pt surfaces with a hairline edge and
// almost no shadow, title-case section headings, icon tiles on list rows, and dark-mode surfaces that get lighter
// as they come forward. The accent and the status colours still come from `Theme` (the user's own themes).
import SwiftUI
import DataSyncerCore

enum DS {
    // MARK: type — five sizes, one typeface (the body size is set once on each window's root)
    /// the job's name at the top of its page
    static let title = Font.system(size: 24, weight: .bold)
    /// a sheet's title, the run screen's headline
    static let heading = Font.system(size: 17, weight: .semibold)
    /// a section heading inside a page ("Destinations")
    static let section = Font.system(size: 14, weight: .semibold)
    /// body text — 14, a point up from the Mac default, as the owner asked
    static let body = Font.system(size: 14)
    /// notes, captions, second lines
    static let secondary = Font.system(size: 13)
    /// file paths in logs and lists
    static let mono = Font.system(size: 12.5, design: .monospaced)
    /// a big number on a tile
    static let stat = Font.system(size: 22, weight: .semibold)

    // MARK: shape and space
    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 7
    static let pad: CGFloat = 16
    static let gap: CGFloat = 12

    // MARK: colours that depend on the look (light / dark), read through the environment by the views below
    /// a card's face: white in light; a slightly lifted grey in dark (surfaces come forward by getting lighter)
    static func surface(_ scheme: ColorScheme) -> Color {
        if let tint = Theme.cardTint { return tint.opacity(scheme == .dark ? 0.22 : 0.16) }
        return scheme == .dark ? Color.white.opacity(0.06) : Color(nsColor: .controlBackgroundColor)
    }
    /// the hairline around a surface
    static func edge(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09) }
    /// a sunken panel (the run screen's left column)
    static func panel(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.03) }
    /// a row under the pointer
    static func hover(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04) }
    /// the shadow under a card (none in dark — the lighter face does the lifting)
    static func shadow(_ scheme: ColorScheme) -> Color { scheme == .dark ? .clear : Color.black.opacity(0.05) }
}

// MARK: - surfaces

/// A card: the surface colour, a hairline edge, a faint shadow in light mode.
struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = DS.pad
    var tinted = false   // kept for callers; every card now shares one look
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(DS.surface(scheme), in: RoundedRectangle(cornerRadius: DS.radius))
            .overlay(RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.edge(scheme)))
            .shadow(color: DS.shadow(scheme), radius: 3, y: 1)
    }
}

/// A card that holds rows, separated by inset hairlines (the grouped list of System Settings).
struct GroupedCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(DS.surface(scheme), in: RoundedRectangle(cornerRadius: DS.radius))
            .overlay(RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.edge(scheme)))
            .shadow(color: DS.shadow(scheme), radius: 3, y: 1)
            .clipShape(RoundedRectangle(cornerRadius: DS.radius))
    }
}

/// The hairline between two rows of a GroupedCard, inset like the system's.
struct RowDivider: View {
    var inset: CGFloat = DS.pad
    var body: some View { Divider().padding(.leading, inset) }
}

/// Highlights a row while the pointer is over it (for rows you can click).
struct HoverHighlight: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .background(over ? DS.hover(scheme) : Color.clear)
            .onHover { over = $0 }
    }
}
extension View { func hoverHighlight() -> some View { modifier(HoverHighlight()) } }

/// A rounded square with a symbol in it — the icon on a row (what System Settings and CCC put beside each item).
struct IconTile: View {
    let systemName: String
    var color: Color = Theme.accent
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: DS.radiusSmall))
    }
}

// MARK: - small shared views

/// "Destinations" — a section heading; `detail` is the quieter part after it ("· they run in this order").
struct SectionLabel: View {
    let text: String
    var detail: String?
    init(_ text: String, detail: String? = nil) { self.text = text; self.detail = detail }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text).font(DS.section)
            if let detail { Text(detail).font(DS.secondary).foregroundStyle(.secondary) }
        }
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// "Sync", "Finished" — a small capsule with a tinted ground.
struct Badge: View {
    let text: String
    let fill: Color
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(fill, in: Capsule())
    }
}

/// A check's line: a tick or a cross, the name, the detail.
struct CheckRow: View {
    let item: CheckItem
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill").font(.system(size: 14))
                .foregroundStyle(item.ok ? Theme.good : Theme.problem).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text(item.detail).font(DS.secondary).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(DS.body)
    }
}

/// A big number with its label (the run screen's tiles).
struct StatTile: View {
    let label: String
    let value: Int
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(DS.secondary).foregroundStyle(.secondary)
                Text(Formatting.count(value)).font(DS.stat).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
