import SwiftUI
import RoomPlan
import ARKit
import RealityKit
import UniformTypeIdentifiers

@main struct SpatialApp: App {
    @StateObject private var store = ProjectStore()
    @AppStorage("appearance") private var appearance = "system"
    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(SpatialStyle.mint)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .alert("Hinweis", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("OK") { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Studio", systemImage: "square.stack.3d.up") }
            ProjectsView().tabItem { Label("Projekte", systemImage: "square.grid.2x2") }
            SettingsView().tabItem { Label("Einstellungen", systemImage: "slider.horizontal.3") }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: ProjectStore
    @AppStorage("units") private var unitValue = "metric"
    @State private var scan: ScanKind?
    @State private var unavailable = false
    private var units: DisplayUnits { DisplayUnits(rawValue: unitValue) ?? .metric }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label("RJ SPATIAL", systemImage: "viewfinder").font(.caption.weight(.bold)).tracking(3)
                        Spacer()
                        Text(RoomCaptureSession.isSupported ? "LiDAR bereit" : "AR bereit").font(.caption2.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7).spatialGlass()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dein Raum.\nIn jeder Dimension.").font(.system(size: 39, weight: .bold, design: .rounded)).tracking(-1.5)
                        Text("Erfassen. Verstehen. Weiterdenken.").foregroundStyle(.secondary)
                    }
                    HeroRoomView().frame(height: 210).accessibilityLabel("Stilisierte Raumskizze zur Illustration")
                    HStack(spacing: 12) {
                        MetricTile(title: "Gespeicherte Projekte", value: "\(store.projects.count)", icon: "square.stack.3d.up")
                        MetricTile(title: "Erfasste Raumfläche", value: units.area(store.projects.compactMap(\.floorArea).reduce(0, +)), icon: "square.dashed")
                    }
                    Text("Was möchtest du erfassen?").font(.title3.bold())
                    ForEach(ScanKind.allCases) { kind in
                        ActionCard(kind: kind, available: supported(kind)) {
                            if supported(kind) { scan = kind } else { unavailable = true }
                        }
                    }
                    Label("Alles lokal. Kein Konto. Kein Abo.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(22)
            }.background(SpatialBackground()).toolbar(.hidden, for: .navigationBar)
                .fullScreenCover(item: $scan) { kind in CaptureRouter(kind: kind) }
                .alert("Gerät nicht unterstützt", isPresented: $unavailable) {
                    Button("OK", role: .cancel) {}
                } message: { Text("Raumscan und Foto-Raum benötigen unterstützte LiDAR-Hardware. Der Objekt-Fotoscan benötigt zusätzlich Apples Object Capture und lokale Fotogrammetrie. Verfügbare Funktionen stehen unter Einstellungen.") }
        }
    }
    private func supported(_ kind: ScanKind) -> Bool {
        switch kind {
        case .room, .volume: return RoomCaptureSession.isSupported
        case .photoRoom: return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        case .object: return ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported
        case .measure: return ARWorldTrackingConfiguration.isSupported
        case .mesh: return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }
}

struct HeroRoomView: View {
    var body: some View {
        Canvas { context, size in
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: size.width * x, y: size.height * y) }
            let a = point(0.12, 0.53), b = point(0.53, 0.82), c = point(0.91, 0.47), d = point(0.49, 0.20)
            var floor = Path(); floor.move(to: a); floor.addLine(to: b); floor.addLine(to: c); floor.addLine(to: d); floor.closeSubpath()
            context.fill(floor, with: .color(SpatialStyle.mint.opacity(0.12)))
            context.stroke(floor, with: .color(SpatialStyle.mint.opacity(0.8)), lineWidth: 2)
            for p in [a, c, d] {
                let top = CGPoint(x: p.x, y: p.y - 48)
                var edge = Path(); edge.move(to: p); edge.addLine(to: top)
                context.stroke(edge, with: .color(SpatialStyle.blue), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                context.fill(Path(ellipseIn: CGRect(x: top.x - 4, y: top.y - 4, width: 8, height: 8)), with: .color(SpatialStyle.mint))
            }
            var back = Path(); back.move(to: CGPoint(x: a.x, y: a.y-48)); back.addLine(to: CGPoint(x: d.x, y: d.y-48)); back.addLine(to: CGPoint(x: c.x, y: c.y-48))
            context.stroke(back, with: .color(SpatialStyle.blue.opacity(0.6)), lineWidth: 2)
            context.draw(Text("SPACE, CAPTURED.").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.secondary), at: point(0.5, 0.97))
        }
    }
}

struct ProjectsView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var importing = false
    @State private var deleteTarget: ScanProject?
    @State private var oldestFirst = false
    var filtered: [ScanProject] {
        let values = store.projects.filter { (!favoritesOnly || $0.favorite) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.notes.localizedCaseInsensitiveContains(search)) }
        return oldestFirst ? values.reversed() : values
    }
    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Dein Raumarchiv" : "Keine Treffer", systemImage: "square.stack.3d.up", description: Text("Starte im Studio einen Scan oder importiere ein RJ-Spatial-Projekt."))
                } else {
                    List {
                        ForEach(filtered) { project in
                            NavigationLink { ProjectDetailView(projectID: project.id) } label: {
                                HStack(spacing: 15) {
                                    Image(systemName: project.kind.icon).font(.title2).foregroundStyle(SpatialStyle.mint).frame(width: 42)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { Text(project.name).font(.headline); if project.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) } }
                                        Text("\(project.kind.title) · \(project.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 10)
                            }.swipeActions {
                                Button("Löschen", role: .destructive) { deleteTarget = project }
                                Button("Favorit") { var changed = project; changed.favorite.toggle(); do { try store.update(changed) } catch { store.errorMessage = error.localizedDescription } }.tint(.orange)
                            }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }.background(SpatialBackground()).navigationTitle("Projekte")
                .searchable(text: $search, prompt: "Name oder Notiz")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Toggle("Nur Favoriten", isOn: $favoritesOnly)
                            Toggle("Älteste zuerst", isOn: $oldestFirst)
                            Button("Projekt importieren", systemImage: "square.and.arrow.down") { importing = true }
                        } label: { Image(systemName: "line.3.horizontal.decrease") }
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do { try store.importArchive(result.get()) } catch { store.errorMessage = error.localizedDescription }
                }
                .confirmationDialog("Projekt dauerhaft löschen?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                    Button("Löschen", role: .destructive) { if let project = deleteTarget { do { try store.delete(project) } catch { store.errorMessage = error.localizedDescription } }; deleteTarget = nil }
                }
        }
    }
}

struct SettingsView: View {
    @AppStorage("units") private var units = "metric"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("haptics") private var haptics = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Darstellung") {
                    Picker("Einheiten", selection: $units) { ForEach(DisplayUnits.allCases) { Text($0.title).tag($0.rawValue) } }
                    Picker("Design", selection: $appearance) { Text("System").tag("system"); Text("Hell").tag("light"); Text("Dunkel").tag("dark") }
                    Toggle("Haptisches Feedback", isOn: $haptics)
                }
                Section("Dein Gerät") {
                    LabeledContent("Raumerkennung", value: RoomCaptureSession.isSupported ? "RoomPlan + LiDAR" : "Nicht verfügbar")
                    LabeledContent("3D-Netz", value: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ? "Verfügbar" : "Nicht verfügbar")
                    LabeledContent("AR-Messungen", value: ARWorldTrackingConfiguration.isSupported ? "Verfügbar" : "Nicht verfügbar")
                    LabeledContent("Objekt-Fotogrammetrie", value: ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported ? "Verfügbar" : "Nicht verfügbar")
                }
                Section("Für gute Scans") {
                    Text("Bewege dich langsam bei gutem Licht. Erfasse jede Wand, Bodenkante, Tür und jedes Fenster aus mehreren Winkeln. Spiegel, Glas und verdeckte Flächen können fehlen oder ungenau sein.")
                    Text("Volumen = erkannte Grundfläche × Raumhöhe. Bei Dachschrägen, offenen Räumen oder unvollständiger Kontur ist das kein exaktes Raumvolumen. Die Raumhöhe kannst du im Projekt korrigieren.")
                    Text("Im klassischen Raumscan sind Möbel vereinfachte Körper. Foto-Raum ergänzt das LiDAR-Netz um echte Kamerabilder und einen freien Rundgang. Nicht beobachtete Flächen bleiben neutral; Nahtstellen zwischen Fotos sind möglich.")
                    Text("Objekt-Fotoscan berechnet ein texturiertes Modell aus mehreren Foto-Runden. iOS unterstützt die mobile Detailstufe. Rohfotos bleiben im Projekt und können für eine spätere Berechnung auf einem Mac exportiert werden. Bei wenig Platz lassen sich nicht mehr benötigte Aufnahmeentwürfe im Objektmodus löschen.")
                }
                Section("Privat & unabhängig") {
                    Text("Keine Werbung, kein Abo, kein Konto. Die App sendet keine Scans an einen Server. Projekte liegen im Dokumente-Ordner der App und können Teil deines Geräte-Backups sein. Beim Löschen der App werden lokale Projekte entfernt; exportiere wichtige Projekte vorher als JSON-Archiv.")
                    LabeledContent("Version", value: "2.0.0 · RJ Spatial")
                }
            }.navigationTitle("Einstellungen")
        }
    }
}
