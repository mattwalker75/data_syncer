// Appearance: the look (light / dark / follow the system), the accent colour, and the user's own named themes.
// A theme sets the accent, the good / attention / problem colours, and tints for the sidebar and cards. The
// active theme is applied through `Theme`, which the views read; everything here is saved in settings.json.
import SwiftUI

/// A colour that can be saved (sRGB 0…1).
struct ThemeColor: Codable, Hashable {
    var r: Double, g: Double, b: Double
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    /// Rounded to 8-bit steps: NSColor keeps Float components, so a round trip through the picker would
    /// otherwise turn every preset into "a colour of your own" by a billionth
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0.4, blue: 0.85, alpha: 1)
        func q(_ v: CGFloat) -> Double { (Double(v) * 255).rounded() / 255 }
        r = q(ns.redComponent); g = q(ns.greenComponent); b = q(ns.blueComponent)
    }
    static func == (a: ThemeColor, b: ThemeColor) -> Bool { abs(a.r - b.r) < 1 / 512 && abs(a.g - b.g) < 1 / 512 && abs(a.b - b.b) < 1 / 512 }
    func hash(into h: inout Hasher) { h.combine(Int(r * 255)); h.combine(Int(g * 255)); h.combine(Int(b * 255)) }
    static let blue = ThemeColor(0.04, 0.37, 0.84)
}

/// The accents offered out of the box (plus any colour the user picks).
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, graphite
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var color: ThemeColor {
        switch self {
        case .blue: return .blue
        case .purple: return ThemeColor(0.56, 0.27, 0.68)
        case .pink: return ThemeColor(0.91, 0.26, 0.52)
        case .red: return ThemeColor(0.86, 0.22, 0.22)
        case .orange: return ThemeColor(0.93, 0.53, 0.12)
        case .yellow: return ThemeColor(0.84, 0.66, 0.08)
        case .green: return ThemeColor(0.16, 0.60, 0.33)
        case .teal: return ThemeColor(0.10, 0.56, 0.62)
        case .graphite: return ThemeColor(0.45, 0.45, 0.48)
        }
    }
}

/// A named theme of the user's own.
struct CustomTheme: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var look: Appearance = .system
    var accent: ThemeColor = .blue
    var good = ThemeColor(0.12, 0.62, 0.33)
    var attention = ThemeColor(0.85, 0.47, 0.02)
    var problem = ThemeColor(0.80, 0.18, 0.18)
    /// nil = the system's own backgrounds; otherwise a tint laid over them
    var sidebarTint: ThemeColor?
    var cardTint: ThemeColor?
}

/// What the views use. Updated by AppModel whenever the settings change; read on the main thread.
enum Theme {
    nonisolated(unsafe) static var accent = Color.accentColor
    nonisolated(unsafe) static var good = Color(red: 0.12, green: 0.62, blue: 0.33)
    nonisolated(unsafe) static var attention = Color(red: 0.85, green: 0.47, blue: 0.02)
    nonisolated(unsafe) static var problem = Color(red: 0.80, green: 0.18, blue: 0.18)
    nonisolated(unsafe) static var sidebarTint: Color?
    nonisolated(unsafe) static var cardTint: Color?

    static func badge(_ mode: DestinationMode) -> (fill: Color, text: Color) {
        switch mode {
        // system colours, so the text reads on both light and dark grounds
        case .sync: return (Color.green.opacity(0.16), Color.green)
        case .fullOnly: return (Color.purple.opacity(0.16), Color.purple)
        case .fullIncremental: return (accent.opacity(0.16), accent)
        }
    }

    /// Applies the settings: the chosen theme, or just the accent.
    @MainActor static func apply(_ s: AppSettings) {
        let t = s.activeTheme
        accent = (t?.accent ?? s.accent).color
        good = (t?.good ?? CustomTheme(name: "").good).color
        attention = (t?.attention ?? CustomTheme(name: "").attention).color
        problem = (t?.problem ?? CustomTheme(name: "").problem).color
        sidebarTint = t?.sidebarTint?.color
        cardTint = t?.cardTint?.color
    }
}

import DataSyncerCore
