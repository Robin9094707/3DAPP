import SwiftUI
import ARKit
import SceneKit
import Combine

struct MeshSnapshot: Sendable {
    var vertices: [SIMD3<Float>]
    var faces: [UInt32]
    func objData() -> Data {
        var text = "# RJ Spatial LiDAR mesh\n# Units: meters; right-handed ARKit world coordinates\no SpatialMesh\n"
        for v in vertices { text += "v \(v.x) \(v.y) \(v.z)\n" }
        for i in stride(from: 0, to: faces.count, by: 3) { text += "f \(faces[i]+1) \(faces[i+1]+1) \(faces[i+2]+1)\n" }
        return Data(text.utf8)
    }
}

final class MeshController: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var status = "Bewege dich langsam um die Oberflächen herum."
    @Published var failure: String?
    @Published var limited = false
    weak var view: ARSCNView?
    private var anchors: [UUID: ARMeshAnchor] = [:]
    private let lock = NSLock()
    private var accepting = true
    private let maximumVertices = 400_000
    func start(_ view: ARSCNView) {
        self.view = view; view.scene = SCNScene(); view.delegate = self
        view.session.delegate = self; view.session.delegateQueue = .main
        view.automaticallyUpdatesLighting = true
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) ? .meshWithClassification : .mesh
        configuration.planeDetection = [.horizontal, .vertical]
        view.session.run(configuration)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func stop() { view?.session.pause(); UIApplication.shared.isIdleTimerDisabled = false }
    func session(_ session: ARSession, didFailWithError error: Error) { failure = error.localizedDescription }
    func sessionWasInterrupted(_ session: ARSession) { status = "Scan unterbrochen. Vorhandene Geometrie kann gespeichert werden."; stop() }
    func sessionInterruptionEnded(_ session: ARSession) { status = "Bitte den vorhandenen Scan speichern und anschließend einen neuen starten." }
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor, remember(mesh) else { return nil }
        return SCNNode(geometry: Self.geometry(mesh.geometry))
    }
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor, remember(mesh) else { return }
        node.geometry = Self.geometry(mesh.geometry)
    }
    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        lock.lock(); anchors.removeValue(forKey: anchor.identifier); lock.unlock()
        publishCounts()
    }
    private func remember(_ anchor: ARMeshAnchor) -> Bool {
        lock.lock()
        guard accepting else { lock.unlock(); return false }
        let total = anchors.values.reduce(0) { $0 + $1.geometry.vertices.count } - (anchors[anchor.identifier]?.geometry.vertices.count ?? 0) + anchor.geometry.vertices.count
        if total > maximumVertices {
            accepting = false; lock.unlock()
            DispatchQueue.main.async { self.limited = true; self.status = "Detailgrenze erreicht. Speichere diesen Scan und starte bei Bedarf einen weiteren."; self.stop() }
            return false
        }
        anchors[anchor.identifier] = anchor
        lock.unlock(); publishCounts(); return true
    }
    private func publishCounts() {
        lock.lock()
        let vertices = anchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
        let faces = anchors.values.reduce(0) { $0 + $1.geometry.faces.count }
        lock.unlock()
        DispatchQueue.main.async { self.vertexCount = vertices; self.faceCount = faces }
    }
    static func geometry(_ mesh: ARMeshGeometry) -> SCNGeometry {
        let vertex = mesh.vertices
        let source = SCNGeometrySource(data: Data(bytes: vertex.buffer.contents(), count: vertex.buffer.length), semantic: .vertex, vectorCount: vertex.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: vertex.offset, dataStride: vertex.stride)
        let faces = mesh.faces
        let data = Data(bytes: faces.buffer.contents(), count: faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex)
        let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial(); material.diffuse.contents = UIColor.systemMint; material.lightingModel = .constant
        material.fillMode = .lines; material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
    func snapshot() -> MeshSnapshot {
        stop()
        lock.lock(); accepting = false
        let copied = Array(anchors.values)
        lock.unlock()
        var result = MeshSnapshot(vertices: [], faces: [])
        for anchor in copied {
            let mesh = anchor.geometry
            let offset = UInt32(result.vertices.count)
            for index in 0..<mesh.vertices.count {
                let ptr = mesh.vertices.buffer.contents().advanced(by: mesh.vertices.offset + mesh.vertices.stride * index)
                let x = ptr.load(as: Float.self), y = ptr.advanced(by: 4).load(as: Float.self), z = ptr.advanced(by: 8).load(as: Float.self)
                let v = anchor.transform * SIMD4(x, y, z, 1)
                result.vertices.append(SIMD3(v.x, v.y, v.z))
            }
            for index in 0..<(mesh.faces.count * mesh.faces.indexCountPerPrimitive) {
                let ptr = mesh.faces.buffer.contents().advanced(by: index * mesh.faces.bytesPerIndex)
                let value = mesh.faces.bytesPerIndex == 2 ? UInt32(ptr.load(as: UInt16.self)) : ptr.load(as: UInt32.self)
                result.faces.append(offset + value)
            }
        }
        return result
    }
}

struct MeshCamera: UIViewRepresentable {
    @ObservedObject var controller: MeshController
    func makeUIView(context: Context) -> ARSCNView { let view = ARSCNView(); controller.start(view); return view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) { uiView.session.pause(); UIApplication.shared.isIdleTimerDisabled = false }
}

struct MeshScannerView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MeshController()
    @State private var naming = false
    @State private var name = ""
    @State private var saving = false
    @State private var cachedSnapshot: MeshSnapshot?
    @State private var saveError: String?
    @State private var discard = false
    var body: some View {
        ZStack {
            MeshCamera(controller: controller).ignoresSafeArea()
            VStack {
                HStack {
                    Button { discard = true } label: { Image(systemName: "xmark").frame(width: 44, height: 44).spatialGlass() }.disabled(saving).accessibilityLabel("Scan schließen")
                    Spacer()
                    Label("LiDAR Mesh", systemImage: "cube.transparent").font(.headline).padding(14).spatialGlass()
                }
                Spacer()
                VStack(spacing: 18) {
                    HStack {
                        VStack { Text(controller.vertexCount.formatted()).font(.title2.bold()); Text("Punkte").font(.caption) }.frame(maxWidth: .infinity)
                        VStack { Text(controller.faceCount.formatted()).font(.title2.bold()); Text("Dreiecke").font(.caption) }.frame(maxWidth: .infinity)
                    }
                    Text(controller.status).font(.caption).multilineTextAlignment(.center)
                    if saving { ProgressView("3D-Netz speichern …") }
                    else {
                        Button { naming = true } label: { Label("Scan speichern", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity).padding(14) }.buttonStyle(.borderedProminent).disabled(controller.faceCount == 0)
                    }
                    Text("Untexturiertes Netz · Export als OBJ in Metern").font(.caption2).foregroundStyle(.secondary)
                }.padding(22).spatialGlass()
            }.padding(20)
        }.interactiveDismissDisabled()
            .onDisappear { controller.stop() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { controller.stop(); controller.status = "Scan pausiert. Speichere die bisher erfassten Oberflächen." } }
            .alert("3D-Scan benennen", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Speichern") { save() }
                Button("Abbrechen", role: .cancel) {}
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("Erneut versuchen") { save() }
                Button("OK", role: .cancel) {}
            } message: { Text(saveError ?? "") }
            .alert("LiDAR-Sitzung beendet", isPresented: Binding(get: { controller.failure != nil }, set: { if !$0 { controller.failure = nil } })) { Button("OK") { controller.failure = nil } } message: { Text(controller.failure ?? "") }
            .confirmationDialog("3D-Scan verwerfen?", isPresented: $discard, titleVisibility: .visible) { Button("Verwerfen", role: .destructive) { dismiss() } }
    }
    private func save() {
        saving = true
        Task { @MainActor in
            await Task.yield()
            let snapshot = cachedSnapshot ?? controller.snapshot()
            cachedSnapshot = snapshot
            let data = await Task.detached(priority: .userInitiated) { snapshot.objData() }.value
            var project = ScanProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "3D-Scan \(store.projects.count + 1)" : name, kind: .mesh)
            project.meshVertexCount = snapshot.vertices.count; project.meshFaceCount = snapshot.faces.count / 3
            do { _ = try store.add(project, mesh: data); haptic(); dismiss() }
            catch { saveError = error.localizedDescription; saving = false }
        }
    }
}
