import Foundation
import Combine
import RoomPlan

struct ProjectArchive: Codable {
    var format = "eu.rjuhas.spatial"
    var version = 1
    var project: ScanProject
    var capturedRoom: Data?
    var meshOBJ: Data?
    var photoFiles: [String: Data]?
}

enum SpatialError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ScanProject] = []
    @Published var errorMessage: String?
    let root: URL
    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try reload() }
        catch { errorMessage = error.localizedDescription }
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func file(_ id: UUID, _ filename: String) -> URL { directory(id).appendingPathComponent(filename) }
    func reload() throws {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var loaded: [ScanProject] = []
        var unreadable = 0
        for folder in directories where UUID(uuidString: folder.lastPathComponent) != nil {
            do {
                let p = try JSONDecoder().decode(ScanProject.self, from: Data(contentsOf: folder.appendingPathComponent("project.json")))
                guard p.id.uuidString == folder.lastPathComponent else { unreadable += 1; continue }
                loaded.append(p)
            } catch { unreadable += 1 }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
        if unreadable > 0 { errorMessage = "\(unreadable) Projekt(e) konnten nicht gelesen werden. Die Dateien wurden beibehalten." }
    }
    func add(_ project: ScanProject, room: CapturedRoom? = nil, mesh: Data? = nil) throws -> ScanProject {
        var saved = project
        let staging = root.appendingPathComponent(".pending-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        if let room {
            try JSONEncoder().encode(room).write(to: staging.appendingPathComponent("room.json"), options: .atomic)
            saved.hasRawRoom = true
            do {
                try room.export(to: staging.appendingPathComponent("room.usdz"), exportOptions: .parametric)
                saved.hasUSDZ = true
            } catch {
                saved.hasUSDZ = false
                errorMessage = "Scan gespeichert. USDZ konnte noch nicht erstellt werden: \(error.localizedDescription)"
            }
        }
        if let mesh {
            try mesh.write(to: staging.appendingPathComponent("mesh.obj"), options: .atomic)
            saved.hasMesh = true
        }
        try JSONEncoder().encode(saved).write(to: staging.appendingPathComponent("project.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: directory(saved.id))
        projects.insert(saved, at: 0)
        return saved
    }
    func update(_ project: ScanProject) throws {
        try JSONEncoder().encode(project).write(to: file(project.id, "project.json"), options: .atomic)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
    }
    func addPhotoProject(_ project: ScanProject, assets: URL) throws {
        guard let photo = project.photoAsset else { throw SpatialError.message("Fotomodell fehlt.") }
        guard ["object.usdz", "textured-room.json"].contains(photo.modelFile), FileManager.default.fileExists(atPath: assets.appendingPathComponent(photo.modelFile).path) else { throw SpatialError.message("3D-Modell wurde nicht fertiggestellt.") }
        if photo.modelFile == "textured-room.json" {
            let model = try JSONDecoder().decode(TexturedRoomModel.self, from: Data(contentsOf: assets.appendingPathComponent(photo.modelFile)))
            try model.validate()
            guard model.keyframes.allSatisfy({ FileManager.default.fileExists(atPath: assets.appendingPathComponent($0.filename).path) }) else { throw SpatialError.message("Mindestens eine Bildtextur fehlt im Projektarchiv.") }
        }
        // Source photos and model move together on the same volume; failure leaves the draft intact.
        try JSONEncoder().encode(project).write(to: assets.appendingPathComponent("project.json"), options: .atomic)
        try FileManager.default.moveItem(at: assets, to: directory(project.id))
        projects.insert(project, at: 0)
    }
    func delete(_ project: ScanProject) throws {
        try FileManager.default.removeItem(at: directory(project.id))
        projects.removeAll { $0.id == project.id }
    }
    func archive(_ project: ScanProject) throws -> URL {
        let room = project.hasRawRoom ? try Data(contentsOf: file(project.id, "room.json")) : nil
        let mesh = project.hasMesh ? try Data(contentsOf: file(project.id, "mesh.obj")) : nil
        var files: [String: Data]?
        if project.photoAsset != nil {
            files = [:]
            let names = try FileManager.default.contentsOfDirectory(at: directory(project.id), includingPropertiesForKeys: [.fileSizeKey])
                .filter { Self.allowedPhotoFile($0.lastPathComponent) }
            let total = try names.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            guard total < 100_000_000 else { throw SpatialError.message("Für dieses große Fotomodell bitte den ZIP-Export verwenden. JSON-Archive sind auf 100 MB Nutzdaten begrenzt.") }
            for url in names { files?[url.lastPathComponent] = try Data(contentsOf: url) }
        }
        var exported = project
        if exported.kind == .object { exported.photoAsset?.retainedSources = false }
        let archive = ProjectArchive(project: exported, capturedRoom: room, meshOBJ: mesh, photoFiles: files)
        let target = try Exporter.temporaryURL("RJ-Spatial-\(project.id.uuidString.prefix(8)).json")
        try JSONEncoder().encode(archive).write(to: target, options: .atomic)
        return target
    }
    func importArchive(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 150_000_000 else { throw SpatialError.message("Dieses Archiv ist größer als 150 MB.") }
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url))
        guard archive.format == "eu.rjuhas.spatial", archive.version == 1, archive.project.schemaVersion == 1 else { throw SpatialError.message("Dieses Projektformat wird noch nicht unterstützt.") }
        guard archive.project.elements.count <= 10000, archive.project.measurements.count <= 10000 else { throw SpatialError.message("Das Projekt enthält zu viele Elemente.") }
        for element in archive.project.elements {
            guard element.transform.count == 16, element.transform.allSatisfy(\.isFinite), element.dimensions.simd.x.isFinite, element.dimensions.simd.y.isFinite, element.dimensions.simd.z.isFinite else { throw SpatialError.message("Ungültige Geometrie im Archiv.") }
        }
        var project = archive.project
        project.id = UUID(); project.name += " (Import)"
        project.hasUSDZ = false; project.hasRawRoom = false; project.hasMesh = false
        if let photo = project.photoAsset {
            guard let files = archive.photoFiles, files.count <= 102, files[photo.modelFile] != nil, files.keys.allSatisfy(Self.allowedPhotoFile) else { throw SpatialError.message("Das Foto-Projektarchiv ist unvollständig.") }
            let staging = root.appendingPathComponent(".photo-import-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for (name, data) in files { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
            if project.kind == .object { project.photoAsset?.retainedSources = false }
            try addPhotoProject(project, assets: staging)
            return
        }
        let room = try archive.capturedRoom.map { try JSONDecoder().decode(CapturedRoom.self, from: $0) }
        _ = try add(project, room: room, mesh: archive.meshOBJ)
    }
    private static func allowedPhotoFile(_ name: String) -> Bool {
        if ["object.usdz", "textured-room.json"].contains(name) { return true }
        guard name.hasPrefix("photo-"), name.hasSuffix(".jpg") else { return false }
        return Int(name.dropFirst(6).dropLast(4)).map { $0 >= 0 && $0 < 100 } ?? false
    }
}
