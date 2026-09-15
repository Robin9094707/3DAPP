import SwiftUI
import SceneKit
import Combine
import ImageIO

@MainActor final class PhotoSceneController: NSObject, ObservableObject {
    @Published var model: TexturedRoomModel?
    @Published var loading = true
    @Published var failure: String?
    @Published var walking = false
    @Published var wireframe = false
    weak var view: SCNView?
    private let camera = SCNNode()
    private let content = SCNNode()
    private var center = SCNVector3Zero
    private var span: Float = 2
    private var minBound = SIMD3<Float>(repeating: -10)
    private var maxBound = SIMD3<Float>(repeating: 10)
    private var displayLink: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var movement = CGSize.zero
    private var loadTask: Task<Void, Never>?
    private var lookGesture: UIPanGestureRecognizer?

    func attach(_ view: SCNView, project: ScanProject, folder: URL) {
        self.view = view
        view.backgroundColor = UIColor(red: 0.035, green: 0.055, blue: 0.08, alpha: 1)
        view.scene = SCNScene(); view.scene?.rootNode.addChildNode(content)
        view.scene?.rootNode.addChildNode(camera)
        camera.camera = SCNCamera(); camera.camera?.zNear = 0.025; camera.camera?.zFar = 200
        view.pointOfView = camera
        view.antialiasingMode = .multisampling4X; view.preferredFramesPerSecond = 30
        view.allowsCameraControl = true
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(look(_:)))
        gesture.isEnabled = false; view.addGestureRecognizer(gesture); lookGesture = gesture
        loadTask = Task {
            do {
                guard let asset = project.photoAsset else { throw SpatialError.message("Fotomodell fehlt.") }
                if project.kind == .photoRoom {
                    let url = folder.appendingPathComponent(asset.modelFile)
                    let model = try await Task.detached(priority: .userInitiated) {
                        let result = try JSONDecoder().decode(TexturedRoomModel.self, from: Data(contentsOf: url))
                        try result.validate(); return result
                    }.value
                    try Task.checkCancellation()
                    self.model = model
                    buildRoom(model, folder: folder)
                    view.autoenablesDefaultLighting = false
                } else {
                    let url = folder.appendingPathComponent(asset.modelFile)
                    let scene = try await Task.detached(priority: .userInitiated) { try SCNScene(url: url, options: nil) }.value
                    try Task.checkCancellation()
                    for node in scene.rootNode.childNodes { content.addChildNode(node) }
                    view.autoenablesDefaultLighting = true
                }
                updateBounds(); reset()
                loading = false
            } catch is CancellationError { }
            catch { failure = error.localizedDescription; loading = false }
        }
    }
    private func buildRoom(_ model: TexturedRoomModel, folder: URL) {
        for batch in model.batches {
            let vertices = batch.indices.map { model.vertices[Int($0)].simd }
            let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x,$0.y,$0.z) })
            let uv = stride(from: 0, to: batch.uv.count, by: 2).map { CGPoint(x: CGFloat(batch.uv[$0]), y: CGFloat(batch.uv[$0+1])) }
            let texture = SCNGeometrySource(textureCoordinates: uv)
            let indices = (0..<vertices.count).map { UInt32($0) }
            let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let faces = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: vertices.count/3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [source, texture], elements: [faces])
            let material = SCNMaterial(); material.lightingModel = .constant; material.isDoubleSided = true
            if batch.frameIndex >= 0 { material.diffuse.contents = folder.appendingPathComponent(model.keyframes[batch.frameIndex].filename) }
            else { material.diffuse.contents = UIColor(white: 0.35, alpha: 1) }
            material.diffuse.wrapS = .clamp; material.diffuse.wrapT = .clamp
            geometry.materials = [material]
            content.addChildNode(SCNNode(geometry: geometry))
        }
    }
    private func updateBounds() {
        let bounds = content.boundingBox
        minBound = SIMD3(bounds.min.x,bounds.min.y,bounds.min.z)
        maxBound = SIMD3(bounds.max.x,bounds.max.y,bounds.max.z)
        center = SCNVector3((minBound.x+maxBound.x)/2, (minBound.y+maxBound.y)/2, (minBound.z+maxBound.z)/2)
        let d = maxBound-minBound
        span = max(1, max(d.x,max(d.y,d.z)))
        view?.defaultCameraController.target = center
        view?.defaultCameraController.inertiaEnabled = false
    }
    func reset() {
        walking = false; movement = .zero; stopMovement()
        lookGesture?.isEnabled = false
        view?.allowsCameraControl = true
        camera.position = SCNVector3(center.x + span*0.95, center.y + span*0.65, center.z + span*0.95)
        camera.look(at: center); view?.pointOfView = camera
    }
    func setWalking(_ value: Bool) {
        movement = .zero; stopMovement(); walking = value
        lookGesture?.isEnabled = value
        view?.allowsCameraControl = !value
        if value, let first = model?.keyframes.first {
            camera.simdTransform = first.matrix; view?.pointOfView = camera
        } else if !value { reset() }
    }
    func visit(_ frame: PhotoKeyframe) {
        movement = .zero; stopMovement(); walking = true
        lookGesture?.isEnabled = true
        view?.allowsCameraControl = false
        camera.simdTransform = frame.matrix; view?.pointOfView = camera
    }
    func toggleWireframe() {
        wireframe.toggle()
        content.enumerateChildNodes { node, _ in node.geometry?.materials.forEach { $0.fillMode = self.wireframe ? .lines : .fill } }
    }
    @objc private func look(_ gesture: UIPanGestureRecognizer) {
        guard walking else { return }
        let translation = gesture.translation(in: view)
        camera.eulerAngles.y -= Float(translation.x)*0.004
        camera.eulerAngles.x = max(-1.35, min(1.35, camera.eulerAngles.x-Float(translation.y)*0.004))
        camera.eulerAngles.z = 0
        gesture.setTranslation(.zero, in: view)
    }
    func move(_ delta: CGSize) {
        movement = delta
        if delta == .zero { stopMovement() }
        else if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFramesPerSecond = 30; link.add(to: .main, forMode: .common)
            displayLink = link; lastTime = 0
        }
    }
    @objc private func step(_ link: CADisplayLink) {
        guard walking else { stopMovement(); return }
        let dt = lastTime == 0 ? 1.0/30 : min(link.timestamp-lastTime,0.1)
        lastTime = link.timestamp
        let yaw = camera.eulerAngles.y
        let forward = SIMD3<Float>(-sin(yaw),0,-cos(yaw))
        let right = SIMD3<Float>(cos(yaw),0,-sin(yaw))
        var next = camera.simdPosition + (right*Float(movement.width)-forward*Float(movement.height))*Float(dt)*1.0
        next.x = max(minBound.x-2, min(maxBound.x+2,next.x))
        next.z = max(minBound.z-2, min(maxBound.z+2,next.z))
        camera.simdPosition = next
    }
    func changeHeight(_ amount: Float) { camera.position.y = max(minBound.y+0.05, min(maxBound.y+2,camera.position.y+amount)) }
    func stopMovement() { displayLink?.invalidate(); displayLink = nil; lastTime = 0; movement = .zero }
    func dispose() { loadTask?.cancel(); stopMovement() }
    func snapshot() throws -> URL {
        guard !loading, let view, let data = view.snapshot().pngData() else { throw SpatialError.message("Die Ansicht ist noch nicht bereit.") }
        let url = try Exporter.temporaryURL("RJ-Spatial-Ansicht.png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct PhotoSceneSurface: UIViewRepresentable {
    @ObservedObject var controller: PhotoSceneController
    var project: ScanProject
    var folder: URL
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); controller.attach(view, project: project, folder: folder); return view
    }
    func updateUIView(_ view: SCNView, context: Context) {}
    static func dismantleUIView(_ view: SCNView, coordinator: ()) { view.isPlaying = false }
}

struct WalkJoystick: View {
    var onMove: (CGSize) -> Void
    @GestureState private var offset = CGSize.zero
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).overlay(Circle().stroke(.white.opacity(0.25)))
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").foregroundStyle(.white.opacity(0.5))
            Circle().fill(SpatialStyle.mint).frame(width: 36, height: 36).offset(offset)
        }.frame(width: 110, height: 110)
            .gesture(DragGesture(minimumDistance: 0).updating($offset) { value, state, _ in
                state = clipped(value.translation)
            }.onChanged { value in let point = clipped(value.translation); onMove(CGSize(width: point.width/35,height: point.height/35)) }.onEnded { _ in onMove(.zero) })
            .accessibilityLabel("Bewegungssteuerung für den Rundgang")
    }
    private func clipped(_ value: CGSize) -> CGSize {
        let factor = min(1, 35/max(1,hypot(value.width,value.height)))
        return CGSize(width: value.width*factor, height: value.height*factor)
    }
}

struct PhotoProjectViewer: View {
    var project: ScanProject
    var folder: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PhotoSceneController()
    @State private var share: SharePayload?
    @State private var gallery = false
    @State private var quickLook = false
    @State private var exporting = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ZStack {
                PhotoSceneSurface(controller: controller, project: project, folder: folder).ignoresSafeArea(edges: .bottom)
                if controller.loading { ProgressView("3D-Modell laden …").padding(20).spatialGlass() }
                VStack(spacing: 12) {
                    if !controller.loading {
                        HStack {
                            if project.kind == .photoRoom {
                                Button { controller.setWalking(!controller.walking) } label: { Label(controller.walking ? "Modell" : "Rundgang", systemImage: controller.walking ? "cube" : "figure.walk") }
                            }
                            Spacer()
                            Button { controller.reset() } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("Ansicht zurücksetzen")
                            Button { controller.toggleWireframe() } label: { Image(systemName: "triangle") }.accessibilityLabel("Drahtgitter umschalten")
                        }.padding(16).spatialGlass()
                    }
                    Spacer()
                    if controller.walking {
                        HStack(alignment: .bottom) {
                            WalkJoystick { controller.move($0) }
                            Spacer()
                            VStack(spacing: 15) {
                                Button { controller.changeHeight(0.2) } label: { Image(systemName: "arrow.up").frame(width: 44,height: 38) }.accessibilityLabel("Blickpunkt anheben")
                                Button { controller.changeHeight(-0.2) } label: { Image(systemName: "arrow.down").frame(width: 44,height: 38) }.accessibilityLabel("Blickpunkt absenken")
                            }.spatialGlass()
                        }
                        Text("Mit dem Daumen gehen · im Bild umsehen · freie Bewegung ohne Wandkollision").font(.caption2).padding(9).spatialGlass()
                    }
                    if let frames = controller.model?.keyframes, !frames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(frames) { frame in
                                    Button { controller.visit(frame) } label: {
                                        PhotoThumbnail(url: folder.appendingPathComponent(frame.filename), rotate: true)
                                            .frame(width: 54,height: 70).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                    }.accessibilityLabel("Fotostandpunkt \(frame.id+1)")
                                }
                            }
                        }
                    }
                }.padding(16)
                if exporting { ProgressView("Export vorbereiten …").padding(24).spatialGlass() }
            }.navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Ansicht als Bild teilen", systemImage: "photo") { do { share = SharePayload(urls: [try controller.snapshot()]) } catch { self.error = error.localizedDescription } }
                            if project.kind == .photoRoom {
                                Button("Aufnahmefotos ansehen", systemImage: "photo.on.rectangle") { controller.stopMovement(); gallery = true }
                                Button("Texturiertes Modell · OBJ + Bilder") { exportRoom() }
                            } else {
                                Button("Objekt in AR ansehen", systemImage: "arkit") { quickLook = true }
                                Button("3D-Objekt · USDZ") { share = SharePayload(urls: [folder.appendingPathComponent("object.usdz")]) }
                            }
                        } label: { Image(systemName: "square.and.arrow.up") }.disabled(controller.loading || exporting)
                    }
                }
        }.sheet(item: $share) { ShareSheet(urls: $0.urls) }
            .sheet(isPresented: $gallery) { PhotoGallery(frames: controller.model?.keyframes ?? [], folder: folder) }
            .sheet(isPresented: $quickLook) { ModelQuickLook(url: folder.appendingPathComponent("object.usdz")) }
            .alert("Hinweis", isPresented: Binding(get: { error != nil || controller.failure != nil }, set: { if !$0 { error = nil; controller.failure = nil } })) { Button("OK") { error = nil; controller.failure = nil } } message: { Text(error ?? controller.failure ?? "") }
            .onChange(of: scenePhase) { _, phase in if phase != .active { controller.stopMovement() } }
            .onDisappear { controller.dispose() }
    }
    private func exportRoom() {
        guard let model = controller.model else { return }
        exporting = true; controller.stopMovement()
        Task {
            do {
                let assets = folder
                let url = try await Task.detached(priority: .userInitiated) { try TexturedOBJ.export(model: model, assets: assets) }.value
                share = SharePayload(urls: [url])
            } catch { self.error = error.localizedDescription }
            exporting = false
        }
    }
}

struct PhotoThumbnail: View {
    var url: URL
    var rotate = false
    var maxPixels = 240
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.gray.opacity(0.2)).overlay(ProgressView()) }
        }.task(id: url) {
            let target = url
            let pixels = maxPixels
            let source = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let input = CGImageSourceCreateWithURL(target as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            if rotate, let cg = source?.cgImage { image = UIImage(cgImage: cg, scale: 1, orientation: .right) }
            else { image = source }
        }
    }
}

struct PhotoGallery: View {
    var frames: [PhotoKeyframe]
    var folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var share: SharePayload?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, frame in
                    GeometryReader { geometry in
                        if abs(i-index) <= 1 {
                        PhotoThumbnail(url: folder.appendingPathComponent(frame.filename), rotate: true, maxPixels: 1920)
                            .aspectRatio(CGFloat(frame.height)/CGFloat(frame.width), contentMode: .fit)
                            .frame(width: geometry.size.width,height: geometry.size.height)
                            .clipped()
                        } else { Color.black }
                    }.tag(i)
                }
            }.tabViewStyle(.page).background(.black).navigationTitle("Aufnahme \(index+1) / \(frames.count)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button { sharePhoto() } label: { Image(systemName: "square.and.arrow.up") } }
                }
        }.sheet(item: $share) { ShareSheet(urls: $0.urls) }
            .alert("Foto nicht verfügbar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func sharePhoto() {
        guard frames.indices.contains(index) else { return }
        do {
            let frame = frames[index]
            guard let source = UIImage(contentsOfFile: folder.appendingPathComponent(frame.filename).path), let cg = source.cgImage else { throw SpatialError.message("Die Bilddatei konnte nicht gelesen werden.") }
            let oriented = UIImage(cgImage: cg, scale: 1, orientation: .right)
            let size = CGSize(width: CGFloat(cg.height), height: CGFloat(cg.width))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.95) { _ in oriented.draw(in: CGRect(origin: .zero, size: size)) }
            let url = try Exporter.temporaryURL("RJ-Spatial-Foto-\(frame.id+1).jpg")
            try data.write(to: url, options: .atomic)
            share = SharePayload(urls: [url])
        } catch { self.error = error.localizedDescription }
    }
}
