import Foundation
import RoomPlan
import simd

struct Point3: Codable, Hashable {
    var x: Float
    var y: Float
    var z: Float
    init(_ v: SIMD3<Float>) { x = v.x; y = v.y; z = v.z }
    init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
}

enum ScanKind: String, Codable, CaseIterable, Identifiable {
    case room, volume, photoRoom, object, measure, mesh
    var id: String { rawValue }
    var title: String {
        switch self { case .room: return "Raumscan"; case .volume: return "Fläche & Volumen"; case .photoRoom: return "Foto-Raum & Rundgang"; case .object: return "Objekt-Fotoscan"; case .measure: return "AR-Maßband"; case .mesh: return "3D-Oberflächen" }
    }
    var icon: String {
        switch self { case .room: return "viewfinder"; case .volume: return "cube.transparent"; case .photoRoom: return "viewfinder.circle.fill"; case .object: return "camera.aperture"; case .measure: return "ruler"; case .mesh: return "cube.transparent.fill" }
    }
    var subtitle: String {
        switch self {
        case .room: return "Wände, Fenster und Möbel als 3D-Plan"
        case .volume: return "Grundfläche, Raumhöhe und Rauminhalt"
        case .photoRoom: return "Echte Bildtexturen, Fotos und begehbares 3D"
        case .object: return "Geführte Fotos für ein texturiertes Objektmodell"
        case .measure: return "Strecken, Umfang und Bodenflächen messen"
        case .mesh: return "LiDAR-Dreiecksnetz erfassen und exportieren"
        }
    }
}

enum ElementKind: String, Codable, CaseIterable, Identifiable {
    case wall, window, door, opening, floor, furniture
    var id: String { rawValue }
    var title: String {
        switch self { case .wall: return "Wand"; case .window: return "Fenster"; case .door: return "Tür"; case .opening: return "Durchgang"; case .floor: return "Boden"; case .furniture: return "Möbel" }
    }
}

struct RoomElement: Codable, Identifiable {
    var id: UUID
    var kind: ElementKind
    var label: String
    var dimensions: Point3
    var transform: [Float]
    var corners: [Point3]
    var confidence: String
    var matrix: simd_float4x4 {
        guard transform.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4(transform[0], transform[1], transform[2], transform[3]),
            SIMD4(transform[4], transform[5], transform[6], transform[7]),
            SIMD4(transform[8], transform[9], transform[10], transform[11]),
            SIMD4(transform[12], transform[13], transform[14], transform[15])))
    }
    func world(_ local: SIMD3<Float>) -> SIMD3<Float> {
        let v = matrix * SIMD4(local.x, local.y, local.z, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    var center: SIMD3<Float> { world(.zero) }
    var endpoints: [SIMD3<Float>] {
        [world(SIMD3(-dimensions.x / 2, 0, 0)), world(SIMD3(dimensions.x / 2, 0, 0))]
    }
    var worldCorners: [SIMD3<Float>] { corners.map { world($0.simd) } }
    static func matrixValues(_ m: simd_float4x4) -> [Float] {
        (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } }
    }
    init(surface: CapturedRoom.Surface, kind: ElementKind, number: Int) {
        id = surface.identifier; self.kind = kind; label = "\(kind.title) \(number)"
        dimensions = Point3(surface.dimensions); transform = Self.matrixValues(surface.transform)
        corners = surface.polygonCorners.map(Point3.init)
        confidence = Self.confidenceName(surface.confidence)
    }
    init(object: CapturedRoom.Object, number: Int) {
        id = object.identifier; kind = .furniture
        let category = String(describing: object.category)
        let names = ["storage": "Schrank", "refrigerator": "Kühlschrank", "stove": "Herd", "bed": "Bett", "sink": "Waschbecken", "washerDryer": "Waschmaschine", "toilet": "Toilette", "bathtub": "Badewanne", "oven": "Backofen", "dishwasher": "Spülmaschine", "table": "Tisch", "sofa": "Sofa", "chair": "Stuhl", "fireplace": "Kamin", "television": "Fernseher", "stairs": "Treppe"]
        label = "\(names[category] ?? category) \(number)"
        dimensions = Point3(object.dimensions); transform = Self.matrixValues(object.transform)
        corners = []; confidence = String(describing: object.confidence)
    }
    private static func confidenceName(_ value: CapturedRoom.Confidence) -> String {
        switch value { case .high: return "high"; case .medium: return "medium"; case .low: return "low"; @unknown default: return "unknown" }
    }
    var confidenceTitle: String {
        switch confidence { case "high": return "Hoch"; case "medium": return "Mittel"; case "low": return "Niedrig"; default: return "Unbekannt" }
    }
}

struct SavedMeasurement: Codable, Identifiable {
    var id = UUID()
    var name: String
    var points: [Point3]
    var isArea: Bool
    var length: Double {
        guard points.count > 1 else { return 0 }
        var value = zip(points, points.dropFirst()).reduce(0.0) { $0 + Double(simd_distance($1.0.simd, $1.1.simd)) }
        if isArea, points.count >= 3 { value += Double(simd_distance(points[0].simd, points[points.count - 1].simd)) }
        return value
    }
    var area: Double? { isArea && points.count >= 3 ? Geometry.areaXZ(points.map(\.simd)) : nil }
}

struct ScanProject: Codable, Identifiable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var createdAt = Date()
    var kind: ScanKind
    var notes = ""
    var favorite = false
    var elements: [RoomElement] = []
    var measurements: [SavedMeasurement] = []
    var meshVertexCount = 0
    var meshFaceCount = 0
    var hasUSDZ = false
    var hasRawRoom = false
    var hasMesh = false
    var heightOverride: Double?
    var photoAsset: PhotoAssetInfo?
    var floorPolygons: [[SIMD3<Float>]] {
        let native = elements.filter { $0.kind == .floor }.map(\.worldCorners).filter { $0.count >= 3 && Geometry.areaXZ($0) > 0.01 }
        if !native.isEmpty { return native }
        if let boundary = Geometry.closedBoundary(elements.filter { $0.kind == .wall }) { return [boundary] }
        return []
    }
    var floorArea: Double? {
        let polygons = floorPolygons
        return polygons.isEmpty ? nil : polygons.reduce(0) { $0 + Geometry.areaXZ($1) }
    }
    var roomHeight: Double? {
        if let heightOverride { return heightOverride }
        let heights = elements.filter { $0.kind == .wall && $0.dimensions.y > 0 }.map { Double($0.dimensions.y) }.sorted()
        guard !heights.isEmpty else { return nil }
        let middle = heights.count / 2
        return heights.count.isMultiple(of: 2) ? (heights[middle-1] + heights[middle]) / 2 : heights[middle]
    }
    var volume: Double? {
        guard let floorArea, let roomHeight else { return nil }
        return floorArea * roomHeight
    }
    var wallArea: Double {
        elements.filter { $0.kind == .wall }.reduce(0) { $0 + Double($1.dimensions.x * $1.dimensions.y) }
    }
    var openingArea: Double {
        elements.filter { [.door, .window, .opening].contains($0.kind) }.reduce(0) { $0 + Double($1.dimensions.x * $1.dimensions.y) }
    }
    var netWallArea: Double { max(0, wallArea - openingArea) }
    var perimeter: Double { elements.filter { $0.kind == .wall }.reduce(0) { $0 + Double($1.dimensions.x) } }
    var boundarySource: String {
        elements.contains { $0.kind == .floor && $0.corners.count >= 3 } ? "Erkannte Bodenpolygone" : "Geschlossene Wandkontur"
    }
}

enum Geometry {
    static func areaXZ(_ points: [SIMD3<Float>]) -> Double {
        guard points.count >= 3 else { return 0 }
        return abs(points.indices.reduce(0.0) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + Double(a.x) * Double(b.z) - Double(b.x) * Double(a.z)
        }) / 2
    }
    static func distanceXZ(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }
    static func closedBoundary(_ walls: [RoomElement]) -> [SIMD3<Float>]? {
        guard walls.count >= 3 else { return nil }
        var remaining = walls.map(\.endpoints)
        let first = remaining.removeFirst()
        var result = first
        while !remaining.isEmpty {
            let current = result[result.count - 1]
            var best: (index: Int, reverse: Bool, distance: Float)?
            for (index, edge) in remaining.enumerated() {
                for reverse in [false, true] {
                    let d = distanceXZ(current, edge[reverse ? 1 : 0])
                    if best == nil || d < best!.distance { best = (index, reverse, d) }
                }
            }
            guard let best, best.distance < 0.25 else { return nil }
            let edge = remaining.remove(at: best.index)
            result.append(edge[best.reverse ? 0 : 1])
        }
        guard distanceXZ(result[0], result[result.count - 1]) < 0.25 else { return nil }
        result.removeLast()
        guard isSimpleXZ(result) else { return nil }
        return result
    }
    static func isSimpleXZ(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 3 else { return false }
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
            (b.x-a.x)*(c.z-a.z) - (b.z-a.z)*(c.x-a.x)
        }
        for i in points.indices {
            let ni = (i+1) % points.count
            for j in points.indices where j > i {
                let nj = (j+1) % points.count
                if ni == j || nj == i { continue }
                if cross(points[i], points[ni], points[j]) * cross(points[i], points[ni], points[nj]) < 0 && cross(points[j], points[nj], points[i]) * cross(points[j], points[nj], points[ni]) < 0 { return false }
            }
        }
        return true
    }
}

enum DisplayUnits: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Meter / m²" : "Fuß / ft²" }
    func length(_ value: Double) -> String { format(value * (self == .metric ? 1 : 3.28084)) + (self == .metric ? " m" : " ft") }
    func area(_ value: Double) -> String { format(value * (self == .metric ? 1 : 10.76391)) + (self == .metric ? " m²" : " ft²") }
    func volume(_ value: Double) -> String { format(value * (self == .metric ? 1 : 35.31467)) + (self == .metric ? " m³" : " ft³") }
    private func format(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(2))) }
}
