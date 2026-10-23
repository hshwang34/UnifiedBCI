// Renders the flat AppIcon fallback set (macOS 15) from the shapes in
// docs/product/briefs/001-visual-spec.md §4 with SwiftUI's ImageRenderer. No external assets.
//
//     swift scripts/render_app_icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Writes icon_<size>.png for every slot of a macOS app icon set plus Contents.json.
import AppKit
import SwiftUI

private func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
}

/// One calm waveform with a single rounded peak, crossing the circle horizontally.
private struct Wave: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY, w = r.width
        p.move(to: CGPoint(x: r.minX, y: y))
        p.addLine(to: CGPoint(x: r.minX + w * 0.30, y: y))
        p.addCurve(to: CGPoint(x: r.midX, y: y - w * 0.26),
                   control1: CGPoint(x: r.minX + w * 0.40, y: y), control2: CGPoint(x: r.midX - w * 0.08, y: y - w * 0.26))
        p.addCurve(to: CGPoint(x: r.minX + w * 0.70, y: y),
                   control1: CGPoint(x: r.midX + w * 0.08, y: y - w * 0.26), control2: CGPoint(x: r.minX + w * 0.60, y: y))
        p.addLine(to: CGPoint(x: r.maxX, y: y))
        return p
    }
}

private struct AppIcon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt continuous squircle centred on the 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [hex(0x0A1018), hex(0x12304F)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            // Layer 1: the scalp seen from above.
            Circle()
                .stroke(hex(0xE8F3FF, 0.9), lineWidth: 14)
                .frame(width: 553, height: 553)
            // Layer 2: the waveform; left half quiet, right half the accent gradient, with a glow.
            let wave = Wave().stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
            ZStack {
                wave.fill(hex(0xE8F3FF, 0.35))
                    .mask(HStack(spacing: 0) { Color.black; Color.clear })
                wave.fill(LinearGradient(colors: [hex(0x5AA9FF), hex(0x58E0D6)], startPoint: .leading, endPoint: .trailing))
                    .mask(HStack(spacing: 0) { Color.clear; Color.black })
                    .shadow(color: hex(0x58E0D6, 0.3), radius: 24)
            }
            .frame(width: 600, height: 600)
            // Layer 3: one electrode at the upper right of the circle.
            Circle()
                .fill(hex(0x58E0D6))
                .frame(width: 28 * 2, height: 28 * 2)
                .offset(x: 276.5 * cos(.pi / 4), y: -276.5 * sin(.pi / 4))
        }
        .frame(width: 1024, height: 1024)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
MainActor.assumeIsolated {
    for pixels in Set(slots.map { $0.points * $0.scale }).sorted() {
        let renderer = ImageRenderer(content: AppIcon())
        renderer.scale = CGFloat(pixels) / 1024
        guard let cg = renderer.cgImage else { fatalError("render failed at \(pixels)") }
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        try! png.write(to: out.appendingPathComponent("icon_\(pixels).png"))
    }
}
for slot in slots {
    images.append(["idiom": "mac", "size": "\(slot.points)x\(slot.points)", "scale": "\(slot.scale)x",
                   "filename": "icon_\(slot.points * slot.scale).png"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) slots to \(out.path)")
