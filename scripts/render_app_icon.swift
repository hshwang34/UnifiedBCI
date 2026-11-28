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

/// The signal in canvas coordinates (1024 grid): a flat lead-in, one rounded peak at the
/// centre (x 512), a flat tail; it stays inside the ring.
private struct Signal: Shape {
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 330, y: 580))
        p.addLine(to: CGPoint(x: 410, y: 580))
        p.addCurve(to: CGPoint(x: 512, y: 400), control1: CGPoint(x: 450, y: 580), control2: CGPoint(x: 470, y: 400))
        p.addCurve(to: CGPoint(x: 614, y: 580), control1: CGPoint(x: 554, y: 400), control2: CGPoint(x: 574, y: 580))
        p.addLine(to: CGPoint(x: 694, y: 580))
        return p
    }
}

private struct AppIcon: View {
    var body: some View {
        let stroke = StrokeStyle(lineWidth: 36, lineCap: .round, lineJoin: .round)
        let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            // macOS icon grid: an 824 pt continuous squircle centred on the 1024 canvas.
            tile.fill(LinearGradient(colors: [hex(0x0A1018), hex(0x12304F)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            tile.fill(LinearGradient(stops: [.init(color: .white.opacity(0.07), location: 0), .init(color: .white.opacity(0), location: 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            tile.strokeBorder(.white.opacity(0.08), lineWidth: 2)
                .frame(width: 824, height: 824)
            // The scalp seen from above: one heavy ring that survives 16 px.
            Circle()
                .stroke(hex(0xE8F3FF), lineWidth: 40)
                .frame(width: 500, height: 500)
            // The signal: one stroke, quiet before the peak and the accent gradient after it
            // (a hard colour change at x 512, so no cap overlaps at the peak).
            Signal()
                .stroke(LinearGradient(stops: [.init(color: hex(0x6F829B), location: 0), .init(color: hex(0x6F829B), location: 0.5),
                                               .init(color: hex(0x5AA9FF), location: 0.5), .init(color: hex(0x58E0D6), location: 1)],
                                       startPoint: UnitPoint(x: 330 / 1024, y: 0), endPoint: UnitPoint(x: 694 / 1024, y: 0)),
                        style: stroke)
            .frame(width: 1024, height: 1024)
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
