import AppKit
import SwiftUI

/// Proton Mail's look, from the tokens of its Snow (light) and Carbon (dark) themes and of its default purple frame:
/// a deep purple sidebar beside a white work area, warm greys, radius 8 controls, solid badges, banners, and glass only
/// on chrome and floating controls, never behind what the user reads. Postern is not Proton's app: it keeps its own
/// mark and name, and borrows values and shapes, never Proton's logo, icons or code.
enum Theme {
    // Purple
    static let accent = dynamic(light: 0x6D4AFF, dark: 0x8A6EFF)
    /// Solid buttons, toggles and selection, in both appearances.
    static let interaction = Color(hex: 0x6D4AFF)
    static let interactionHover = dynamic(light: 0x6243E6, dark: 0x7C5CFF)
    static let interactionActive = dynamic(light: 0x573BCC, dark: 0x8A6EFF)
    static let link = dynamic(light: 0x6D4AFF, dark: 0x7C5CFF)
    static let accentSoft = dynamic(light: 0xF0EDFF, dark: 0x1C1633)
    static let accentStrong = dynamic(light: 0xE2DBFF, dark: 0x29214D)
    static let chipSelected = dynamic(light: 0xEAE5FF, dark: 0x35356A)
    static let chipSelectedText = dynamic(light: 0x372580, dark: 0xD0D0FF)

    // Surfaces
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x16141C)
    static let weak = dynamic(light: 0xF5F4F2, dark: 0x292733)
    static let strong = dynamic(light: 0xE5E4E1, dark: 0x3F3B4C)
    static let elevated = dynamic(light: 0xFFFFFF, dark: 0x1E1C26)
    static let lowered = dynamic(light: 0xF8F8F6, dark: 0x0E0D12)
    static let border = dynamic(light: 0xEAE7E4, dark: 0x343140)
    static let borderStrong = dynamic(light: 0xD1CFCD, dark: 0x4A4658)
    static let field = dynamic(light: 0xADABA8, dark: 0x5B576B)
    static let fieldHover = dynamic(light: 0x8F8D8A, dark: 0x6D697D)
    static let secondaryBorder = dynamic(light: 0xDEDBD9, dark: 0x5C5969)
    static let secondaryBorderHover = dynamic(light: 0xD3D0CD, dark: 0x6E6B79)
    static let secondaryBorderActive = dynamic(light: 0xC7C4C2, dark: 0x6E6B79)
    static let secondaryHover = dynamic(light: 0xF9F8F7, dark: 0x25232C)
    static let secondaryActive = dynamic(light: 0xF5F3F2, dark: 0x292733)
    static let rowHover = dynamicAlpha(light: (0xC2C1C0, 0.20), dark: (0x5B576B, 0.20))
    static let quoteBar = Color(hex: 0x657EE4)

    // Text
    static let text = dynamic(light: 0x0C0C14, dark: 0xFFFFFF)
    static let textWeak = dynamic(light: 0x5C5958, dark: 0xA7A4B5)
    static let hint = dynamic(light: 0x8F8D8A, dark: 0x6D697D)

    // Signals. Text on the warning orange is black, as in Proton.
    static let success = Color(hex: 0x1EA885)
    static let successStrong = Color(hex: 0x18866A)
    static let warning = Color(hex: 0xFF9900)
    static let warningHover = dynamic(light: 0xF27D00, dark: 0xFFA31A)
    static let warningActive = dynamic(light: 0xE66300, dark: 0xFFAD33)
    static let danger = dynamic(light: 0xDC3251, dark: 0xF5385A)
    static let dangerHover = dynamic(light: 0xC62D49, dark: 0xF64C6B)
    static let dangerActive = dynamic(light: 0xB02841, dark: 0xF7607B)
    static let info = Color(hex: 0x239ECE)

    // The sidebar: Proton's purple frame in light, Carbon in dark, as Proton has no purple dark theme.
    static let sidebar = dynamic(light: 0x1B1340, dark: 0x16141C)
    static let sidebarTile = dynamic(light: 0x271C57, dark: 0x292733)
    static let sidebarStrong = dynamic(light: 0x38277A, dark: 0x3F3B4C)
    static let sidebarBorder = dynamic(light: 0x3C2B80, dark: 0x343140)
    static let sidebarText = Color.white
    static let sidebarTextWeak = dynamic(light: 0xB3A3F5, dark: 0xA7A4B5)
    static let sidebarHint = dynamic(light: 0x8067E4, dark: 0x6D697D)
    static let sidebarIconOn = Color(hex: 0x8A6EFF)
    static let sidebarHover = dynamicAlpha(light: (0x4A368F, 0.30), dark: (0x5B576B, 0.20))
    static let sidebarPressed = dynamicAlpha(light: (0x4A398F, 0.50), dark: (0x5B576B, 0.40))
    static let sidebarCounter = Color(hex: 0x8A6EFF)

    static let radiusSmall: CGFloat = 4
    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let floatRadius: CGFloat = 16

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    static func dynamicAlpha(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (hex, alpha) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex).withAlphaComponent(alpha)
        })
    }

    /// The tile behind a tier's symbol, and the symbol's color: purple for what reads, files or drafts, Proton's
    /// warning and danger for what leaves or is lost.
    enum Signal {
        case accent, warning, danger

        var tile: Color {
            switch self {
            case .accent: Theme.accentSoft
            case .warning: Theme.dynamic(light: 0xFFF5E6, dark: 0x331200)
            case .danger: Theme.dynamic(light: 0xFCEBEE, dark: 0x310B12)
            }
        }

        var glyph: Color {
            switch self {
            case .accent: Theme.accent
            case .warning: Theme.dynamic(light: 0xE66300, dark: 0xFFAD33)
            case .danger: Theme.danger
            }
        }

        /// The solid color of a meter or a badge.
        var solid: Color {
            switch self {
            case .accent: Theme.interaction
            case .warning: Theme.warning
            case .danger: Theme.danger
            }
        }
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

// MARK: Badges

/// Proton's badge: a solid capsule in a signal color, white text (black on the warning orange).
struct Pill: View {
    let text: String
    let color: Color
    var onColor: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(onColor)
            .background(color, in: Capsule())
    }
}

/// A flat tinted tile with an outline symbol, where Apple would draw a gradient app icon.
struct SymbolTile: View {
    let symbol: String
    var signal: Theme.Signal = .accent
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .regular))
            .foregroundStyle(signal.glyph)
            .frame(width: size, height: size)
            .background(signal.tile, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: Buttons

/// Proton's in-content buttons: radius 8 rectangles with a 1pt edge, never capsules, and a primary that stays purple
/// in every state, even in a window that is not key.
struct ProtonButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, warning, ghost }
    enum Size {
        case small, medium, large

        var height: CGFloat { switch self { case .small: 28; case .medium: 32; case .large: 40 } }
        var padding: CGFloat { switch self { case .small: 10; case .medium: 14; case .large: 18 } }
        var font: Font { self == .large ? .system(size: 14, weight: .medium) : .system(size: 13) }
    }

    var kind: Kind = .secondary
    var size: Size = .medium

    func makeBody(configuration: Configuration) -> some View {
        ProtonButton(configuration: configuration, kind: kind, size: size)
    }

    private struct ProtonButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            configuration.label
                .font(size.font)
                .lineLimit(1)
                .padding(.horizontal, kind == .ghost ? 6 : size.padding)
                .frame(minHeight: kind == .ghost ? nil : size.height)
                .foregroundStyle(text)
                .background(fill(pressed: pressed), in: shape)
                .overlay(shape.strokeBorder(stroke(pressed: pressed)))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }

        private var text: Color {
            switch kind {
            case .primary, .danger: .white
            case .warning: .black
            case .secondary: Theme.text
            case .ghost: Theme.link
            }
        }

        private func fill(pressed: Bool) -> Color {
            switch kind {
            case .primary: pressed ? Theme.interactionActive : hovering ? Theme.interactionHover : Theme.interaction
            case .danger: pressed ? Theme.dangerActive : hovering ? Theme.dangerHover : Theme.danger
            case .warning: pressed ? Theme.warningActive : hovering ? Theme.warningHover : Theme.warning
            case .secondary: pressed ? Theme.secondaryActive : hovering ? Theme.secondaryHover : Theme.canvas
            case .ghost: pressed || hovering ? Theme.rowHover : .clear
            }
        }

        private func stroke(pressed: Bool) -> Color {
            guard kind == .secondary else { return .clear }
            return pressed ? Theme.secondaryBorderActive : hovering ? Theme.secondaryBorderHover : Theme.secondaryBorder
        }
    }
}

extension ButtonStyle where Self == ProtonButtonStyle {
    static func proton(_ kind: ProtonButtonStyle.Kind = .secondary, size: ProtonButtonStyle.Size = .medium) -> ProtonButtonStyle {
        ProtonButtonStyle(kind: kind, size: size)
    }
}

// MARK: Toggles

/// Proton's switch: the knob, not the track, turns purple, with a check mark when on.
struct ProtonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProtonSwitch(configuration: configuration)
    }

    private struct ProtonSwitch: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 12, style: .circular).fill(Theme.canvas)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).inset(by: 0.5).stroke(Theme.field, lineWidth: 1))
                    Circle()
                        .fill(configuration.isOn ? (hovering ? Theme.interactionHover : Theme.interaction)
                                                 : (hovering ? Theme.fieldHover : Theme.field))
                        .frame(width: 22, height: 22)
                        .padding(1)
                        .overlay {
                            if configuration.isOn {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                }
                .frame(width: 40, height: 24)
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .onHover { hovering = $0 && isEnabled }
                .animation(.spring(response: 0.25, dampingFraction: 0.68), value: configuration.isOn)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement(children: .combine)
            .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
            .accessibilityAddTraits(.isToggle)
        }
    }
}

extension ToggleStyle where Self == ProtonToggleStyle {
    static var proton: ProtonToggleStyle { ProtonToggleStyle() }
}

// MARK: Banners

/// Proton's banner: a tinted strip with the icon in the signal color and text that stays readable.
struct ProtonBanner<Action: View>: View {
    enum Kind { case norm, info, success, warning, danger, accent }

    let kind: Kind
    let symbol: String
    let text: Text
    var flat = false
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(accent)
            text.font(.system(size: 13)).foregroundStyle(textColor).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, flat ? 20 : 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: flat ? 0 : Theme.radius, style: .continuous))
        .overlay(alignment: .bottom) { if flat { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    private var background: Color {
        switch kind {
        case .norm: Theme.weak
        case .info: Theme.dynamic(light: 0xE9F5FA, dark: 0x072029)
        case .success: Theme.dynamic(light: 0xE9F6F3, dark: 0x06221B)
        case .warning: Theme.dynamic(light: 0xFFEBCC, dark: 0x4D1B00)
        case .danger: Theme.dynamic(light: 0xF8D6DC, dark: 0x4A111B)
        case .accent: Theme.accentSoft
        }
    }

    private var accent: Color {
        switch kind {
        case .norm: Theme.text
        case .info: Theme.dynamic(light: 0x1C7EA5, dark: 0x4FB1D8)
        case .success: Theme.dynamic(light: 0x18866A, dark: 0x4BB99D)
        case .warning: Theme.dynamic(light: 0xE66300, dark: 0xFFAD33)
        case .danger: Theme.danger
        case .accent: Theme.accent
        }
    }

    private var textColor: Color {
        switch kind {
        case .norm, .danger, .accent: Theme.text
        case .info: Theme.dynamic(light: 0x186382, dark: 0x79C4E1)
        case .success: Theme.dynamic(light: 0x156955, dark: 0x76CAB5)
        case .warning: Theme.dynamic(light: 0xB24E05, dark: 0xFFC164)
        }
    }
}

extension ProtonBanner where Action == EmptyView {
    init(kind: Kind, symbol: String, text: Text, flat: Bool = false) {
        self.init(kind: kind, symbol: symbol, text: text, flat: flat) { EmptyView() }
    }
}

// MARK: Sections

/// Proton's card: a warm grey surface with a thin edge, rows divided by hairlines, a bold title above.
struct ProtonSection<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    var footer: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 16) }
                        row
                    }
                }
            }
            .background(Theme.weak, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
            if let footer {
                footer.font(.system(size: 12)).foregroundStyle(Theme.textWeak).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension ProtonSection where Header == Text {
    init(_ title: LocalizedStringKey, footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: { Text(title) }, footer: footer, content: content)
    }
}

extension ProtonSection where Header == EmptyView {
    init(footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: { EmptyView() }, footer: footer, content: content)
    }
}

/// One row of a section: Proton's padding, and a faint highlight under the pointer.
struct ProtonRow<Content: View>: View {
    var hoverable = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(hoverable && hovering ? Theme.rowHover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A label and its value, as Proton lists settings.
struct ProtonValueRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        ProtonRow {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(Theme.textWeak).multilineTextAlignment(.trailing)
            }
        }
    }
}

/// Proton's search field: a warm grey box, a magnifying glass, a purple edge and ring when focused.
struct ProtonField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var symbol: String? = nil
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.hint) }
            TextField(placeholder, text: $text).textFieldStyle(.plain).focused($focused).onSubmit(onSubmit)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(symbol == nil ? Theme.canvas : Theme.weak, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(focused ? Theme.interaction : (symbol == nil ? Theme.field : .clear), lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: Theme.radius + 3, style: .continuous)
            .stroke(Theme.interaction.opacity(focused ? 0.2 : 0), lineWidth: 3).padding(-2))
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

/// The floating action bar of the approval panels: Liquid Glass, as Proton's composer bar. The reason field and the
/// buttons share one line when they fit; in longer languages the field moves above, and the buttons stay whole.
struct GlassActionBar<Buttons: View>: View {
    @Binding var reason: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ProtonField(placeholder: "Why, for the app (optional)", text: $reason).frame(minWidth: 150, maxWidth: 220)
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .trailing, spacing: 10) {
                    ProtonField(placeholder: "Why, for the app (optional)", text: $reason)
                    HStack(spacing: 10) { buttons }
                }
            }
                .controlSize(.large)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: Theme.floatRadius))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }
}
