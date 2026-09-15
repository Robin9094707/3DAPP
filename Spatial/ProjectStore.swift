import Foundation
import Combine
import RoomPlan

struct ProjectArchive: Codable {
    var format = "eu.rjuhas.spatial"
    var version = 1
    var project: ScanProject
    var capturedRoom: Data?
    var meshOBJ: Data?
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
    func delete(_ project: ScanProject) throws {
        try FileManager.default.removeItem(at: directory(project.id))
        projects.removeAll { $0.id == project.id }
    }
    func archive(_ project: ScanProject) throws -> URL {
        let room = project.hasRawRoom ? try Data(contentsOf: file(project.id, "room.json")) : nil
        let mesh = project.hasMesh ? try Data(contentsOf: file(project.id, "mesh.obj")) : nil
        let archive = ProjectArchive(project: project, capturedRoom: room, meshOBJ: mesh)
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
        let room = try archive.capturedRoom.map { try JSONDecoder().decode(CapturedRoom.self, from: $0) }
        _ = try add(project, room: room, mesh: archive.meshOBJ)
    }
}
