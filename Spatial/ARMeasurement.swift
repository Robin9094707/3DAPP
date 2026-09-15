import SwiftUI
import ARKit
import SceneKit
import Combine

enum MeasureMode: String, CaseIterable, Identifiable {
    case distance, polyline, area
    var id: String { rawValue }
    var title: String { switch self { case .distance: return "Strecke"; case .polyline: return "Linienzug"; case .area: return "Bodenfläche" } }
}

enum SceneDrawing {
    static func line(from a: SIMD3<Float>, to b: SIMD3<Float>, color: UIColor, radius: CGFloat = 0.008) -> SCNNode {
        let length = simd_distance(a, b)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) / 2
        if length > 0.0001 { node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(b - a)) }
        return node
    }
    static func dot(at point: SIMD3<Float>) -> SCNNode {
        let sphere = SCNSphere(radius: 0.016)
        sphere.firstMaterial?.diffuse.contents = UIColor.systemMint
        sphere.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: sphere); node.simdPosition = point
        return node
    }
    static func label(_ text: String, at point: SIMD3<Float>) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = .systemFont(ofSize: 8, weight: .semibold)
        geometry.flatness = 0.5
        geometry.firstMaterial?.diffuse.contents = UIColor.white
        geometry.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(0.004, 0.004, 0.004)
        let (min, max) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((min.x + max.x) / 2, min.y, 0)
        node.simdPosition = point + SIMD3(0, 0.03, 0)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }
}

final class MeasureController: NSObject, ObservableObject, ARSessionDelegate {
    @Published var mode: MeasureMode = .distance
    @Published var points: [Point3] = []
    @Published var completed: [SavedMeasurement] = []
    @Published var target: SIMD3<Float>?
    @Published var status = "Bewege das iPhone langsam, um Oberflächen zu erkennen."
    @Published var trackingReady = false
    @Published var failure: String?
    var units: DisplayUnits = .metric
    weak var view: ARSCNView?
    private let drawing = SCNNode()
    private var previewNode: SCNNode?
    private var lastFrame: TimeInterval = 0
    func start(_ view: ARSCNView) {
        self.view = view
        view.scene = SCNScene()
        view.scene.rootNode.addChildNode(drawing)
        view.session.delegate = self; view.session.delegateQueue = .main
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { configuration.frameSemantics.insert(.sceneDepth) }
        view.session.run(configuration)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func stop() { view?.session.pause(); UIApplication.shared.isIdleTimerDisabled = false }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastFrame > 0.10 else { return }; lastFrame = frame.timestamp
        switch frame.camera.trackingState {
        case .normal: trackingReady = true
        case .notAvailable: trackingReady = false; status = "AR ist momentan nicht verfügbar."
        case .limited(let reason): trackingReady = false; status = reason == .excessiveMotion ? "Bitte langsamer bewegen." : "Orientierung suchen: Kamera langsam bewegen."
        }
        guard trackingReady, let view else { target = nil; return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let alignment: ARRaycastQuery.TargetAlignment = mode == .area ? .horizontal : .any
        var hit: ARRaycastResult?
        for targetType in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            if let query = view.raycastQuery(from: center, allowing: targetType, alignment: alignment), let first = session.raycast(query).first { hit = first; break }
        }
        if let hit {
            let t = hit.worldTransform.columns.3
            target = SIMD3(t.x, t.y, t.z)
            status = mode == .area ? "Nacheinander die Bodenecken markieren." : "Fadenkreuz auf den Messpunkt richten."
        } else { target = nil; status = "Noch keine Oberfläche im Fadenkreuz erkannt." }
        previewNode?.removeFromParentNode()
        if let target, let last = points.last {
            let node = SceneDrawing.line(from: last.simd, to: target, color: .systemYellow, radius: 0.003)
            drawing.addChildNode(node); previewNode = node
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) { failure = error.localizedDescription; trackingReady = false }
    func sessionWasInterrupted(_ session: ARSession) { trackingReady = false; target = nil; status = "AR unterbrochen." }
    func sessionInterruptionEnded(_ session: ARSession) { failure = "Die AR-Sitzung wurde unterbrochen. Bitte starte neu, damit Messpunkte nicht in einem verschobenen Koordinatensystem liegen." }
    func addPoint() {
        guard trackingReady, let target, mode != .distance || points.count < 2 else { return }
        if let last = points.last, simd_distance(last.simd, target) < 0.015 { status = "Der neue Punkt liegt zu nah am letzten Punkt."; haptic(.warning); return }
        if mode == .area, let first = points.first, abs(first.y - target.y) > 0.12 { status = "Bodenflächen brauchen Punkte auf derselben Höhe."; haptic(.warning); return }
        points.append(Point3(target)); redraw(); haptic()
    }
    func undo() { if !points.isEmpty { points.removeLast(); redraw() } }
    func clear() { points.removeAll(); redraw() }
    func changeMode(_ value: MeasureMode) { mode = value; target = nil; clear() }
    var current: SavedMeasurement { SavedMeasurement(name: "\(mode.title) \(completed.count + 1)", points: points, isArea: mode == .area) }
    var canAccept: Bool { points.count >= (mode == .area ? 3 : 2) }
    func accept() -> Bool {
        guard canAccept else { return false }
        if mode == .area && (!Geometry.isSimpleXZ(points.map(\.simd)) || Geometry.areaXZ(points.map(\.simd)) < 0.0001) {
            status = "Die Kontur kreuzt sich oder hat keine Fläche. Setze die Ecken in Reihenfolge."; haptic(.warning); return false
        }
        completed.append(current); clear(); haptic(); return true
    }
    private func redraw() {
        drawing.childNodes.forEach { $0.removeFromParentNode() }
        for point in points { drawing.addChildNode(SceneDrawing.dot(at: point.simd)) }
        for (a, b) in zip(points, points.dropFirst()) {
            drawing.addChildNode(SceneDrawing.line(from: a.simd, to: b.simd, color: .systemMint))
            drawing.addChildNode(SceneDrawing.label(units.length(Double(simd_distance(a.simd, b.simd))), at: (a.simd + b.simd) / 2))
        }
        if mode == .area, points.count >= 3 {
            drawing.addChildNode(SceneDrawing.line(from: points[points.count-1].simd, to: points[0].simd, color: .systemOrange, radius: 0.004))
        }
    }
}

struct MeasureCamera: UIViewRepresentable {
    @ObservedObject var controller: MeasureController
    func makeUIView(context: Context) -> ARSCNView { let view = ARSCNView(); controller.start(view); return view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) { uiView.session.pause(); UIApplication.shared.isIdleTimerDisabled = false }
}

struct ARMeasureView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("units") private var unitValue = "metric"
    @StateObject private var controller = MeasureController()
    @State private var naming = false
    @State private var name = ""
    @State private var saveError: String?
    @State private var discard = false
    @State private var pendingMode: MeasureMode?
    var units: DisplayUnits { DisplayUnits(rawValue: unitValue) ?? .metric }
    var body: some View {
        ZStack {
            MeasureCamera(controller: controller).ignoresSafeArea()
            Image(systemName: "plus").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(controller.target == nil ? .white : SpatialStyle.mint).shadow(radius: 3).accessibilityHidden(true)
            VStack(spacing: 14) {
                HStack {
                    Button { discard = true } label: { Image(systemName: "xmark").frame(width: 44, height: 44).spatialGlass() }.accessibilityLabel("Messung schließen")
                    Spacer()
                    Text("AR-Maßband").font(.headline).padding(13).spatialGlass()
                    Spacer()
                    Button("Sichern") {
                        if controller.points.isEmpty || controller.accept() { naming = true }
                    }.disabled(!controller.canAccept && controller.completed.isEmpty).padding(12).spatialGlass()
                }
                Picker("Messmodus", selection: Binding(get: { controller.mode }, set: { value in
                    if controller.points.isEmpty { controller.changeMode(value) } else { pendingMode = value }
                })) {
                    ForEach(MeasureMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).padding(10).spatialGlass()
                Spacer()
                VStack(spacing: 14) {
                    Text(valueText).font(.system(size: 38, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1).monospacedDigit()
                    Text(controller.status).font(.caption).multilineTextAlignment(.center)
                    HStack(spacing: 24) {
                        Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.title2).frame(width: 48, height: 48) }.disabled(controller.points.isEmpty).accessibilityLabel("Letzten Punkt entfernen")
                        Button { controller.addPoint() } label: {
                            Image(systemName: "plus").font(.title.bold()).foregroundStyle(.black).frame(width: 68, height: 68).background(SpatialStyle.mint, in: Circle())
                        }.disabled(controller.target == nil || !controller.trackingReady || (controller.mode == .distance && controller.points.count == 2)).accessibilityLabel("Messpunkt setzen")
                        Button { _ = controller.accept() } label: { Image(systemName: "checkmark").font(.title2).frame(width: 48, height: 48) }.disabled(!controller.canAccept).accessibilityLabel("Messung übernehmen")
                    }
                    Text("\(controller.points.count) Punkte · \(controller.completed.count) Messungen übernommen").font(.caption2).foregroundStyle(.secondary)
                    if controller.mode == .area { Text("Horizontale Bodenfläche · Näherungswert").font(.caption2).foregroundStyle(.secondary) }
                }.padding(22).spatialGlass()
            }.padding(20)
        }.interactiveDismissDisabled()
            .onAppear { controller.units = units }
            .onDisappear { controller.stop() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { controller.stop(); controller.failure = "Die Messung wurde im Hintergrund unterbrochen. Bitte starte eine neue Sitzung." } }
            .alert("Messprojekt speichern", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Speichern") { save() }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text("\(controller.completed.count) Messungen werden lokal gespeichert.") }
            .alert("Hinweis", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) { Button("OK") { saveError = nil } } message: { Text(saveError ?? "") }
            .alert("AR unterbrochen", isPresented: Binding(get: { controller.failure != nil }, set: { _ in })) { Button("Schließen") { dismiss() } } message: { Text(controller.failure ?? "") }
            .confirmationDialog("Messung verwerfen?", isPresented: $discard, titleVisibility: .visible) { Button("Verwerfen", role: .destructive) { dismiss() } }
            .confirmationDialog("Aktuelle Punkte beim Moduswechsel verwerfen?", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }), titleVisibility: .visible) {
                Button("Modus wechseln", role: .destructive) { if let mode = pendingMode { controller.changeMode(mode) }; pendingMode = nil }
            }
    }
    var valueText: String {
        if let area = controller.current.area { return units.area(area) }
        if controller.points.count >= 2 { return units.length(controller.current.length) }
        if let point = controller.points.last, let target = controller.target { return units.length(Double(simd_distance(point.simd, target))) }
        return "Punkt setzen"
    }
    private func save() {
        var project = ScanProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Messung \(store.projects.count + 1)" : name, kind: .measure)
        project.measurements = controller.completed
        do { _ = try store.add(project); haptic(); dismiss() } catch { saveError = error.localizedDescription }
    }
}
