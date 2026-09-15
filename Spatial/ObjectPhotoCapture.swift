import SwiftUI
import RealityKit
import Combine

struct ObjectDraft: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var shots: Int
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ObjectDrafts", isDirectory: true)
    }
    var folder: URL { Self.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func available() -> [ObjectDraft] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("draft.json")), let draft = try? JSONDecoder().decode(Self.self, from: data), draft.shots >= 20, draft.id.uuidString == url.lastPathComponent else { return nil }
            return draft
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

@MainActor final class ObjectPhotoController: ObservableObject {
    @Published var capture: ObjectCaptureSession?
    @Published var draft: ObjectDraft?
    @Published var processing = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var failure: String?
    @Published var modelReady = false
    @Published var readyToBuild = false
    @Published var passes = 1
    @Published var detailedFeatures = true
    @Published var masking = true
    @Published var capturePaused = false
    private var stateTask: Task<Void, Never>?
    private var shotTask: Task<Void, Never>?
    private var reconstructionTask: Task<Void, Never>?
    private var reconstruction: PhotogrammetrySession?
    private var reconstructionID = UUID()
    func start() {
        guard ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported else { failure = "Object Capture wird auf diesem Gerät nicht unterstützt."; return }
        do {
            let draft = ObjectDraft(id: UUID(), createdAt: Date(), shots: 0)
            try FileManager.default.createDirectory(at: draft.folder.appendingPathComponent("SourceImages"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: draft.folder.appendingPathComponent("Checkpoints"), withIntermediateDirectories: true)
            self.draft = draft
            try persistDraft()
            let session = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = draft.folder.appendingPathComponent("Checkpoints")
            configuration.isOverCaptureEnabled = false
            if #available(iOS 18.0, *) {
                session.shouldPlayHaptics = (UserDefaults.standard.object(forKey: "haptics") as? Bool) ?? true
            }
            session.start(imagesDirectory: draft.folder.appendingPathComponent("SourceImages"), configuration: configuration)
            capture = session
            UIApplication.shared.isIdleTimerDisabled = true
            stateTask = Task { [weak self] in
                for await state in session.stateUpdates {
                    guard !Task.isCancelled, let self else { return }
                    switch state {
                    case .completed:
                        self.draft?.shots = session.numberOfShotsTaken
                        do { try self.persistDraft() } catch { self.failure = error.localizedDescription }
                        self.capture = nil; self.shotTask?.cancel(); self.readyToBuild = true
                        UIApplication.shared.isIdleTimerDisabled = false
                        self.build(); return
                    case .failed(let error):
                        self.failure = error.localizedDescription; self.capture = nil; self.shotTask?.cancel()
                        self.readyToBuild = (self.draft?.shots ?? 0) >= 20
                        UIApplication.shared.isIdleTimerDisabled = false; return
                    default: break
                    }
                }
            }
            shotTask = Task { [weak self] in
                for await shots in session.numberOfShotsTakenUpdates {
                    guard !Task.isCancelled, let self else { return }
                    self.draft?.shots = shots
                    do { try self.persistDraft() } catch { self.failure = error.localizedDescription }
                }
            }
        } catch { failure = error.localizedDescription }
    }
    private func persistDraft() throws {
        if let draft { try JSONEncoder().encode(draft).write(to: draft.folder.appendingPathComponent("draft.json"), options: .atomic) }
    }
    func recover(_ draft: ObjectDraft) { self.draft = draft; readyToBuild = true; status = "\(draft.shots) Aufnahmen wiederhergestellt. Das 3D-Modell kann erneut berechnet werden." }
    func detect() {
        guard let capture else { return }
        if !capture.startDetecting() { failure = "Das Objekt konnte noch nicht gewählt werden. Richte die Kamera auf das gesamte Objekt." }
    }
    func nextPass(flip: Bool) {
        if flip { capture?.beginNewScanPassAfterFlip() } else { capture?.beginNewScanPass() }
        passes += 1
    }
    func finishCapture() {
        guard let capture else { return }
        draft?.shots = capture.numberOfShotsTaken
        do { try persistDraft(); capture.finish() } catch { failure = error.localizedDescription }
    }
    func pauseForBackground() {
        if let capture { capture.pause(); capturePaused = true }
        if processing { stopBuild(); status = "Berechnung im Hintergrund beendet. Die Fotos sind gespeichert; starte die Berechnung erneut." }
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func resumeCapture() { capture?.resume(); capturePaused = false; UIApplication.shared.isIdleTimerDisabled = true }
    func build() {
        guard let draft, !processing else { return }
        let generation = UUID()
        reconstructionID = generation
        processing = true; modelReady = false; failure = nil; progress = 0; status = "Fotos werden vorbereitet …"
        UIApplication.shared.isIdleTimerDisabled = true
        reconstructionTask = Task { [weak self] in
            guard let self else { return }
            do {
                await Task.yield()
                var configuration = PhotogrammetrySession.Configuration()
                configuration.featureSensitivity = detailedFeatures ? .high : .normal
                configuration.isObjectMaskingEnabled = masking
                configuration.sampleOrdering = .unordered
                configuration.checkpointDirectory = draft.folder.appendingPathComponent("Checkpoints")
                let output = draft.folder.appendingPathComponent("object.usdz")
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                let session = try PhotogrammetrySession(input: draft.folder.appendingPathComponent("SourceImages"), configuration: configuration)
                reconstruction = session
                try session.process(requests: [.modelFile(url: output, detail: .reduced)])
                for try await event in session.outputs {
                    try Task.checkCancellation()
                    guard reconstructionID == generation else { return }
                    switch event {
                    case .requestProgress(_, let fraction): progress = fraction; status = "Texturiertes 3D-Modell berechnen …"
                    case .requestComplete(_, let result):
                        if case .modelFile(let url) = result {
                            guard FileManager.default.fileExists(atPath: url.path) else { throw SpatialError.message("Das fertige Modell wurde nicht gefunden.") }
                            modelReady = true
                        }
                    case .processingComplete:
                        guard modelReady else { throw SpatialError.message("Es wurde kein Modell erzeugt. Mehr Blickwinkel und gleichmäßiges Licht helfen.") }
                        processing = false; readyToBuild = false; reconstruction = nil
                        UIApplication.shared.isIdleTimerDisabled = false; haptic(); return
                    case .requestError(_, let error): throw error
                    case .automaticDownsampling: status = "iOS passt die Auflösung an den verfügbaren Speicher an."
                    case .invalidSample, .skippedSample: status = "Einzelne ungeeignete Fotos werden übersprungen."
                    case .processingCancelled: throw CancellationError()
                    default: break
                    }
                }
            } catch is CancellationError {
                guard reconstructionID == generation else { return }
                processing = false; readyToBuild = true; reconstruction = nil
                UIApplication.shared.isIdleTimerDisabled = false
            } catch {
                guard reconstructionID == generation else { return }
                processing = false; readyToBuild = true; reconstruction = nil
                failure = error.localizedDescription
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
    func stopBuild() {
        reconstructionID = UUID()
        reconstruction?.cancel(); reconstructionTask?.cancel(); reconstruction = nil
        processing = false; readyToBuild = true
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func close(keepPhotos: Bool) {
        capture?.cancel(); capture = nil
        stateTask?.cancel(); shotTask?.cancel(); reconstruction?.cancel(); reconstructionTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        // Retained drafts can be reconstructed after a restart. Never delete while RealityKit is writing.
        if !keepPhotos, let folder = draft?.folder, reconstruction == nil {
            try? FileManager.default.removeItem(at: folder)
        }
    }
    var feedback: String {
        guard let capture else { return status }
        if capturePaused { return "Aufnahme pausiert. Erst fortsetzen, wenn das Objekt unverändert steht." }
        let raw = capture.feedback.map { String(describing: $0) }.joined(separator: " ").lowercased()
        if raw.contains("dark") || raw.contains("light") { return "Für mehr gleichmäßiges Licht sorgen." }
        if raw.contains("fast") || raw.contains("motion") { return "Langsamer bewegen und kurz ruhig halten." }
        if raw.contains("close") { return "Etwas mehr Abstand zum Objekt halten." }
        if raw.contains("far") { return "Näher an das Objekt herangehen." }
        if raw.contains("outofview") { return "Das Objekt vollständig im Bild behalten." }
        if capture.userCompletedScanPass { return "Runde vollständig. Nimm das Objekt jetzt aus einer anderen Höhe auf." }
        return "Langsam um das unbewegte Objekt gehen. Die Fotos werden automatisch aufgenommen."
    }
}

struct ObjectPhotoScanView: View {
    @StateObject private var controller = ObjectPhotoController()
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var drafts: [ObjectDraft] = []
    @State private var closeDialog = false
    @State private var flipDialog = false
    @State private var name = ""
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Group {
                if let capture = controller.capture { captureScreen(capture) }
                else if controller.modelReady { resultScreen }
                else if controller.processing || controller.readyToBuild { buildScreen }
                else { setupScreen }
            }.navigationTitle("Objekt-Fotoscan").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { closeDialog = true }.disabled(saving) } }
                .confirmationDialog("Aufnahme schließen?", isPresented: $closeDialog, titleVisibility: .visible) {
                    Button("Fotos behalten & schließen") { controller.close(keepPhotos: true); dismiss() }
                    if controller.draft == nil { Button("Schließen", role: .cancel) { dismiss() } }
                } message: { Text("Erfasste Objektfotos bleiben für einen neuen Berechnungsversuch auf diesem Gerät.") }
                .alert("Hinweis", isPresented: Binding(get: { controller.failure != nil }, set: { if !$0 { controller.failure = nil } })) { Button("OK") { controller.failure = nil } } message: { Text(controller.failure ?? "") }
                .confirmationDialog("Objekt wirklich umgedreht?", isPresented: $flipDialog, titleVisibility: .visible) {
                    Button("Neue Seite erfassen") { controller.nextPass(flip: true); controller.resumeCapture() }
                    Button("Abbrechen", role: .cancel) { controller.resumeCapture() }
                } message: { Text("Nur für stabile Gegenstände, deren Form sich dabei nicht verändert. Einen Scooter besser stehen lassen und aus niedrigerer Höhe aufnehmen.") }
        }.interactiveDismissDisabled().onAppear { drafts = ObjectDraft.available() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { controller.pauseForBackground() } }
            .onDisappear { controller.close(keepPhotos: true) }
    }
    private var setupScreen: some View {
        Form {
            Section {
                Label("Aus Fotos wird ein 3D-Objekt", systemImage: "camera.aperture").font(.title2.bold())
                Text("Erst das gesamte Objekt markieren, dann langsam umrunden. Zwei bis drei Runden aus verschiedenen Höhen helfen, verdeckte Flächen zu erfassen.")
            }
            Section("Qualität") {
                Toggle("Details intensiver erkennen", isOn: $controller.detailedFeatures)
                Toggle("Hintergrund automatisch ausblenden", isOn: $controller.masking)
                Text("Die Berechnung erfolgt lokal mit Apples mobiler Detailstufe. Originalbilder bleiben für spätere Verarbeitung und Export erhalten.").font(.caption)
            }
            Section("Auch für größere Gegenstände") {
                Text("Für deinen E-Scooter: rundherum Platz lassen, Lenker und Räder unbewegt lassen, auch von unten und oben fotografieren. Dünne Speichen, glänzendes Metall und einfarbige Flächen sind anspruchsvoll und können im Modell fehlen.")
            }
            Button("Neue Objektaufnahme starten") { controller.start() }.font(.headline)
            if !drafts.isEmpty {
                Section("Gespeicherte Aufnahmen") {
                    ForEach(drafts) { draft in
                        Button { controller.recover(draft) } label: {
                            VStack(alignment: .leading) { Text("\(draft.shots) Fotos"); Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                        }.swipeActions { Button("Löschen", role: .destructive) { do { try FileManager.default.removeItem(at: draft.folder); drafts.removeAll { $0.id == draft.id } } catch { controller.failure = error.localizedDescription } } }
                    }
                }
            }
        }
    }
    private func captureScreen(_ capture: ObjectCaptureSession) -> some View {
        ZStack(alignment: .bottom) {
            ObjectCaptureView(session: capture)
            VStack(spacing: 14) {
                Text(controller.feedback).font(.subheadline).multilineTextAlignment(.center)
                HStack { Text("\(capture.numberOfShotsTaken) / \(capture.maximumNumberOfInputImages) Fotos"); Spacer(); Text("Runde \(controller.passes)") }.font(.caption).monospacedDigit()
                if controller.capturePaused { Button("Aufnahme fortsetzen") { controller.resumeCapture() }.buttonStyle(.borderedProminent) }
                else {
                    switch capture.state {
                    case .ready: Button("Objekt auswählen") { controller.detect() }.buttonStyle(.borderedProminent)
                    case .detecting:
                        Text("Rahmen um das gesamte Objekt anpassen.").font(.caption)
                        Button("Aufnahme starten") { capture.startCapturing() }.buttonStyle(.borderedProminent)
                    case .capturing:
                        HStack {
                            Button { capture.requestImageCapture() } label: { Image(systemName: "camera.shutter.button.fill").font(.title) }.disabled(!capture.canRequestImageCapture).accessibilityLabel("Zusätzliches Foto aufnehmen")
                            Menu("Weitere Runde") {
                                Button("Aus anderer Höhe") { controller.nextPass(flip: false) }
                                Button("Objekt umdrehen / Unterseite") { capture.pause(); controller.capturePaused = true; flipDialog = true }
                            }
                            Spacer()
                            Button("Berechnen") { controller.finishCapture() }.buttonStyle(.borderedProminent).disabled(capture.numberOfShotsTaken < 20)
                        }
                    case .finishing, .initializing: ProgressView("Aufnahme vorbereiten …")
                    default: EmptyView()
                    }
                }
            }.padding(18).spatialGlass().padding(16)
        }
    }
    private var buildScreen: some View {
        Form {
            Section {
                Label("3D-Modell erstellen", systemImage: "cube.transparent.fill").font(.title2.bold())
                Text(controller.status)
                if controller.processing {
                    ProgressView(value: controller.progress)
                    Text(controller.progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    Text("App geöffnet lassen. Aufwendige Aufnahmen können mehrere Minuten benötigen.").font(.caption)
                    Button("Berechnung stoppen, Fotos behalten") { controller.stopBuild() }
                } else {
                    Toggle("Details intensiver erkennen", isOn: $controller.detailedFeatures)
                    Toggle("Hintergrund ausblenden", isOn: $controller.masking)
                    Button("Modell berechnen") { controller.build() }.font(.headline)
                }
            }
        }
    }
    private var resultScreen: some View {
        Form {
            Section {
                Label("Dein Objekt ist fertig", systemImage: "checkmark.seal.fill").font(.title2).foregroundStyle(SpatialStyle.mint)
                TextField("Objektname, z. B. mein E-Scooter", text: $name)
                Text("Das texturierte Modell kannst du drehen, in AR ansehen und als USDZ teilen. Die Aufnahmefotos werden mit dem Projekt aufbewahrt.")
                Button(saving ? "Speichern …" : "Objekt speichern") { save() }.disabled(saving).font(.headline)
            }
        }
    }
    private func save() {
        guard let draft = controller.draft else { return }; saving = true
        var p = ScanProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Foto-Objekt \(store.projects.count+1)" : name, kind: .object)
        p.photoAsset = PhotoAssetInfo(imageCount: draft.shots, texturedFraction: nil, quality: "Object Capture · mobil", modelFile: "object.usdz", retainedSources: true)
        do { try store.addPhotoProject(p, assets: draft.folder); haptic(); dismiss() }
        catch { controller.failure = error.localizedDescription; saving = false }
    }
}
