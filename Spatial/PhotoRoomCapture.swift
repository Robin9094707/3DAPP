import SwiftUI
import ARKit
import SceneKit
import CoreImage
import ImageIO
import Combine

extension MeshSnapshot {
    static func capture(_ anchors: [ARMeshAnchor]) -> MeshSnapshot {
        var result = MeshSnapshot(vertices: [], faces: [])
        for anchor in anchors {
            let mesh = anchor.geometry
            let offset = UInt32(result.vertices.count)
            for index in 0..<mesh.vertices.count {
                let ptr = mesh.vertices.buffer.contents().advanced(by: mesh.vertices.offset + mesh.vertices.stride * index)
                let p = SIMD4(ptr.load(as: Float.self), ptr.advanced(by: 4).load(as: Float.self), ptr.advanced(by: 8).load(as: Float.self), 1)
                let world = anchor.transform * p
                result.vertices.append(SIMD3(world.x,world.y,world.z))
            }
            for index in 0..<(mesh.faces.count*mesh.faces.indexCountPerPrimitive) {
                let p = mesh.faces.buffer.contents().advanced(by: index*mesh.faces.bytesPerIndex)
                let value = mesh.faces.bytesPerIndex == 2 ? UInt32(p.load(as: UInt16.self)) : p.load(as: UInt32.self)
                result.faces.append(offset+value)
            }
        }
        return result
    }
}

final class PhotoRoomController: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    @Published var imageCount = 0
    @Published var triangles = 0
    @Published var message = "Langsam bewegen und jede Fläche aus mehreren Blickwinkeln erfassen."
    @Published var finishing = false
    @Published var progress = 0.0
    @Published var ready = false
    @Published var failure: String?
    @Published var paused = false
    @Published var result: TexturedRoomModel?
    let quality: RoomPhotoQuality
    let folder: URL
    private let queue = DispatchQueue(label: "eu.rjuhas.spatial.photo-room", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var anchors: [UUID: ARMeshAnchor] = [:]
    private var frames: [TextureDepthFrame] = []
    private var running = false
    private var lastPhotoTime: TimeInterval = -10
    private var previousPose: simd_float4x4?
    private var previousTime: TimeInterval = 0
    private var lastStatus: TimeInterval = 0
    private var savedMesh: MeshSnapshot?
    private var cancelled = false
    weak var view: ARSCNView?
    init(quality: RoomPhotoQuality) {
        self.quality = quality
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoRoom-" + UUID().uuidString)
        super.init()
    }
    func start(_ view: ARSCNView) {
        self.view = view
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { failure = error.localizedDescription; return }
        view.scene = SCNScene(); view.delegate = self
        view.session.delegate = self; view.session.delegateQueue = queue
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.frameSemantics = [.sceneDepth]
        configuration.isAutoFocusEnabled = true
        let candidates = ARWorldTrackingConfiguration.supportedVideoFormats.filter { $0.framesPerSecond == 30 && $0.imageResolution.width <= 3840 }
        if quality == .detail, let format = candidates.max(by: { lhs, rhs in
            lhs.imageResolution.width * lhs.imageResolution.height < rhs.imageResolution.width * rhs.imageResolution.height
        }) { configuration.videoFormat = format }
        // Do not flatten to detected planes: preserve the observed surface shape.
        queue.async { self.running = true }
        view.session.run(configuration)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func suspend() {
        view?.session.pause()
        queue.async { self.running = false }
        paused = true; message = "Aufnahme pausiert. Speichere die erfassten Daten oder starte neu."
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func cancel() {
        view?.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        queue.async {
            self.cancelled = true; self.running = false
            self.anchors.removeAll(); self.frames.removeAll()
            try? FileManager.default.removeItem(at: self.folder)
        }
    }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { remember(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { remember(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { for anchor in anchors { self.anchors.removeValue(forKey: anchor.identifier) } }
    private func remember(_ values: [ARAnchor]) {
        guard running else { return }
        for case let mesh as ARMeshAnchor in values {
            let count = anchors.values.reduce(0) { $0 + $1.geometry.vertices.count } - (anchors[mesh.identifier]?.geometry.vertices.count ?? 0) + mesh.geometry.vertices.count
            if count > quality.vertexLimit {
                running = false
                DispatchQueue.main.async { self.suspend(); self.message = "Detailgrenze erreicht. Der aktuelle Raum kann jetzt gespeichert werden." }
                break
            }
            anchors[mesh.identifier] = mesh
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        running = false
        DispatchQueue.main.async { self.failure = error.localizedDescription; self.suspend() }
    }
    func sessionWasInterrupted(_ session: ARSession) { running = false; DispatchQueue.main.async { self.suspend() } }
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor else { return nil }
        let node = SCNNode(geometry: MeshController.geometry(mesh.geometry)); node.opacity = 0.20; return node
    }
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        node.geometry = MeshController.geometry(mesh.geometry)
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        let pose = frame.camera.transform
        var movementOK = true
        if let previousPose {
            let dt = max(0.001, frame.timestamp-previousTime)
            let speed = simd_distance(PhotoMath.position(pose), PhotoMath.position(previousPose))/Float(dt)
            let cosine = max(-1, min(1, simd_dot(SIMD3(pose.columns.2.x,pose.columns.2.y,pose.columns.2.z), SIMD3(previousPose.columns.2.x,previousPose.columns.2.y,previousPose.columns.2.z))))
            movementOK = speed < 0.65 && acos(cosine)/Float(dt) < 0.85
        }
        previousPose = pose; previousTime = frame.timestamp
        var status = "Gute Aufnahmebedingungen. Bodenkanten und verdeckte Stellen mit erfassen."
        let tracking: Bool
        if case .normal = frame.camera.trackingState { tracking = true } else { tracking = false; status = "Orientierung wird gesucht. Langsam auf strukturierte Flächen richten." }
        let bright = (frame.lightEstimate?.ambientIntensity ?? 1000) > 250
        if !bright { status = "Mehr Licht einschalten. Dunkle Bilder werden nicht übernommen." }
        if !movementOK { status = "Bitte langsamer bewegen. Schnelle Aufnahmen werden übersprungen." }
        let warm = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        if warm { status = "iPhone ist warm. Fotos pausieren, bis es etwas abgekühlt ist." }
        if frames.count >= quality.frameLimit { status = "Fotolimit erreicht. Raum abschließen oder die Geometrie noch vervollständigen." }
        if frame.timestamp-lastStatus > 0.35 {
            lastStatus = frame.timestamp
            let count = anchors.values.reduce(0) { $0 + $1.geometry.faces.count }
            DispatchQueue.main.async { self.message = status; self.triangles = count; self.ready = count > 0 && self.imageCount >= 3 }
        }
        guard tracking, bright, movementOK, !warm, frames.count < quality.frameLimit, frame.timestamp-lastPhotoTime > 0.85, let depth = frame.sceneDepth else { return }
        if let last = frames.last {
            let moved = simd_distance(PhotoMath.position(last.photo.matrix), PhotoMath.position(pose)) > 0.12
            let a = last.photo.matrix.columns.2, b = pose.columns.2
            let rotated = simd_dot(SIMD3(a.x,a.y,a.z), SIMD3(b.x,b.y,b.z)) < 0.985
            guard moved || rotated else { return }
        }
        do {
            let captured = try makeFrame(frame, depth: depth)
            frames.append(captured); lastPhotoTime = frame.timestamp
            let count = frames.count
            DispatchQueue.main.async { self.imageCount = count }
        } catch {
            running = false
            DispatchQueue.main.async { self.failure = "Foto konnte nicht gespeichert werden: \(error.localizedDescription)"; self.suspend() }
        }
    }
    private func makeFrame(_ frame: ARFrame, depth: ARDepthData) throws -> TextureDepthFrame {
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let scale = min(1, CGFloat(quality.imageWidth)/image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filename = "photo-\(frames.count).jpg"
        try context.writeJPEGRepresentation(of: scaled, to: folder.appendingPathComponent(filename), colorSpace: CGColorSpaceCreateDeviceRGB(), options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
        let width = Int(scaled.extent.width), height = Int(scaled.extent.height)
        let k = frame.camera.intrinsics
        let photo = PhotoKeyframe(id: frames.count, filename: filename, pose: RoomElement.matrixValues(frame.camera.transform), width: width, height: height, fx: k[0][0]*Float(scale), fy: k[1][1]*Float(scale), cx: k[2][0]*Float(scale), cy: k[2][1]*Float(scale))
        let buffer = depth.depthMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let dw = CVPixelBufferGetWidth(buffer), dh = CVPixelBufferGetHeight(buffer)
        let bytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpatialError.message("Tiefendaten fehlen.") }
        let confidence = depth.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        var values = [Float](repeating: 0, count: dw*dh)
        for y in 0..<dh {
            let row = base.advanced(by: y*bytes).assumingMemoryBound(to: Float.self)
            for x in 0..<dw {
                var reliable = true
                if let confidence, let cp = CVPixelBufferGetBaseAddress(confidence) {
                    reliable = cp.advanced(by: y*CVPixelBufferGetBytesPerRow(confidence)+x).load(as: UInt8.self) >= 1
                }
                values[y*dw+x] = reliable ? row[x] : 0
            }
        }
        return TextureDepthFrame(photo: photo, depth: values, depthWidth: dw, depthHeight: dh, inverse: simd_inverse(frame.camera.transform), cameraPosition: PhotoMath.position(frame.camera.transform))
    }
    func finish() {
        guard !finishing else { return }
        finishing = true; failure = nil
        view?.session.pause(); UIApplication.shared.isIdleTimerDisabled = false
        queue.async {
            self.running = false
            do {
                let mesh = self.savedMesh ?? MeshSnapshot.capture(Array(self.anchors.values))
                self.savedMesh = mesh; self.anchors.removeAll()
                let model = try RoomTexturing.build(mesh: mesh, frames: self.frames) { value in
                    DispatchQueue.main.async { self.progress = value }
                }
                try JSONEncoder().encode(model).write(to: self.folder.appendingPathComponent("textured-room.json"), options: .atomic)
                DispatchQueue.main.async { self.result = model; self.finishing = false }
            } catch {
                DispatchQueue.main.async { self.failure = error.localizedDescription; self.finishing = false; self.paused = true }
            }
        }
    }
}

struct PhotoRoomCamera: UIViewRepresentable {
    @ObservedObject var controller: PhotoRoomController
    func makeUIView(context: Context) -> ARSCNView { let view = ARSCNView(); controller.start(view); return view }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.session.pause(); UIApplication.shared.isIdleTimerDisabled = false }
}

struct PhotoRoomSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var quality: RoomPhotoQuality = .detail
    @State private var started = false
    var body: some View {
        if started { PhotoRoomScanView(quality: quality) }
        else {
            NavigationStack {
                Form {
                    Section {
                        Label("Dein Raum in echten Farben", systemImage: "viewfinder.circle.fill").font(.title2.bold())
                        Text("Kamerabilder werden auf das LiDAR-Netz gelegt. Danach kannst du frei durch das Modell gehen, Fotostandpunkte öffnen und Ansichten teilen.")
                    }
                    Section("Aufnahmequalität") {
                        Picker("Qualität", selection: $quality) { ForEach(RoomPhotoQuality.allCases) { Text($0.title).tag($0) } }
                        Text("Mehr Details: bis zu 80 Bildstandpunkte mit bis zu 1920 Pixeln Breite. Die tatsächlich verfügbare Kameraauflösung hängt von ARKit ab.").font(.caption)
                    }
                    Section("Für scharfe Texturen") {
                        Text("Licht einschalten, Personen möglichst aus dem Raum lassen. Langsam gehen und jede Fläche auch aus seitlichen Blickwinkeln aufnehmen. Fotos entstehen automatisch bei ausreichend Bewegung, Licht und stabiler Ortung.")
                        Text("Nicht fotografierte oder verdeckte Flächen bleiben neutral. Ein Scan ist kein lückenloses Foto; Spiegel und Glas können unvollständig sein.")
                    }
                    Button("Foto-Raum starten") { started = true }.font(.headline)
                }.navigationTitle("Foto-Raum").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            }
        }
    }
}

struct PhotoRoomScanView: View {
    @StateObject private var controller: PhotoRoomController
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var name = ""
    @State private var discarding = false
    @State private var saving = false
    init(quality: RoomPhotoQuality) { _controller = StateObject(wrappedValue: PhotoRoomController(quality: quality)) }
    var body: some View {
        ZStack {
            PhotoRoomCamera(controller: controller).ignoresSafeArea()
            VStack {
                HStack {
                    Button { discarding = true } label: { Image(systemName: "xmark").frame(width: 44, height: 44).spatialGlass() }.disabled(controller.finishing || saving)
                    Spacer()
                    Label("\(controller.imageCount) Fotos", systemImage: "camera.fill").padding(13).spatialGlass()
                }
                Spacer()
                VStack(spacing: 16) {
                    Text(controller.message).font(.subheadline).multilineTextAlignment(.center)
                    Text("\(controller.triangles.formatted()) Dreiecke").font(.caption).monospacedDigit()
                    if controller.finishing { ProgressView("Bildtexturen berechnen …", value: controller.progress) }
                    else { Button("Raum fertigstellen") { controller.finish() }.buttonStyle(.borderedProminent).disabled(!controller.ready) }
                }.padding(22).spatialGlass()
            }.padding(20)
        }.interactiveDismissDisabled()
            .sheet(isPresented: Binding(get: { controller.result != nil }, set: { _ in })) {
                NavigationStack {
                    Form {
                        TextField("Raumname", text: $name)
                        if let result = controller.result {
                            LabeledContent("Bildtextur vorhanden", value: result.texturedFraction.formatted(.percent.precision(.fractionLength(0))))
                            Text("Der Prozentwert beschreibt nur den Anteil der Dreiecke mit zugeordnetem Foto, nicht die Messgenauigkeit oder die Vollständigkeit des Raums.").font(.caption)
                        }
                        if let failure = controller.failure { Text(failure).foregroundStyle(.red) }
                        Button(saving ? "Speichern …" : "Projekt speichern") { save() }.disabled(saving)
                    }.navigationTitle("Foto-Raum sichern")
                }.interactiveDismissDisabled().presentationDetents([.medium])
            }
            .alert("Hinweis", isPresented: Binding(get: { controller.failure != nil && controller.result == nil }, set: { if !$0 { controller.failure = nil } })) { Button("OK") { controller.failure = nil } } message: { Text(controller.failure ?? "") }
            .confirmationDialog("Aufnahme verwerfen?", isPresented: $discarding, titleVisibility: .visible) { Button("Verwerfen", role: .destructive) { controller.cancel(); dismiss() } }
            .onChange(of: scenePhase) { _, phase in if phase == .background && !controller.finishing && controller.result == nil { controller.suspend() } }
            .onDisappear { controller.cancel() }
    }
    private func save() {
        guard let model = controller.result else { return }
        saving = true
        var p = ScanProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Foto-Raum \(store.projects.count+1)" : name, kind: .photoRoom)
        p.meshVertexCount = model.vertices.count; p.meshFaceCount = model.triangleCount
        p.photoAsset = PhotoAssetInfo(imageCount: model.keyframes.count, texturedFraction: model.texturedFraction, quality: controller.quality.title, modelFile: "textured-room.json", retainedSources: true)
        do { try store.addPhotoProject(p, assets: controller.folder); haptic(); dismiss() }
        catch { controller.failure = error.localizedDescription; saving = false }
    }
}
