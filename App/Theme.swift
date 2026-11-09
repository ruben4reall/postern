import AppKit
import SwiftUI

/// Proton Mail's colors, from its Snow (light) and Carbon (dark) themes, so Postern looks at home beside it: purple
/// marks what you can act on and what is selected, the deep purple sidebar echoes Proton's own, and states keep
/// Proton's signal colors. Postern is not Proton's app, so it keeps its own mark and name.
enum Theme {
    // Purple
    static let accent = dynamic(light: 0x6D4AFF, dark: 0x8A6EFF)
    /// Solid buttons in both appearances.
    static let interaction = Color(hex: 0x6D4AFF)
    static let accentSoft = dynamic(light: 0xF0EDFF, dark: 0x29214D)
    static let accentStrong = dynamic(light: 0xE2DBFF, dark: 0x372580)

    // Surfaces
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x16141C)
    static let weak = dynamic(light: 0xF5F4F2, dark: 0x292733)
    static let elevated = dynamic(light: 0xFFFFFF, dark: 0x1E1C26)
    static let lowered = dynamic(light: 0xF8F8F6, dark: 0x0E0D12)
    static let border = dynamic(light: 0xEAE7E4, dark: 0x343140)
    static let borderStrong = dynamic(light: 0xD1CFCD, dark: 0x4A4658)

    // Text
    static let text = dynamic(light: 0x0C0C14, dark: 0xFFFFFF)
    static let textWeak = dynamic(light: 0x5C5958, dark: 0xA7A4B5)
    static let hint = dynamic(light: 0x8F8D8A, dark: 0x6D697D)

    // Signals
    static let success = Color(hex: 0x1EA885)
    static let warning = Color(hex: 0xFF9900)
    static let danger = dynamic(light: 0xDC3251, dark: 0xF5385A)
    static let info = Color(hex: 0x239ECE)

    // The sidebar, deep purple in both appearances, as on Proton's web app.
    static let sidebar = dynamic(light: 0x1B1340, dark: 0x120D2B)
    static let sidebarTile = dynamic(light: 0x271C57, dark: 0x1E1745)
    static let sidebarText = Color.white
    static let sidebarTextWeak = Color(hex: 0xB3A3F5)

    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 12

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A small capsule in a signal color, like Proton's badges.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.3)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// A rounded surface with Proton's thin edge.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}
