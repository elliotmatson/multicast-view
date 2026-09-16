import SwiftUI
import AppKit

/// Colour tokens.
///
/// Every colour is defined once here, with its light and dark step chosen
/// deliberately rather than derived by lightening. The categorical series
/// slots are validated for colour-vision separation and for contrast against
/// the chart surface in both appearances.
enum Token {
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // MARK: Surfaces and ink
    //
    // These follow the system rather than a bespoke scale, so the app picks up
    // the user's appearance, accent and accessibility settings the way a stock
    // macOS app does. Only the data colours below are ours, because those have
    // to stay as validated.

    static let pagePlane      = Color(nsColor: .windowBackgroundColor)
    static let surface        = Color(nsColor: .controlBackgroundColor)
    static let textPrimary    = Color.primary
    static let textSecondary  = Color.secondary
    static let textMuted      = Color(nsColor: .tertiaryLabelColor)
    static let gridline       = Color(nsColor: .separatorColor)
    static let baseline       = Color(nsColor: .separatorColor)
    static let hairline       = Color(nsColor: .separatorColor)

    // MARK: Status
    //
    // Kept out of the series rotation on purpose: a state must never be
    // mistaken for a data series. Each one always ships with an icon and a
    // label, so the colour never carries the meaning by itself.

    static let statusGood     = dynamic(light: "#0ca30c", dark: "#0ca30c")
    static let statusWarning  = dynamic(light: "#fab219", dark: "#fab219")
    static let statusSerious  = dynamic(light: "#ec835a", dark: "#ec835a")
    static let statusCritical = dynamic(light: "#d03b3b", dark: "#d03b3b")

    // MARK: Categorical series
    //
    // Assigned in fixed order and never cycled: a group holds its slot for as
    // long as it is charted, and a series beyond the last slot folds into
    // "Other" rather than reusing a colour.
    //
    // Validated (OKLab dE x100, adjacent pairs) against the system control
    // background in both appearances (#ffffff / #1e1e1e):
    //   light  worst CVD 9.1, worst normal-vision 19.6
    //   dark   worst CVD 8.4, worst normal-vision 19.3
    // Three light-mode steps sit below 3:1 on the light surface, so the chart
    // always carries its legend with current values and the same data is in
    // the stream table -- identity is never colour alone.

    static let series: [Color] = [
        dynamic(light: "#2a78d6", dark: "#3987e5"),   // blue
        dynamic(light: "#eb6834", dark: "#d95926"),   // orange
        dynamic(light: "#1baf7a", dark: "#199e70"),   // aqua
        dynamic(light: "#eda100", dark: "#c98500"),   // yellow
        dynamic(light: "#e87ba4", dark: "#d55181"),   // magenta
    ]

    /// "Other" is a remainder, not an entity, so it gets a neutral rather than
    /// the next hue in the rotation.
    static let seriesOther = dynamic(light: "#a8a69e", dark: "#6b6a64")

    static func seriesColor(slot: Int) -> Color {
        guard slot >= 0, slot < series.count else { return seriesOther }
        return series[slot]
    }

    static func statusColor(_ severity: DiagnosticLevel) -> Color {
        switch severity {
        case .good:     return statusGood
        case .info:     return textSecondary
        case .warning:  return statusWarning
        case .critical: return statusCritical
        }
    }
}

enum DiagnosticLevel {
    case good, info, warning, critical
}

extension NSColor {
    convenience init(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
