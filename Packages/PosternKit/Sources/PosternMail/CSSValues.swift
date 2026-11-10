import Foundation

/// A CSS color, its channels from 0 to 1.
struct CSSColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = CSSColor(red: 1, green: 1, blue: 1)
    static let black = CSSColor(red: 0, green: 0, blue: 0)

    enum Parsed: Equatable {
        case color(CSSColor)
        /// `inherit`, `currentcolor`, `unset`, `revert`: the inherited color.
        case inherit
        /// A function no browser this parser knows would draw, such as a color space added later: what it draws
        /// cannot be told, so text in it is not trusted to show.
        case unknown
    }

    /// The color a CSS value names, or nil when the value is not a color (a browser drops the declaration).
    static func parse(_ raw: String) -> CSSColor? {
        if case .color(let color) = read(raw) { return color }
        return nil
    }

    static func read(_ raw: String) -> Parsed? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        switch value {
        case "inherit", "currentcolor", "unset", "revert", "revert-layer": return .inherit
        case "initial": return .color(.black)
        case "transparent": return .color(CSSColor(red: 0, green: 0, blue: 0, alpha: 0))
        default: break
        }
        if value.hasPrefix("#") { return hex(value.dropFirst()).map(Parsed.color) }
        if let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let name = value[..<open].trimmingCharacters(in: .whitespaces)
            let inside = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
            if let color = colorFunction(name, inside) { return .color(color) }
            // A known function with arguments it cannot read is dropped by browsers; any other function is not.
            return known.contains(name) ? nil : .unknown
        }
        if let hex = named[value] ?? system[value] { return Self.hex(Substring(hex)).map(Parsed.color) }
        return nil
    }

    private static let known: Set<String> = [
        "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color", "color-mix", "light-dark",
    ]

    private static func colorFunction(_ name: String, _ inside: String) -> CSSColor? {
        switch name {
        case "light-dark":
            // Proton shows mail in light mode.
            return splitTopLevel(inside, by: ",").first.flatMap(parse)
        case "color-mix":
            return mix(inside)
        default:
            break
        }
        guard let read = arguments(inside), read.0.count == 3 else { return nil }
        let (channels, alphaText) = read
        let alpha: Double
        if let alphaText {
            guard let value = number(alphaText, percentOf: 1) else { return nil }
            alpha = value
        } else {
            alpha = 1
        }
        switch name {
        case "rgb", "rgba", "color":
            let parts = channels.compactMap { number($0, percentOf: 255).map { $0 / 255 } }
            guard parts.count == 3 else { return nil }
            return CSSColor(red: parts[0], green: parts[1], blue: parts[2], alpha: alpha).clamped
        case "hsl", "hsla":
            guard let hue = angle(channels[0]), let s = number(channels[1], percentOf: 100), let l = number(channels[2], percentOf: 100) else { return nil }
            return hsl(hue, s / 100, l / 100, alpha: alpha)
        case "hwb":
            guard let hue = angle(channels[0]), let w = number(channels[1], percentOf: 100), let b = number(channels[2], percentOf: 100) else { return nil }
            return hwb(hue, w / 100, b / 100, alpha: alpha)
        case "oklab":
            guard let l = number(channels[0], percentOf: 1), let a = number(channels[1], percentOf: 0.4), let b = number(channels[2], percentOf: 0.4) else { return nil }
            return oklab(l, a, b, alpha: alpha)
        case "oklch":
            guard let l = number(channels[0], percentOf: 1), let c = number(channels[1], percentOf: 0.4), let h = angle(channels[2]) else { return nil }
            return oklab(l, c * cos(h * .pi / 180), c * sin(h * .pi / 180), alpha: alpha)
        case "lab":
            guard let l = number(channels[0], percentOf: 100), let a = number(channels[1], percentOf: 125), let b = number(channels[2], percentOf: 125) else { return nil }
            return lab(l, a, b, alpha: alpha)
        case "lch":
            guard let l = number(channels[0], percentOf: 100), let c = number(channels[1], percentOf: 150), let h = angle(channels[2]) else { return nil }
            return lab(l, c * cos(h * .pi / 180), c * sin(h * .pi / 180), alpha: alpha)
        default:
            return nil
        }
    }

    /// `color(srgb 1 1 1)` and the other predefined spaces, read as sRGB: close enough to judge contrast.
    private static func arguments(_ inside: String) -> ([String], String?)? {
        var text = inside.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        let halves = splitTopLevel(text, by: "/")
        guard let first = halves.first, halves.count <= 2 else { return nil }
        text = first
        var channels: [String]
        if text.contains(",") {
            // The legacy syntax: commas between every value, and nothing else.
            channels = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard channels.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }), halves.count == 1 else { return nil }
            if channels.count == 4 { return (Array(channels.prefix(3)), channels[3]) }
        } else {
            channels = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if let space = channels.first, ["srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "xyz", "xyz-d50", "xyz-d65"].contains(space) {
                channels.removeFirst()
                channels = channels.map { $0.hasSuffix("%") ? $0 : (Double($0).map { String($0 * 255) } ?? $0) }
            }
        }
        return (channels, halves.count == 2 ? halves[1].trimmingCharacters(in: .whitespaces) : nil)
    }

    /// `color-mix(in srgb, white 30%, black)`, mixed in sRGB.
    private static func mix(_ inside: String) -> CSSColor? {
        let parts = splitTopLevel(inside, by: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[0].hasPrefix("in ") else { return nil }
        func side(_ text: String) -> (CSSColor, Double?)? {
            var words = splitTopLevel(text, by: " ").filter { !$0.isEmpty }
            var weight: Double?
            if let index = words.firstIndex(where: { $0.hasSuffix("%") && Double($0.dropLast()) != nil }) {
                weight = Double(words.remove(at: index).dropLast()).map { $0 / 100 }
            }
            return parse(words.joined(separator: " ")).map { ($0, weight) }
        }
        guard let left = side(parts[1]), let right = side(parts[2]) else { return nil }
        let (a, wa) = left, (b, wb) = right
        let first = wa ?? (wb.map { 1 - $0 } ?? 0.5)
        let second = wb ?? (1 - first)
        let total = first + second
        guard total > 0, total.isFinite else { return nil }
        let p = first / total
        return CSSColor(red: a.red * p + b.red * (1 - p), green: a.green * p + b.green * (1 - p),
                        blue: a.blue * p + b.blue * (1 - p), alpha: a.alpha * p + b.alpha * (1 - p))
    }

    /// The colors of a gradient, as `linear-gradient(#fff, rgb(0 0 0) 40%)` lists them.
    static func stops(inGradient value: String) -> [CSSColor] {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return [] }
        let inside = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
        return splitTopLevel(inside, by: ",").compactMap { part in
            splitTopLevel(part.trimmingCharacters(in: .whitespaces), by: " ").lazy.compactMap(parse).first
        }
    }

    /// Splits at `separator` outside parentheses and quotes.
    static func splitTopLevel(_ text: String, by separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if character == separator, depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return separator == " " ? parts.filter { !$0.isEmpty } : parts
    }

    /// A finite number, or a percentage of `percentOf`. `none` is zero.
    private static func number(_ text: String, percentOf full: Double) -> Double? {
        if text == "none" { return 0 }
        let value: Double?
        if text.hasSuffix("%") { value = Double(text.dropLast()).map { $0 / 100 * full } } else { value = Double(text) }
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func angle(_ text: String) -> Double? {
        if text == "none" { return 0 }
        for (unit, factor) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi), ("turn", 360.0)] where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count)).flatMap { ($0 * factor).isFinite ? $0 * factor : nil }
        }
        return Double(text).flatMap { $0.isFinite ? $0 : nil }
    }

    private var clamped: CSSColor {
        CSSColor(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1), alpha: min(max(alpha, 0), 1))
    }

    private static func hex(_ digits: Substring) -> CSSColor? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded: String
        switch digits.count {
        case 3, 4: expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = String(digits)
        default: return nil
        }
        let numbers = stride(from: 0, to: expanded.count, by: 2).compactMap { offset -> Double? in
            let start = expanded.index(expanded.startIndex, offsetBy: offset)
            return UInt8(expanded[start..<expanded.index(start, offsetBy: 2)], radix: 16).map { Double($0) / 255 }
        }
        guard numbers.count >= 3 else { return nil }
        return CSSColor(red: numbers[0], green: numbers[1], blue: numbers[2], alpha: numbers.count == 4 ? numbers[3] : 1)
    }

    private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double, alpha: Double) -> CSSColor {
        let s = min(max(saturation, 0), 1), l = min(max(lightness, 0), 1)
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return CSSColor(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha).clamped
    }

    private static func hwb(_ hue: Double, _ whiteness: Double, _ blackness: Double, alpha: Double) -> CSSColor {
        let w = min(max(whiteness, 0), 1), b = min(max(blackness, 0), 1)
        if w + b >= 1 {
            let gray = w / (w + b)
            return CSSColor(red: gray, green: gray, blue: gray, alpha: alpha).clamped
        }
        let pure = hsl(hue, 1, 0.5, alpha: alpha)
        func channel(_ c: Double) -> Double { c * (1 - w - b) + w }
        return CSSColor(red: channel(pure.red), green: channel(pure.green), blue: channel(pure.blue), alpha: alpha).clamped
    }

    private static func encoded(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func oklab(_ l: Double, _ a: Double, _ b: Double, alpha: Double) -> CSSColor {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (lc, mc, sc) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        return CSSColor(red: encoded(r), green: encoded(g), blue: encoded(bl), alpha: alpha).clamped
    }

    private static func lab(_ l: Double, _ a: Double, _ b: Double, alpha: Double) -> CSSColor {
        let epsilon = 216.0 / 24389, kappa = 24389.0 / 27
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        let xr = pow(fx, 3) > epsilon ? pow(fx, 3) : (116 * fx - 16) / kappa
        let yr = l > kappa * epsilon ? pow(fy, 3) : l / kappa
        let zr = pow(fz, 3) > epsilon ? pow(fz, 3) : (116 * fz - 16) / kappa
        let (x50, y50, z50) = (xr * 0.96422, yr, zr * 0.82521)
        let x = 0.9554734527042182 * x50 - 0.023098536874261423 * y50 + 0.0632593086610217 * z50
        let y = -0.028369706963208136 * x50 + 1.0099954580058226 * y50 + 0.021041398966943008 * z50
        let z = 0.012314001688319899 * x50 - 0.020507696433808526 * y50 + 1.3303659366080753 * z50
        let r = 3.2409699419045226 * x - 1.537383177570094 * y - 0.4986107602930034 * z
        let g = -0.9692436362808796 * x + 1.8759675015077202 * y + 0.04155505740717559 * z
        let bl = 0.05563007969699366 * x - 0.20397695888897652 * y + 1.0569715142428786 * z
        return CSSColor(red: encoded(r), green: encoded(g), blue: encoded(bl), alpha: alpha).clamped
    }

    /// The HTML rules for old color attributes such as `<font color>` and `bgcolor`, which read almost anything:
    /// `fffffff` is a near white, `0000000` black.
    static func legacy(_ raw: String) -> CSSColor? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.lowercased() == "transparent" { return nil }
        if let hex = named[value.lowercased()] { return Self.hex(Substring(hex)) }
        if value.count == 4, value.hasPrefix("#"), let short = Self.hex(value.dropFirst()) { return short }
        value = String(value.unicodeScalars.map { $0.value > 0xFFFF ? "00" : String($0) }.joined().prefix(128))
        if value.hasPrefix("#") { value.removeFirst() }
        var digits = value.map { $0.isHexDigit && $0.isASCII ? $0 : Character("0") }
        while digits.isEmpty || digits.count % 3 != 0 { digits.append("0") }
        let length = digits.count / 3
        var parts = (0..<3).map { Array(digits[($0 * length)..<(($0 + 1) * length)]) }
        if length > 8 { parts = parts.map { Array($0.suffix(8)) } }
        while parts[0].count > 2, parts.allSatisfy({ $0.first == "0" }) { parts = parts.map { Array($0.dropFirst()) } }
        if parts[0].count > 2 { parts = parts.map { Array($0.prefix(2)) } }
        let numbers = parts.compactMap { UInt8(String($0), radix: 16).map { Double($0) / 255 } }
        guard numbers.count == 3 else { return nil }
        return CSSColor(red: numbers[0], green: numbers[1], blue: numbers[2])
    }

    /// This color painted over `background`.
    func over(_ background: CSSColor) -> CSSColor {
        CSSColor(red: red * alpha + background.red * (1 - alpha), green: green * alpha + background.green * (1 - alpha),
                 blue: blue * alpha + background.blue * (1 - alpha))
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, from 1 (the same) to 21 (black on white).
    func contrast(with other: CSSColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The colors of the system, as a browser draws them in light mode.
    private static let system: [String: String] = [
        "canvas": "ffffff", "canvastext": "000000", "linktext": "0000ee", "visitedtext": "551a8b",
        "activetext": "ff0000", "buttonface": "efefef", "buttontext": "000000", "buttonborder": "767676",
        "field": "ffffff", "fieldtext": "000000", "highlight": "b5d5ff", "highlighttext": "000000",
        "selecteditem": "0064d2", "selecteditemtext": "ffffff", "mark": "ffff00", "marktext": "000000",
        "graytext": "808080", "accentcolor": "6d4aff", "accentcolortext": "ffffff",
    ]

    /// The CSS named colors.
    static let named: [String: String] = {
        let table = """
        aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 \
        black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 \
        chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff \
        darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 \
        darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 \
        darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f \
        darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 \
        dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc \
        ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 \
        honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa \
        lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
        lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 \
        lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 \
        lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff \
        maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db \
        mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc \
        mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 \
        navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 \
        orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 \
        papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 \
        rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 \
        sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd \
        slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 \
        thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 \
        yellow ffff00 yellowgreen 9acd32
        """
        let words = table.split(separator: " ")
        return Dictionary(uniqueKeysWithValues: stride(from: 0, to: words.count - 1, by: 2).map { (String(words[$0]), String(words[$0 + 1])) })
    }()
}

/// Lengths as a desktop window of 800 by 600 points would draw them.
enum CSSLength {
    static let rootFontSize = 16.0

    /// A font size in points, given the size it inherits; nil when the value is not a size.
    static func fontSize(_ raw: String, inherited: Double) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "inherit", "unset", "revert", "revert-layer": return inherited
        case "initial", "medium": return rootFontSize
        case "xx-small": return 9
        case "x-small": return 10
        case "small": return 13
        case "large": return 18
        case "x-large": return 24
        case "xx-large": return 32
        case "xxx-large": return 48
        case "smaller": return inherited / 1.2
        case "larger": return inherited * 1.2
        case "": return nil
        default: return length(value, relativeTo: inherited, font: inherited)
        }
    }

    /// A length in points. `em` is taken of `font`, `%` of `reference`. `calc()`, `min()`, `max()` and `clamp()`
    /// are worked out when their terms are lengths added, subtracted, or scaled by numbers.
    static func length(_ raw: String, relativeTo reference: Double, font: Double = rootFontSize) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let name = String(value[..<open])
            let inside = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
            let arguments = CSSColor.splitTopLevel(inside, by: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            switch name {
            case "calc", "-webkit-calc": return expression(inside, reference: reference, font: font)
            case "min":
                let values = arguments.compactMap { expression($0, reference: reference, font: font) }
                return values.count == arguments.count ? values.min() : nil
            case "max":
                let values = arguments.compactMap { expression($0, reference: reference, font: font) }
                return values.count == arguments.count ? values.max() : nil
            case "clamp":
                let values = arguments.compactMap { expression($0, reference: reference, font: font) }
                guard values.count == 3 else { return nil }
                return max(values[0], min(values[1], values[2]))
            default: return nil
            }
        }
        var end = value.startIndex
        // A number, with an exponent such as 1e-3.
        while end < value.endIndex {
            let character = value[end]
            if character.isNumber || character == "." || character == "-" || character == "+" {
                end = value.index(after: end)
            } else if character == "e", end > value.startIndex, value.index(after: end) < value.endIndex,
                      value[value.index(after: end)].isNumber || "+-".contains(value[value.index(after: end)]) {
                end = value.index(after: end)
            } else {
                break
            }
        }
        guard let number = Double(value[..<end]), number.isFinite else { return nil }
        let unit = String(value[end...]).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "", "px": return number
        case "pt": return number * 4 / 3
        case "pc": return number * 16
        case "in": return number * 96
        case "cm": return number * 96 / 2.54
        case "mm": return number * 96 / 25.4
        case "q": return number * 96 / 101.6
        case "em", "cap", "ic": return number * font
        case "rem", "rlh": return number * rootFontSize
        case "lh": return number * font * 1.2
        case "%": return number * reference / 100
        case "ex", "ch", "rex", "rch": return number * font / 2
        case "vw", "svw", "lvw", "dvw", "vi", "svi", "lvi", "dvi", "cqw", "cqi", "vmax", "svmax", "lvmax", "dvmax", "cqmax": return number * 8
        case "vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb", "cqh", "cqb", "vmin", "svmin", "lvmin", "dvmin", "cqmin": return number * 6
        default: return nil
        }
    }

    /// `16px - 2px`, `2 * 1em`, `100% / 3`: sums of terms, each a length or a length scaled by numbers.
    private static func expression(_ text: String, reference: Double, font: Double) -> Double? {
        var total = 0.0
        var sign = 1.0
        var term = ""
        var depth = 0
        func flush() -> Bool {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            term = ""
            if trimmed.isEmpty { return true }
            var product = 1.0
            var lengths = 0
            for factor in trimmed.split(separator: "*").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = factor.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let head = parts.first else { return false }
                if let number = Double(head), number.isFinite {
                    product *= number
                } else if let length = (head.hasPrefix("(") && head.hasSuffix(")") ? expression(String(head.dropFirst().dropLast()), reference: reference, font: font)
                                        : length(head, relativeTo: reference, font: font)) {
                    product *= length
                    lengths += 1
                } else {
                    return false
                }
                for divisor in parts.dropFirst() {
                    guard let number = Double(divisor), number != 0, number.isFinite else { return false }
                    product /= number
                }
            }
            guard lengths <= 1 else { return false }
            total += sign * product
            return true
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            // + and - with spaces around them, outside parentheses, separate terms.
            if depth == 0, character == "+" || character == "-", index > 0, characters[index - 1] == " ",
               index + 1 < characters.count, characters[index + 1] == " " {
                guard flush() else { return nil }
                sign = character == "+" ? 1 : -1
                continue
            }
            term.append(character)
        }
        guard flush(), total.isFinite else { return nil }
        return total
    }
}
