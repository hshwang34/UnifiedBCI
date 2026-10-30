import CoreGraphics
import Foundation
import simd

/// The stylized head both the Recording screen's montage view and the intro's scalp map
/// draw (brief 003: "the intro's scalp map uses the same head and positions"). Built from
/// code: an ellipsoid skull fitted to the 10-10 table, plus a nose, ears and neck.
///
/// Scene frame (RealityKit): metres, origin at the skull centre, +x the subject's right,
/// +y up, −z the nose. `scene(_:)` maps the table's millimetre frame into it.
enum HeadGeometry {
    /// Least-squares axis-aligned ellipsoid through the 86 table sites (table frame, mm).
    /// Largest residual 5.5 % of the radius, so a site moved onto the surface shifts < 6 mm.
    static let centre = SIMD3<Double>(0.8, -16.5, -16.4)
    static let radii = SIMD3<Double>(89.3, 105.9, 120.5)

    /// Table frame (mm) → scene frame (m). A proper rotation (no mirroring): x stays,
    /// table z (up) becomes y, table y (anterior) becomes −z.
    static func scene(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let d = (p - centre) / 1000
        return SIMD3(d.x, d.z, -d.y)
    }

    /// Skull radii in the scene frame.
    static var sceneRadii: SIMD3<Double> { SIMD3(radii.x, radii.z, radii.y) / 1000 }

    /// A site moved along its direction from the centre onto the skull surface, so a marker
    /// sits on the drawn head (scene frame).
    static func surfacePoint(_ site: StandardPositions.Site) -> SIMD3<Double> {
        let d = scene(site.position)
        let a = sceneRadii
        let k = 1 / sqrt(simd_length_squared(d / a))
        return d * k
    }

    /// Outward surface normal at a skull point (scene frame).
    static func normal(at p: SIMD3<Double>) -> SIMD3<Double> {
        let a = sceneRadii
        return simd_normalize(p / (a * a))
    }

    // Accessory parts, scene frame (metres); positions from the table's own fiducials
    // (nasion 1.5, 85.1, −34.8; LPA/RPA ±82, −29, −41 mm).
    static let noseTip = scene(SIMD3(0.8, 112, -62))
    static let noseBase = scene(SIMD3(0.8, 88, -50))
    static let leftEar = scene(SIMD3(-86, -29, -41))
    static let rightEar = scene(SIMD3(86, -29, -41))
    static let earRadii = SIMD3<Double>(0.010, 0.030, 0.020)   // x thin, tall, deep
    static let neckTop = scene(SIMD3(0.8, -30, -95))
    static let neckRadius = 0.052
    static let neckHeight = 0.12
}

/// An orbit around the head: yaw about the vertical, then pitch up (degrees). The camera
/// sits at R_y(yaw)·R_x(−pitch)·(0, 0, d) looking at the centre. Yaw 0 / pitch 90 is the
/// top view with the nose up and the subject's right on the right (the topoplot convention);
/// yaw 180 / pitch 0 faces the subject.
struct Orbit: Equatable, Sendable {
    var yaw: Double
    var pitch: Double

    static let pitchRange: ClosedRange<Double> = -20...90

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case top, left, right, front, reset
        var id: String { rawValue }
        var title: String { rawValue == "reset" ? "Reset" : rawValue.capitalized }
        var symbol: String {
            switch self {
            case .top: return "arrow.down.to.line"
            case .left: return "arrow.right.to.line"
            case .right: return "arrow.left.to.line"
            case .front: return "person.crop.circle"
            case .reset: return "arrow.counterclockwise"
            }
        }
        /// VoiceOver label for the button.
        var accessibilityLabel: String {
            switch self {
            case .top: return "View from the top"
            case .left: return "View from the left"
            case .right: return "View from the right"
            case .front: return "View from the front"
            case .reset: return "Reset view"
            }
        }
        var orbit: Orbit {
            switch self {
            case .top: return Orbit(yaw: 0, pitch: 90)
            case .left: return Orbit(yaw: -90, pitch: 0)
            case .right: return Orbit(yaw: 90, pitch: 0)
            case .front: return Orbit(yaw: 180, pitch: 0)
            // Front-left and above: the face reads at a glance and the central strip shows.
            case .reset: return Orbit(yaw: -150, pitch: 42)
            }
        }
    }

    static let `default` = Preset.reset.orbit

    /// A drag of (dx, dy) points: yaw wraps to (−180, 180], pitch clamps to `pitchRange`.
    func dragged(by translation: CGSize, degreesPerPoint: Double = 0.45) -> Orbit {
        Orbit(yaw: Self.wrap(yaw - translation.width * degreesPerPoint),
              pitch: min(max(pitch + translation.height * degreesPerPoint, Self.pitchRange.lowerBound), Self.pitchRange.upperBound))
    }

    static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    /// `target` with its yaw moved by whole turns so an animation takes the short way round.
    func nearest(_ target: Orbit) -> Orbit {
        Orbit(yaw: yaw + Self.wrap(target.yaw - yaw), pitch: target.pitch)
    }

    /// How long a change of view animates: 0 under Reduce Motion (decision #18: snap).
    static func transitionDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.6 }

    var rotation: simd_quatd {
        simd_quatd(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: -pitch * .pi / 180, axis: SIMD3(1, 0, 0))
    }
}

/// A perspective camera on an orbit, and the projection the SwiftUI overlay uses to sit
/// labels and buttons on the RealityKit head. Matches RealityKit's PerspectiveCamera with a
/// vertical field of view.
struct HeadCamera: Equatable, Sendable {
    var orbit: Orbit
    var distance: Double = 0.84
    var verticalFOV: Double = 30

    var rotation: simd_quatd { orbit.rotation }
    var position: SIMD3<Double> { rotation.act(SIMD3(0, 0, distance)) }

    /// A scene point → view point (origin top-left), or nil behind the camera.
    func project(_ p: SIMD3<Double>, in size: CGSize) -> CGPoint? {
        let c = rotation.inverse.act(p - position)
        guard c.z < -1e-6, size.height > 0 else { return nil }
        let f = 1 / tan(verticalFOV * .pi / 360)
        let aspect = size.width / size.height
        let nx = f * c.x / -c.z / aspect
        let ny = f * c.y / -c.z
        return CGPoint(x: (nx + 1) / 2 * size.width, y: (1 - ny) / 2 * size.height)
    }

    /// Whether a skull point faces the camera (the skull is convex, so this is its occlusion).
    func faces(_ p: SIMD3<Double>) -> Bool {
        simd_dot(HeadGeometry.normal(at: p), position - p) > 0
    }

    /// How squarely a surface point faces the camera, 0…1 (for dimming markers at the rim).
    func facing(_ p: SIMD3<Double>) -> Double {
        max(0, simd_dot(HeadGeometry.normal(at: p), simd_normalize(position - p)))
    }
}
