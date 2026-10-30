import RealityKit
import SwiftUI

/// The stylized head (brief 003, decision #16): RealityKit draws the procedural head, and a
/// SwiftUI overlay draws everything that must be legible, focusable or animated (electrodes,
/// labels, particles), placed with the same camera maths (`HeadCamera.project`).
///
/// Animatable on the orbit: SwiftUI interpolates yaw and pitch, so the RealityKit camera and
/// the overlay move together frame by frame. With no animation (Reduce Motion) it snaps.
struct HeadStage<Overlay: View>: View, @preconcurrency Animatable {
    var orbit: Orbit
    @ViewBuilder var overlay: (HeadCamera, CGSize) -> Overlay

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(orbit.yaw, orbit.pitch) }
        set { orbit = Orbit(yaw: newValue.first, pitch: newValue.second) }
    }

    var body: some View {
        let camera = HeadCamera(orbit: orbit)
        GeometryReader { geo in
            ZStack {
                HeadRealityView(camera: camera)
                    .accessibilityHidden(true)
                overlay(camera, geo.size)
            }
        }
    }
}

/// The RealityKit part: skull, nose, ears and neck from generated meshes (no model files,
/// so the bundle stays small), lit by a light that rides with the camera.
private struct HeadRealityView: View {
    let camera: HeadCamera
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RealityView { content in
            content.add(HeadModel.make(dark: scheme == .dark))
            let cam = Entity()
            cam.name = HeadModel.cameraName
            var lens = PerspectiveCameraComponent()
            lens.fieldOfViewInDegrees = Float(camera.verticalFOV)
            lens.near = 0.05
            lens.far = 3
            cam.components.set(lens)
            let key = DirectionalLight()
            key.light.intensity = 2600
            key.light.color = .white
            key.orientation = simd_quatf(angle: -.pi / 7, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 9, axis: [0, 1, 0])
            cam.addChild(key)
            content.add(cam)
            HeadModel.place(cam, camera)
        } update: { content in
            if let cam = content.entities.first(where: { $0.name == HeadModel.cameraName }) {
                HeadModel.place(cam, camera)
            }
        }
        // Rebuild the materials when the appearance changes.
        .id(scheme)
    }
}

@MainActor
enum HeadModel {
    static let cameraName = "camera"

    static func place(_ cam: Entity, _ camera: HeadCamera) {
        let q = camera.rotation
        cam.transform = Transform(scale: .one,
                                  rotation: simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real)),
                                  translation: SIMD3<Float>(camera.position))
    }

    static func make(dark: Bool) -> Entity {
        let root = Entity()
        let skin = material(dark ? NSColor(red: 0.23, green: 0.27, blue: 0.34, alpha: 1) : NSColor(red: 0.86, green: 0.89, blue: 0.93, alpha: 1))
        let shade = material(dark ? NSColor(red: 0.19, green: 0.22, blue: 0.28, alpha: 1) : NSColor(red: 0.78, green: 0.82, blue: 0.87, alpha: 1))

        // Skull: a unit sphere scaled to the fitted ellipsoid.
        let skull = ModelEntity(mesh: .generateSphere(radius: 1), materials: [skin])
        skull.scale = SIMD3<Float>(HeadGeometry.sceneRadii)
        root.addChild(skull)

        // Nose: a cone from the base towards the tip.
        let base = SIMD3<Float>(HeadGeometry.noseBase), tip = SIMD3<Float>(HeadGeometry.noseTip)
        let axis = tip - base
        let nose = ModelEntity(mesh: .generateCone(height: simd_length(axis), radius: 0.016), materials: [skin])
        nose.position = (base + tip) / 2
        nose.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(axis))
        root.addChild(nose)

        for centre in [HeadGeometry.leftEar, HeadGeometry.rightEar] {
            let ear = ModelEntity(mesh: .generateSphere(radius: 1), materials: [shade])
            ear.scale = SIMD3<Float>(HeadGeometry.earRadii)
            ear.position = SIMD3<Float>(centre)
            root.addChild(ear)
        }

        let neck = ModelEntity(mesh: .generateCylinder(height: Float(HeadGeometry.neckHeight), radius: Float(HeadGeometry.neckRadius)), materials: [shade])
        neck.position = SIMD3<Float>(HeadGeometry.neckTop) - [0, Float(HeadGeometry.neckHeight) / 2, 0]
        root.addChild(neck)
        return root
    }

    private static func material(_ color: NSColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: 0.55)
        m.metallic = .init(floatLiteral: 0)
        m.clearcoat = .init(floatLiteral: 0.25)
        return m
    }
}
