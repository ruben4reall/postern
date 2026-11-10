import Foundation

/// A CSS color, its channels from 0 to 1.
struct CSSColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = CSSColor(red: 1, green: 1, blue: 1)
    static let black = CSSColor(red: 0, green: 0, blue: 0)

    /// The color a value names, or nil when it names none (`inherit`, `currentcolor`, a variable, an image).
    static func parse(_ raw: String) -> CSSColor? {
        let value = raw.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        if value == "transparent" { return CSSColor(red: 0, green: 0, blue: 0, alpha: 0) }
        if value.hasPrefix("#") { return hex(value.dropFirst()) }
        if let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let function = value[..<open].trimmingCharacters(in: .whitespaces)
            let inside = value[value.index(after: open)..<value.index(before: value.endIndex)]
            let (channels, alpha) = arguments(inside)
            switch function {
            case "rgb", "rgba":
                guard channels.count == 3 else { return nil }
                let parts = channels.compactMap { channel($0, scale: 255) }
                guard parts.count == 3 else { return nil }
                return CSSColor(red: parts[0], green: parts[1], blue: parts[2], alpha: alpha.flatMap(Self.alpha) ?? 1)
            case "hsl", "hsla":
                guard channels.count == 3, let hue = angle(channels[0]), let saturation = percent(channels[1]),
                      let lightness = percent(channels[2]) else { return nil }
                return hsl(hue, saturation, lightness, alpha: alpha.flatMap(Self.alpha) ?? 1)
            default:
                return nil
            }
        }
        // `#fff` written as a legacy attribute without its hash, as in `bgcolor="fff"`.
        if value.count == 6 || value.count == 3, value.allSatisfy(\.isHexDigit), let color = hex(Substring(value)) {
            return color
        }
        return named[value].flatMap { hex(Substring($0)) }
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

    /// `255, 0, 0, 0.5`, `255 0 0 / 50%`: the channels and the alpha, if any.
    private static func arguments(_ inside: Substring) -> ([String], String?) {
        let halves = inside.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        var channels = halves[0].split { $0 == "," || $0 == " " || $0 == "\t" }.map(String.init)
        var alpha = halves.count == 2 ? halves[1] : nil
        if channels.count == 4 && alpha == nil { alpha = channels.removeLast() }
        return (channels, alpha)
    }

    private static func channel(_ text: String, scale: Double) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { min(max($0 / 100, 0), 1) } }
        return Double(text).map { min(max($0 / scale, 0), 1) }
    }

    private static func alpha(_ text: String) -> Double? { channel(text, scale: 1) }

    private static func percent(_ text: String) -> Double? {
        Double(text.hasSuffix("%") ? String(text.dropLast()) : text).map { min(max($0 / 100, 0), 1) }
    }

    private static func angle(_ text: String) -> Double? {
        for (unit, factor) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi), ("turn", 360.0)] where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count)).map { $0 * factor }
        }
        return Double(text)
    }

    private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double, alpha: Double) -> CSSColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return CSSColor(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha)
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

    /// A font size in points, given the size it inherits; nil when it cannot be told (`calc()`, a variable).
    static func fontSize(_ raw: String, inherited: Double) -> Double? {
        let value = raw.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "inherit", "unset", "revert", "": return inherited
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
        default: return length(value, relativeTo: inherited)
        }
    }

    /// A length in points; `em` and `%` are taken of `reference`.
    static func length(_ raw: String, relativeTo reference: Double) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = value.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let number = Double(digits) else { return nil }
        switch value.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "px": return number
        case "pt": return number * 4 / 3
        case "pc": return number * 16
        case "in": return number * 96
        case "cm": return number * 96 / 2.54
        case "mm": return number * 96 / 25.4
        case "q": return number * 96 / 101.6
        case "em": return number * reference
        case "rem": return number * rootFontSize
        case "%": return number * reference / 100
        case "ex", "ch": return number * reference / 2
        case "vw", "vmax": return number * 8
        case "vh", "vmin": return number * 6
        default: return nil
        }
    }
}
