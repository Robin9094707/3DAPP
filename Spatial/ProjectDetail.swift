import SwiftUI
import QuickLook

struct ProjectDetailView: View {
    var projectID: UUID
    @EnvironmentObject private var store: ProjectStore
    @AppStorage("units") private var unitValue = "metric"
    @State private var page = 0
    @State private var hiddenKinds: Set<ElementKind> = []
    @State private var showDimensions = true
    @State private var wireframe = false
    @State private var exploded = 0.0
    @State private var topView = false
    @State private var selected: UUID?
    @State private var resetToken = 0
    @State private var share: SharePayload?
    @State private var editing = false
    @State private var quickLook = false
    @State private var photoViewer = false
    @State private var exportingSources = false
    @State private var planScale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var planOffset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    private var units: DisplayUnits { DisplayUnits(rawValue: unitValue) ?? .metric }
    private var project: ScanProject? { store.projects.first { $0.id == projectID } }
    var body: some View {
        Group {
            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label(project.kind.title, systemImage: project.kind.icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(project.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        if project.photoAsset != nil {
                            photoSummary(project)
                        } else {
                            Picker("Ansicht", selection: $page) { Text("3D").tag(0); if !project.hasMesh { Text("Grundriss").tag(1) }; Text("Details").tag(2) }.pickerStyle(.segmented)
                            if page == 0 { scene(project) }
                            if page == 1 { plan(project) }
                            if page != 2 { controls(project) }
                        }
                        if let element = project.elements.first(where: { $0.id == selected }) { inspector(element) }
                        metrics(project)
                        if page == 2 { elementList(project) }
                        if !project.measurements.isEmpty { measurements(project) }
                        if !project.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) { Text("Notizen").font(.headline); Text(project.notes).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading).padding(20).spatialGlass()
                        }
                        if !project.elements.isEmpty {
                            Text("≈ Näherungswerte · \(project.floorArea == nil ? "Bodenkontur noch nicht geschlossen" : project.boundarySource). Volumen setzt eine gleichmäßige Raumhöhe voraus.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20)
                }.background(SpatialBackground()).navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { editing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Projekt bearbeiten")
                        }
                        ToolbarItem(placement: .topBarTrailing) { exportMenu(project) }
                    }
                    .sheet(isPresented: $editing) { ProjectEditor(draft: project) }
                    .sheet(isPresented: $quickLook) { ModelQuickLook(url: store.file(project.id, "room.usdz")) }
                    .fullScreenCover(isPresented: $photoViewer) { PhotoProjectViewer(project: project, folder: store.directory(project.id)) }
            } else { ContentUnavailableView("Projekt nicht vorhanden", systemImage: "folder.badge.questionmark") }
        }.sheet(item: $share) { ShareSheet(urls: $0.urls) }
    }
    @ViewBuilder private func photoSummary(_ p: ScanProject) -> some View {
        if let asset = p.photoAsset {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: p.kind.icon).font(.system(size: 54)).foregroundStyle(SpatialStyle.mint)
                Text(p.kind == .photoRoom ? "Dein Raum. Zum Durchgehen." : "Dein Objekt. In echten Farben.").font(.system(.title, design: .rounded, weight: .bold))
                Text(p.kind == .photoRoom ? "Öffne das texturierte Modell, bewege dich frei hindurch und sieh dir die aufgenommenen Fotos an." : "Drehe dein Foto-Modell, teile Ansichten als Bild oder öffne den USDZ-Export in AR.").font(.subheadline).foregroundStyle(.secondary)
                Button { photoViewer = true } label: { Label("3D-Ansicht öffnen", systemImage: "cube").font(.headline).frame(maxWidth: .infinity).padding(12) }.buttonStyle(.borderedProminent)
                LabeledContent("Aufnahmefotos", value: asset.imageCount.formatted())
                LabeledContent("Qualität", value: asset.quality)
                if let fraction = asset.texturedFraction {
                    LabeledContent("Dreiecke mit Bildtextur", value: fraction.formatted(.percent.precision(.fractionLength(0))))
                    Text("Dieser Anteil beschreibt die Texturzuordnung, nicht die Genauigkeit oder Vollständigkeit des Scans.").font(.caption).foregroundStyle(.secondary)
                }
                if exportingSources { ProgressView("Originalaufnahmen verpacken …") }
            }.padding(22).spatialGlass()
        }
    }
    private func scene(_ p: ScanProject) -> some View {
        RoomSceneView(project: p, meshURL: p.hasMesh ? store.file(p.id, "mesh.obj") : nil, hiddenKinds: hiddenKinds, dimensions: showDimensions, wireframe: wireframe, exploded: exploded, topView: topView, units: units, selected: $selected, resetToken: resetToken)
            .frame(height: 390).background(SpatialStyle.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 24)).clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .bottom) {
                Text("Drehen · Zoomen · Element antippen").font(.caption2).padding(10).spatialGlass().padding(12).allowsHitTesting(false)
            }
            .accessibilityLabel("Drehbares 3D-Modell. Alle Elemente und Maße sind auch unter Details verfügbar.")
    }
    private func plan(_ p: ScanProject) -> some View {
        FloorPlanView(project: p, units: units, labels: showDimensions, furniture: !hiddenKinds.contains(.furniture), selected: $selected)
            .frame(height: 390)
            .scaleEffect(planScale * pinch).offset(x: planOffset.width + drag.width, y: planOffset.height + drag.height)
            .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }.onEnded { planScale = max(1, min(5, planScale * $0)) })
            .simultaneousGesture(DragGesture(minimumDistance: 10).updating($drag) { value, state, _ in if planScale > 1 { state = value.translation } }.onEnded { if planScale > 1 { planOffset.width += $0.translation.width; planOffset.height += $0.translation.height } })
            .frame(height: 390).background(SpatialStyle.mint.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityLabel("Bemaßter Grundriss. Alle Maße sind auch unter Details verfügbar.")
    }
    private func controls(_ p: ScanProject) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 15) {
                Menu {
                    Toggle("Maße einblenden", isOn: $showDimensions)
                    if page == 0 {
                        Toggle("Drahtgitter", isOn: $wireframe)
                        Toggle("Von oben", isOn: $topView)
                    }
                    ForEach(ElementKind.allCases.filter { page == 0 || $0 == .furniture }) { kind in
                        Toggle(kind.title, isOn: Binding(get: { !hiddenKinds.contains(kind) }, set: { show in if show { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) } }))
                    }
                } label: { Label("Ebenen", systemImage: "square.3.layers.3d") }
                Spacer()
                if p.hasUSDZ { Button { quickLook = true } label: { Label("AR", systemImage: "arkit") } }
                Button { resetToken += 1; planScale = 1; planOffset = .zero; exploded = 0; selected = nil } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("Ansicht zurücksetzen")
            }
            if page == 0 && !p.elements.isEmpty {
                HStack { Image(systemName: "square.stack.3d.up"); Slider(value: $exploded, in: 0...1).accessibilityLabel("Elemente auseinanderziehen") }
                Text("Elemente auseinanderziehen").font(.caption2).foregroundStyle(.secondary)
            }
        }.font(.subheadline).padding(18).spatialGlass()
    }
    @ViewBuilder private func metrics(_ p: ScanProject) -> some View {
        if !p.elements.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricTile(title: "Grundfläche ≈", value: p.floorArea.map { units.area($0) } ?? "Nicht erfasst", icon: "square.dashed")
                MetricTile(title: "Rauminhalt ≈", value: p.volume.map { units.volume($0) } ?? "Nicht erfasst", icon: "cube.transparent")
                MetricTile(title: "Raumhöhe ≈", value: p.roomHeight.map { units.length($0) } ?? "Nicht erfasst", icon: "arrow.up.and.down")
                MetricTile(title: "Summe Wandlängen ≈", value: units.length(p.perimeter), icon: "ruler")
            }
            if page == 2 {
                VStack(spacing: 12) {
                    LabeledContent("Wandfläche brutto ≈", value: units.area(p.wallArea))
                    LabeledContent("Öffnungsflächen ≈", value: units.area(p.openingArea))
                    LabeledContent("Wandfläche netto ≈", value: units.area(p.netWallArea))
                }.font(.subheadline).padding(20).spatialGlass()
            }
        }
        if p.hasMesh || p.kind == .photoRoom {
            HStack { MetricTile(title: "3D-Punkte", value: p.meshVertexCount.formatted(), icon: "circle.dotted"); MetricTile(title: "Dreiecke", value: p.meshFaceCount.formatted(), icon: "triangle") }
        }
    }
    private func inspector(_ e: RoomElement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(e.label).font(.headline); Spacer(); Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Auswahl aufheben") }
            Text("\(units.length(Double(e.dimensions.x))) × \(units.length(Double(e.dimensions.y))) × \(units.length(Double(e.dimensions.z)))").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            Text("Breite × Höhe × Tiefe · Erkennung: \(e.confidenceTitle)").font(.caption).foregroundStyle(.secondary)
        }.padding(20).spatialGlass()
    }
    private func elementList(_ p: ScanProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Erkannte Elemente").font(.title3.bold())
            ForEach(ElementKind.allCases) { kind in
                let elements = p.elements.filter { $0.kind == kind }
                if !elements.isEmpty {
                    Text("\(kind.title) · \(elements.count)").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(elements) { e in
                        Button { selected = e.id } label: {
                            HStack {
                                Circle().fill(Color(uiColor: RoomSceneView.Coordinator.color(kind))).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(e.label).foregroundStyle(.primary)
                                    Text("\(units.length(Double(e.dimensions.x))) × \(units.length(Double(e.dimensions.y)))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(e.confidenceTitle).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(20).spatialGlass()
    }
    private func measurements(_ p: ScanProject) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Gespeicherte Messungen").font(.title3.bold())
            ForEach(p.measurements) { measurement in
                VStack(alignment: .leading, spacing: 5) {
                    Text(measurement.name).font(.headline)
                    Text("\(measurement.isArea ? "Umfang" : "Länge"): \(units.length(measurement.length))\(measurement.area.map { " · Fläche: " + units.area($0) } ?? "")").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).spatialGlass()
    }
    private func exportMenu(_ p: ScanProject) -> some View {
        Menu {
            Button(p.kind == .object ? "Modellarchiv ohne Rohfotos · JSON" : "Projektarchiv · JSON", systemImage: "archivebox") { export { try store.archive(p) } }
            if p.photoAsset != nil {
                Button("Modell und Aufnahmen · ZIP", systemImage: "photo.stack") { exportSources(p) }
                if p.kind == .object { Button("Texturiertes 3D-Objekt · USDZ", systemImage: "cube") { share = SharePayload(urls: [store.file(p.id,"object.usdz")]) } }
            }
            if p.photoAsset == nil {
            Button("Messbericht · PDF", systemImage: "doc.richtext") { export { try Exporter.pdf(p, units: units) } }
            Button("Maßtabelle · CSV", systemImage: "tablecells") { export { try Exporter.csv(p) } }
            if !p.hasMesh { Button("Grundriss · SVG", systemImage: "square.dashed") { export { try Exporter.svg(p, units: units) } } }
            if p.hasUSDZ { Button("3D-Modell · USDZ", systemImage: "cube") { share = SharePayload(urls: [store.file(p.id, "room.usdz")]) } }
            if p.hasMesh { Button("Dreiecksnetz · OBJ", systemImage: "cube.transparent") { share = SharePayload(urls: [store.file(p.id, "mesh.obj")]) } }
            }
        } label: { Image(systemName: "square.and.arrow.up") }.disabled(exportingSources).accessibilityLabel("Projekt exportieren")
    }
    private func exportSources(_ p: ScanProject) {
        let folder = store.directory(p.id)
        exportingSources = true
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try PhotoZIP.write(folder: folder, filename: "RJ-Spatial-Modell-und-Aufnahmen.zip") }.value
                share = SharePayload(urls: [url])
            } catch { store.errorMessage = error.localizedDescription }
            exportingSources = false
        }
    }
    private func export(_ action: () throws -> URL) {
        do { share = SharePayload(urls: [try action()]) } catch { store.errorMessage = error.localizedDescription }
    }
}

struct ProjectEditor: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: ScanProject
    @State private var height = ""
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Projekt") {
                    TextField("Name", text: $draft.name)
                    Toggle("Favorit", isOn: $draft.favorite)
                }
                if !draft.elements.isEmpty {
                    Section("Raumhöhe korrigieren") {
                        TextField("Höhe in Metern, z. B. 2,50", text: $height).keyboardType(.decimalPad)
                        Text("Leer lassen, um die mittlere erkannte Wandhöhe zu verwenden. Diese Korrektur verändert die Volumenberechnung; das gescannte Modell bleibt unverändert.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Notizen") { TextEditor(text: $draft.notes).frame(minHeight: 130) }
                if !draft.measurements.isEmpty {
                    Section("Messungen benennen") {
                        ForEach($draft.measurements) { $measurement in TextField("Messungsname", text: $measurement.name) }
                    }
                }
                if !draft.elements.isEmpty {
                    Section("Elemente benennen") { ForEach($draft.elements) { $element in TextField(element.kind.title, text: $element.label) } }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }.navigationTitle("Bearbeiten").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Sichern") { save() } }
                }
                .onAppear { height = draft.heightOverride.map { String($0) } ?? "" }
        }
    }
    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { errorMessage = "Bitte einen Projektnamen eingeben."; return }
        let value = height.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if value.isEmpty { draft.heightOverride = nil }
        else {
            guard let number = Double(value), number.isFinite, number > 0, number < 100 else { errorMessage = "Bitte eine Höhe zwischen 0 und 100 Metern eingeben."; return }
            draft.heightOverride = number
        }
        do { try store.update(draft); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

struct ModelQuickLook: UIViewControllerRepresentable {
    var url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
