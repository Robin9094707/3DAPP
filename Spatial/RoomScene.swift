import SwiftUI
import SceneKit

struct RoomSceneView: UIViewRepresentable {
    var project: ScanProject
    var meshURL: URL?
    var hiddenKinds: Set<ElementKind>
    var dimensions: Bool
    var wireframe: Bool
    var exploded: Double
    var topView: Bool
    var units: DisplayUnits
    @Binding var selected: UUID?
    var resetToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.configure(view, owner: self)
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) { context.coordinator.configure(uiView, owner: self) }
    final class Coordinator: NSObject {
        var owner: RoomSceneView
        var signature = ""
        var lastCameraKey = ""
        var cachedMesh: SCNScene?
        var meshPath: String?
        init(_ owner: RoomSceneView) { self.owner = owner }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let hits = view.hitTest(gesture.location(in: view), options: nil)
            var selected: UUID?
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, let id = UUID(uuidString: name) { selected = id; break }
                    node = current.parent
                }
                if selected != nil { break }
            }
            owner.selected = selected
        }
        func configure(_ view: SCNView, owner: RoomSceneView) {
            self.owner = owner
            let key = "\(owner.project.id)-\(owner.hiddenKinds.map(\.rawValue).sorted())-\(owner.dimensions)-\(owner.wireframe)-\(owner.exploded)-\(String(describing: owner.selected))-\(owner.units.rawValue)"
            let cameraKey = "\(owner.project.id)-\(owner.topView)-\(owner.resetToken)"
            guard key != signature || cameraKey != lastCameraKey else { return }
            let previousCamera = view.pointOfView?.clone()
            let scene = SCNScene()
            let content = SCNNode()
            scene.rootNode.addChildNode(content)
            for element in owner.project.elements where !owner.hiddenKinds.contains(element.kind) {
                let geometry = Self.elementGeometry(element)
                let material = SCNMaterial()
                let selected = owner.selected == element.id
                material.diffuse.contents = selected ? UIColor.systemYellow : Self.color(element.kind)
                material.transparency = element.kind == .wall ? (selected ? 0.95 : 0.55) : element.kind == .floor ? 0.26 : 0.85
                material.isDoubleSided = true
                material.fillMode = owner.wireframe ? .lines : .fill
                material.lightingModel = .physicallyBased
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                node.name = element.id.uuidString
                node.simdTransform = element.matrix
                if owner.exploded > 0 {
                    let center = element.center
                    node.simdPosition += SIMD3(center.x * Float(owner.exploded) * 0.16, element.kind == .furniture ? Float(owner.exploded) * 0.8 : 0, center.z * Float(owner.exploded) * 0.16)
                }
                content.addChildNode(node)
                if owner.dimensions && element.kind != .floor {
                    let label = SceneDrawing.label(owner.units.length(Double(element.dimensions.x)), at: node.simdPosition + SIMD3(0, element.dimensions.y / 2 + 0.08, 0))
                    content.addChildNode(label)
                }
            }
            for measurement in owner.project.measurements {
                for point in measurement.points { content.addChildNode(SceneDrawing.dot(at: point.simd)) }
                for (a,b) in zip(measurement.points, measurement.points.dropFirst()) { content.addChildNode(SceneDrawing.line(from: a.simd, to: b.simd, color: .systemMint)) }
                if measurement.isArea, let first = measurement.points.first, let last = measurement.points.last { content.addChildNode(SceneDrawing.line(from: last.simd, to: first.simd, color: .systemOrange)) }
            }
            if let url = owner.meshURL {
                if meshPath != url.path { cachedMesh = try? SCNScene(url: url, options: nil); meshPath = url.path }
                if let cachedMesh {
                    let node = cachedMesh.rootNode.clone()
                    node.enumerateChildNodes { child, _ in
                        child.geometry = child.geometry?.copy() as? SCNGeometry
                        let material = SCNMaterial(); material.diffuse.contents = UIColor.systemMint
                        material.isDoubleSided = true; material.fillMode = owner.wireframe ? .lines : .fill
                        child.geometry?.materials = [material]
                    }
                    content.addChildNode(node)
                }
            }
            let (min, max) = content.boundingBox
            let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
            let span = Swift.max(2.0, Swift.max(max.x - min.x, Swift.max(max.y-min.y, max.z-min.z)))
            if let previousCamera, cameraKey == lastCameraKey {
                scene.rootNode.addChildNode(previousCamera); view.pointOfView = previousCamera
            } else {
                let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.01; camera.camera?.zFar = 500
                camera.camera?.usesOrthographicProjection = owner.topView
                camera.camera?.orthographicScale = Double(span) * 0.85
                camera.position = owner.topView ? SCNVector3(center.x, center.y + span * 2, center.z + 0.001) : SCNVector3(center.x + span * 1.1, center.y + span * 0.85, center.z + span * 1.1)
                camera.look(at: center)
                scene.rootNode.addChildNode(camera); view.pointOfView = camera
            }
            view.scene = scene
            view.defaultCameraController.target = center
            view.defaultCameraController.inertiaEnabled = true
            signature = key; lastCameraKey = cameraKey
        }
        static func color(_ kind: ElementKind) -> UIColor {
            switch kind { case .wall: return .systemCyan; case .window: return .systemBlue; case .door: return .systemOrange; case .opening: return .systemPink; case .floor: return .systemMint; case .furniture: return .systemIndigo }
        }
        static func elementGeometry(_ e: RoomElement) -> SCNGeometry {
            if e.kind == .floor && e.corners.count >= 3 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: CGFloat(e.corners[0].x), y: CGFloat(e.corners[0].y)))
                for p in e.corners.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) }
                path.close()
                return SCNShape(path: path, extrusionDepth: 0.012)
            }
            return SCNBox(width: CGFloat(Swift.max(e.dimensions.x, 0.02)), height: CGFloat(Swift.max(e.dimensions.y, 0.02)), length: CGFloat(Swift.max(e.dimensions.z, e.kind == .wall ? 0.06 : 0.02)), chamferRadius: 0)
        }
    }
}
