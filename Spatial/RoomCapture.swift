import SwiftUI
import RoomPlan
import ARKit
import AVFoundation
import Combine

struct CaptureRouter: View {
    var kind: ScanKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorized = false
    @State private var checked = false
    var body: some View {
        Group {
            if authorized {
                switch kind {
                case .room, .volume: RoomScannerView(kind: kind)
                case .photoRoom: PhotoRoomSetup()
                case .object: ObjectPhotoScanView()
                case .measure: ARMeasureView()
                case .mesh: MeshScannerView()
                }
            } else if checked {
                ContentUnavailableView {
                    Label("Kamera erlauben", systemImage: "camera.fill")
                } description: {
                    Text("RJ Spatial braucht die Kamera, um Räume und Messpunkte zu erfassen. Du kannst den Zugriff in den iOS-Einstellungen erlauben.")
                } actions: {
                    Button("Einstellungen öffnen") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Button("Schließen") { dismiss() }
                }
            } else { ProgressView("Kamera vorbereiten …") }
        }.task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            checked = true
        }.onChange(of: scenePhase) { _, phase in
            if phase == .active && checked { authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
        }
    }
}

final class RoomCaptureController: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    @Published var wallCount = 0
    @Published var objectCount = 0
    @Published var openingCount = 0
    @Published var processing = false
    @Published var result: CapturedRoom?
    @Published var failure: String?
    @Published var instruction = "Bewege das iPhone langsam entlang aller Wände."
    weak var captureView: RoomCaptureView?
    private var active = false
    private var completed = false
    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func start(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
        view.captureSession.delegate = self
        active = true
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func finish() {
        guard active, !processing else { return }
        processing = true
        instruction = "Dein Raum wird berechnet …"
        captureView?.captureSession.stop()
        active = false
    }
    func cancel() {
        completed = true
        captureView?.captureSession.stop()
        active = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            DispatchQueue.main.async { self.failure = error.localizedDescription; self.processing = false }
            return false
        }
        return !completed
    }
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            guard !self.completed else { return }
            self.completed = true; self.processing = false
            UIApplication.shared.isIdleTimerDisabled = false
            if let error { self.failure = error.localizedDescription }
            else if processedResult.walls.isEmpty { self.failure = "Es wurden noch keine Wände erkannt. Starte erneut und scanne den Raum langsamer." }
            else { self.result = processedResult; haptic() }
        }
    }
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async {
            self.wallCount = room.walls.count
            self.objectCount = room.objects.count
            self.openingCount = room.windows.count + room.doors.count + room.openings.count
        }
    }
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        DispatchQueue.main.async {
            let raw = String(describing: instruction)
            switch raw {
            case "moveCloseToWall": self.instruction = "Gehe etwas näher an die Wand."
            case "moveAwayFromWall": self.instruction = "Gehe etwas von der Wand zurück."
            case "slowDown": self.instruction = "Bewege das iPhone langsamer."
            case "turnOnLight": self.instruction = "Mehr Licht verbessert die Erkennung."
            case "lowTexture": self.instruction = "Erfasse auch Kanten und strukturierte Flächen."
            default: self.instruction = "Erfasse Wände, Boden, Türen und Fenster vollständig."
            }
        }
    }
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error { DispatchQueue.main.async { if !self.completed { self.failure = error.localizedDescription; self.processing = false } } }
    }
}

struct NativeRoomCapture: UIViewRepresentable {
    @ObservedObject var controller: RoomCaptureController
    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        controller.start(view)
        return view
    }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) {
        uiView.captureSession.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

struct RoomScannerView: View {
    let kind: ScanKind
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = RoomCaptureController()
    @State private var projectName = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var cancelConfirmation = false
    @State private var startedAt = Date()
    var body: some View {
        ZStack {
            NativeRoomCapture(controller: controller).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Button { cancelConfirmation = true } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).spatialGlass() }.accessibilityLabel("Scan schließen")
                    Spacer()
                    Text(kind.title).font(.headline).padding(13).spatialGlass()
                    Spacer()
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(time(context.date)).monospacedDigit().font(.caption.bold()).padding(12).spatialGlass()
                    }
                }
                HStack {
                    Label("\(controller.wallCount)", systemImage: "rectangle.split.3x1")
                    Label("\(controller.openingCount)", systemImage: "door.left.hand.open")
                    Label("\(controller.objectCount)", systemImage: "sofa")
                }.font(.subheadline.weight(.medium)).padding(13).spatialGlass()
                Spacer()
                VStack(spacing: 15) {
                    Text(controller.instruction).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                    if controller.processing { ProgressView("3D-Plan aufbauen …") }
                    else {
                        Button { controller.finish() } label: {
                            Label("Scan abschließen", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity).padding(17)
                        }.buttonStyle(.borderedProminent).disabled(controller.wallCount == 0)
                    }
                }.padding(20).spatialGlass()
            }.padding(20)
        }.interactiveDismissDisabled()
            .sheet(isPresented: Binding(get: { controller.result != nil }, set: { _ in })) {
                saveSheet.interactiveDismissDisabled()
            }
            .confirmationDialog("Scan verwerfen?", isPresented: $cancelConfirmation, titleVisibility: .visible) {
                Button("Verwerfen", role: .destructive) { controller.cancel(); dismiss() }
            }
            .alert("Scan konnte nicht abgeschlossen werden", isPresented: Binding(get: { controller.failure != nil }, set: { _ in })) {
                Button("Schließen") { controller.cancel(); dismiss() }
            } message: { Text(controller.failure ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && controller.result == nil {
                    controller.cancel()
                    controller.failure = "Der Scan wurde im Hintergrund unterbrochen. Bitte starte ihn erneut."
                }
            }
            .onDisappear { controller.cancel() }
    }
    private func time(_ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private var saveSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Dein Raum ist erfasst", systemImage: "checkmark.seal.fill").font(.title3).foregroundStyle(SpatialStyle.mint)
                    TextField("Raumname", text: $projectName)
                }
                if let room = controller.result {
                    Section("Erkannt") {
                        LabeledContent("Wände", value: "\(room.walls.count)")
                        LabeledContent("Fenster", value: "\(room.windows.count)")
                        LabeledContent("Türen", value: "\(room.doors.count)")
                        LabeledContent("Möbel", value: "\(room.objects.count)")
                    }
                }
                Section {
                    Text("Dein 3D-Modell, der Grundriss und alle erkannten Maße stehen anschließend unter Projekte bereit.")
                }
                if let saveError { Section { Text(saveError).foregroundStyle(.red) } }
            }.navigationTitle("Scan speichern")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Verwerfen", role: .destructive) { controller.result = nil; dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Speichern …" : "Speichern") { save() }.disabled(saving)
                    }
                }
        }.presentationDetents([.medium, .large])
    }
    private func save() {
        guard let room = controller.result else { return }
        saving = true
        Task { @MainActor in
            await Task.yield()
            var project = ScanProject(name: projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Raum \(store.projects.count + 1)" : projectName, kind: kind)
            let groups: [(ElementKind, [CapturedRoom.Surface])] = [(.wall, room.walls), (.window, room.windows), (.door, room.doors), (.opening, room.openings), (.floor, room.floors)]
            for (type, surfaces) in groups {
                project.elements += surfaces.enumerated().map { RoomElement(surface: $0.element, kind: type, number: $0.offset + 1) }
            }
            project.elements += room.objects.enumerated().map { RoomElement(object: $0.element, number: $0.offset + 1) }
            do { _ = try store.add(project, room: room); controller.result = nil; haptic(); dismiss() }
            catch { saveError = error.localizedDescription; saving = false }
        }
    }
}
