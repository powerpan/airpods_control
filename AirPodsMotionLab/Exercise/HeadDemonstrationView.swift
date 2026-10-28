import AppKit
import SceneKit
import SwiftUI

/// An entirely local, procedural 3D demonstration. The model faces the viewer:
/// +Z is the nose, +Y is up. Semantic left is negative yaw/roll; semantic nod
/// is positive pitch. Mirroring therefore maps to SceneKit (pitch, yaw, -roll).
/// Sensor values never steer this model; the exercise rule supplies its target.
@MainActor
struct HeadDemonstrationView: NSViewRepresentable {
    let yaw: Double
    let pitch: Double
    let roll: Double
    let isPaused: Bool
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.isPlaying = true
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.setAccessibilityLabel("面向你的三维头部示范模型")
        view.setAccessibilityRole(.image)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.update(
            yaw: yaw, pitch: pitch, roll: roll,
            paused: isPaused, reduceMotion: reduceMotion,
            isDark: colorScheme == .dark
        )
        view.setAccessibilityValue("镜像示范：转头 \(Int(yaw.rounded())) 度，低头 \(Int(pitch.rounded())) 度，侧倾 \(Int(roll.rounded())) 度")
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.head.removeAllActions()
        view.isPlaying = false
        view.scene = nil
        view.pointOfView = nil
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        let head = SCNNode()
        let camera = SCNNode()
        private let clay = SCNMaterial()
        private let garment = SCNMaterial()
        private let features = SCNMaterial()
        private var lastTarget: SIMD3<Double>?
        private var lastAppearance: Bool?

        init() {
            configureMaterials()
            buildSculpture()
            buildStudio()
        }

        func update(yaw: Double, pitch: Double, roll: Double, paused: Bool, reduceMotion: Bool, isDark: Bool) {
            if lastAppearance != isDark {
                lastAppearance = isDark
                clay.diffuse.contents = isDark
                    ? NSColor(calibratedRed: 0.49, green: 0.65, blue: 0.67, alpha: 1)
                    : NSColor(calibratedRed: 0.45, green: 0.60, blue: 0.62, alpha: 1)
                garment.diffuse.contents = isDark
                    ? NSColor(calibratedRed: 0.26, green: 0.41, blue: 0.44, alpha: 1)
                    : NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.39, alpha: 1)
            }

            head.isPaused = paused
            guard !paused else { return }
            let target = SIMD3(pitch, yaw, -roll) * (.pi / 180)
            guard target != lastTarget else { return }
            lastTarget = target

            let visibleRotation = head.presentation.eulerAngles
            head.removeAction(forKey: "demonstration")
            head.eulerAngles = visibleRotation
            if reduceMotion {
                head.eulerAngles = SCNVector3(Float(target.x), Float(target.y), Float(target.z))
            } else {
                let action = SCNAction.rotateTo(
                    x: CGFloat(target.x), y: CGFloat(target.y), z: CGFloat(target.z),
                    duration: 2, usesShortestUnitArc: true
                )
                action.timingMode = .easeInEaseOut
                head.runAction(action, forKey: "demonstration")
            }
        }

        private func configureMaterials() {
            for material in [clay, garment, features] {
                // Diffuse clay stays readable without an HDR environment map.
                material.lightingModel = .lambert
                material.specular.contents = NSColor.black
            }
            clay.diffuse.contents = NSColor(calibratedRed: 0.45, green: 0.60, blue: 0.62, alpha: 1)
            garment.diffuse.contents = NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.39, alpha: 1)
            features.diffuse.contents = NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.20, alpha: 1)
        }

        private func buildSculpture() {
            // The shoulders stay fixed. Only the head pivots at the neck, making
            // turn, side tilt and nod visually distinct without a moving target.
            addEllipsoid(to: scene.rootNode, radius: 0.7,
                         scale: SCNVector3(1.48, 0.46, 0.75),
                         position: SCNVector3(0, -0.02, 0), material: garment)
            let neckGeometry = SCNCylinder(radius: 0.22, height: 0.69)
            neckGeometry.radialSegmentCount = 40
            neckGeometry.materials = [clay]
            let neck = SCNNode(geometry: neckGeometry)
            neck.position = SCNVector3(0, 0.35, 0)
            scene.rootNode.addChildNode(neck)

            head.position = SCNVector3(0, 0.52, 0)
            scene.rootNode.addChildNode(head)
            addEllipsoid(to: head, radius: 0.65,
                         scale: SCNVector3(0.82, 1.12, 0.82),
                         position: SCNVector3(0, 0.71, 0), material: clay)

            for side in [Float(-1), Float(1)] {
                addEllipsoid(to: head, radius: 0.10,
                             scale: SCNVector3(0.88, 1.65, 0.7),
                             position: SCNVector3(side * 0.55, 0.65, 0), material: clay)
                addEllipsoid(to: head, radius: 0.033,
                             scale: SCNVector3(1.05, 0.72, 0.48),
                             position: SCNVector3(side * 0.205, 0.83, 0.49), material: features)
            }

            let noseGeometry = SCNCone(topRadius: 0.023, bottomRadius: 0.085, height: 0.20)
            noseGeometry.radialSegmentCount = 32
            noseGeometry.materials = [clay]
            let nose = SCNNode(geometry: noseGeometry)
            nose.eulerAngles.x = .pi / 2
            nose.position = SCNVector3(0, 0.62, 0.52)
            head.addChildNode(nose)

            let mouthGeometry = SCNCapsule(capRadius: 0.012, height: 0.16)
            mouthGeometry.radialSegmentCount = 16
            mouthGeometry.materials = [features]
            let mouth = SCNNode(geometry: mouthGeometry)
            mouth.eulerAngles.z = .pi / 2
            mouth.position = SCNVector3(0, 0.37, 0.475)
            head.addChildNode(mouth)

            let plinthGeometry = SCNCylinder(radius: 0.61, height: 0.08)
            plinthGeometry.radialSegmentCount = 64
            plinthGeometry.materials = [clay]
            let plinth = SCNNode(geometry: plinthGeometry)
            plinth.scale = SCNVector3(1.20, 1, 0.82)
            plinth.position = SCNVector3(0, -0.35, 0)
            scene.rootNode.addChildNode(plinth)
        }

        private func buildStudio() {
            let lens = SCNCamera()
            lens.usesOrthographicProjection = true
            lens.orthographicScale = 1.42
            lens.zNear = 0.1
            lens.zFar = 30
            lens.wantsHDR = false
            lens.screenSpaceAmbientOcclusionIntensity = 0.45
            lens.screenSpaceAmbientOcclusionRadius = 0.2
            camera.camera = lens
            camera.position = SCNVector3(0, 1.02, 5)
            camera.look(at: SCNVector3(0, 0.85, 0))
            scene.rootNode.addChildNode(camera)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 150
            ambient.color = NSColor.white
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            let key = SCNLight()
            key.type = .spot
            key.intensity = 500
            key.temperature = 6500
            key.spotInnerAngle = 40
            key.spotOuterAngle = 90
            key.castsShadow = true
            key.shadowRadius = 7
            key.shadowMapSize = CGSize(width: 1024, height: 1024)
            key.shadowColor = NSColor.black.withAlphaComponent(0.17)
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.position = SCNVector3(-3, 4, 4)
            keyNode.look(at: SCNVector3(0, 0.8, 0))
            scene.rootNode.addChildNode(keyNode)

            let fill = SCNLight()
            fill.type = .omni
            fill.intensity = 150
            fill.color = NSColor(calibratedRed: 0.78, green: 0.88, blue: 1, alpha: 1)
            let fillNode = SCNNode()
            fillNode.light = fill
            fillNode.position = SCNVector3(3, 2, 2)
            scene.rootNode.addChildNode(fillNode)
        }

        private func addEllipsoid(to parent: SCNNode, radius: CGFloat, scale: SCNVector3,
                                  position: SCNVector3, material: SCNMaterial) {
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 48
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.scale = scale
            node.position = position
            parent.addChildNode(node)
        }
    }
}
