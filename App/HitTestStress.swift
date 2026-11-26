import AppKit

/// Debug only (brief 009): `-BCIHitTestStress YES` hit-tests every visible window many times a
/// second, the path a mouse-down takes (NSWindow → NSHostingView.hitTest → SwiftUI re-reading
/// the view graph). It reproduces the 2026-11-26 click crash without clicking and without
/// Accessibility permission. Compiled out of Release.
@MainActor
enum HitTestStress {
    #if DEBUG
    private static var timer: Timer?
    private(set) static var count = 0
    #endif

    static func startIfAsked() {
        #if DEBUG
        guard timer == nil, UserDefaults.standard.bool(forKey: "BCIHitTestStress") else { return }
        let interval = max(0.005, UserDefaults.standard.double(forKey: "BCIHitTestStressInterval").nonZero ?? 0.02)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        #endif
    }

    #if DEBUG
    private static func tick() {
        for window in NSApp.windows where window.isVisible {
            guard let frameView = window.contentView?.superview ?? window.contentView else { continue }
            let b = frameView.bounds
            for _ in 0..<4 {
                let p = NSPoint(x: .random(in: b.minX...max(b.minX, b.maxX - 1)), y: .random(in: b.minY...max(b.minY, b.maxY - 1)))
                _ = frameView.hitTest(p)
                count += 1
            }
        }
    }
    #endif
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
