import Foundation
import Testing

/// Visual spec §1.1: WCAG 2.x contrast of every token text/background pair, in Light and
/// Dark and with Increase Contrast, read from the colour sets the app actually ships
/// (App/Assets.xcassets). Text needs 4.5:1; UI components and graphics 3:1.
struct ThemeContrastTests {
    struct RGBA { var r, g, b, a: Double }

    enum Mode: String, CaseIterable { case light, dark, lightHigh, darkHigh }

    static let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets")

    /// One token in one appearance, from its colorset's Contents.json.
    static func color(_ name: String, _ mode: Mode) throws -> RGBA {
        let url = assets.appendingPathComponent("\(name).colorset/Contents.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for entry in json["colors"] as! [[String: Any]] {
            let appearances = (entry["appearances"] as? [[String: String]]) ?? []
            let dark = appearances.contains { $0["value"] == "dark" }
            let high = appearances.contains { $0["value"] == "high" }
            guard dark == (mode == .dark || mode == .darkHigh), high == (mode == .lightHigh || mode == .darkHigh) else { continue }
            let c = (entry["color"] as! [String: Any])["components"] as! [String: String]
            func channel(_ k: String) -> Double { Double(UInt8(c[k]!.dropFirst(2), radix: 16)!) / 255 }
            return RGBA(r: channel("red"), g: channel("green"), b: channel("blue"), a: Double(c["alpha"]!)!)
        }
        throw CocoaError(.coderValueNotFound)
    }

    static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        RGBA(r: top.a * top.r + (1 - top.a) * bottom.r, g: top.a * top.g + (1 - top.a) * bottom.g,
             b: top.a * top.b + (1 - top.a) * bottom.b, a: 1)
    }

    static func luminance(_ c: RGBA) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    @Test(arguments: Mode.allCases)
    func textPairsMeetAA(mode: Mode) throws {
        let surface1 = try Self.color("surface1", mode)
        var backgrounds: [(String, RGBA)] = []
        for name in ["canvas", "surface1", "surface2"] { backgrounds.append((name, try Self.color(name, mode))) }
        // Translucent fills sit on surface1 (StatusChip, error banner).
        backgrounds.append(("warningFill", Self.over(try Self.color("warningFill", mode), surface1)))
        // The chip fills StatusChip uses (danger and positive 11 %, info 10 %) and the error
        // banner's 12 % danger wash.
        for (token, alpha, label) in [("danger", 0.11, "dangerChip"), ("positive", 0.11, "positiveChip"),
                                      ("accentInk", 0.10, "infoChip"), ("danger", 0.12, "dangerBanner")] {
            var fill = try Self.color(token, mode); fill.a = alpha
            backgrounds.append((label, Self.over(fill, surface1)))
        }
        for text in ["textPrimary", "textSecondary", "textTertiary", "accentInk"] {
            let fg = try Self.color(text, mode)
            // Chips and banners carry only primary and secondary text (textTertiary is for
            // non-essential text on plain surfaces; accentInk links never sit on a fill).
            let onFill = text == "textPrimary" || text == "textSecondary"
            for (bgName, bg) in backgrounds where onFill || !(bgName == "warningFill" || bgName.hasSuffix("Chip") || bgName.hasSuffix("Banner")) {
                let ratio = Self.contrast(fg, bg)
                #expect(ratio >= 4.5, "\(text) on \(bgName) in \(mode): \(ratio)")
            }
        }
        // White labels on filled controls.
        let fill = try Self.color("accentFill", mode)
        #expect(Self.contrast(Self.white, fill) >= 4.5, "white on accentFill in \(mode)")
        // Matrix numbers on the most-shaded correct cell (alpha cap 0.45 dark / 0.30 light).
        var cell = fill
        cell.a = (mode == .dark || mode == .darkHigh) ? 0.45 : 0.30
        let shaded = Self.over(cell, surface1)
        #expect(Self.contrast(try Self.color("textPrimary", mode), shaded) >= 7, "matrix number in \(mode)")
    }

    @Test(arguments: Mode.allCases)
    func uiAndGraphicsMeetThree(mode: Mode) throws {
        let surface1 = try Self.color("surface1", mode)
        let surface2 = try Self.color("surface2", mode)
        for token in ["warning", "danger", "positive", "accentInk", "accentFill"] {
            let fg = try Self.color(token, mode)
            #expect(Self.contrast(fg, surface1) >= 3, "\(token) on surface1 in \(mode)")
            #expect(Self.contrast(fg, surface2) >= 3, "\(token) on surface2 in \(mode)")
        }
        let chip = Self.over(try Self.color("warningFill", mode), surface1)
        #expect(Self.contrast(try Self.color("warning", mode), chip) >= 3, "warning icon on its chip in \(mode)")
        // Each chip's symbol and border on its own fill.
        for (token, alpha) in [("danger", 0.11), ("positive", 0.11), ("accentInk", 0.10)] {
            var fill = try Self.color(token, mode); fill.a = alpha
            let fg = try Self.color(token, mode)
            #expect(Self.contrast(fg, Self.over(fill, surface1)) >= 3, "\(token) symbol on its chip in \(mode)")
        }
    }

    @Test func highContrastVariantsDiffer() throws {
        #expect(Self.luminance(try Self.color("textSecondary", .lightHigh)) < Self.luminance(try Self.color("textSecondary", .light)))
        #expect(Self.luminance(try Self.color("textSecondary", .darkHigh)) > Self.luminance(try Self.color("textSecondary", .dark)))
        #expect(try Self.color("hairline", .lightHigh).a > Self.color("hairline", .light).a)
    }
}
