import Foundation
import simd

struct PhotoAssetInfo: Codable {
    var imageCount: Int
    var texturedFraction: Double?
    var quality: String
    var modelFile: String
    var retainedSources: Bool
}

enum RoomPhotoQuality: String, CaseIterable, Identifiable {
    case balanced, detail
    var id: String { rawValue }
    var title: String { self == .detail ? "Mehr Details" : "Ausgewogen" }
    var imageWidth: Int { self == .detail ? 1920 : 1280 }
    var frameLimit: Int { self == .detail ? 80 : 48 }
    var vertexLimit: Int { self == .detail ? 600_000 : 350_000 }
}

struct PhotoKeyframe: Codable, Identifiable {
    var id: Int
    var filename: String
    var pose: [Float]
    var width: Int
    var height: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var matrix: simd_float4x4 { PhotoMath.matrix(pose) }
}

enum PhotoMath {
    static func matrix(_ v: [Float]) -> simd_float4x4 {
        guard v.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4(v[0],v[1],v[2],v[3]), SIMD4(v[4],v[5],v[6],v[7]), SIMD4(v[8],v[9],v[10],v[11]), SIMD4(v[12],v[13],v[14],v[15])))
    }
    static func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    static func project(_ p: SIMD3<Float>, inverse: simd_float4x4, frame: PhotoKeyframe) -> SIMD3<Float>? {
        let camera = inverse * SIMD4(p.x,p.y,p.z,1)
        let depth = -camera.z
        guard depth > 0.08 else { return nil }
        let u = (frame.fx * camera.x / depth + frame.cx) / Float(frame.width)
        let v = (frame.cy - frame.fy * camera.y / depth) / Float(frame.height)
        guard u > 0.015, u < 0.985, v > 0.015, v < 0.985 else { return nil }
        return SIMD3(u,v,depth)
    }
}

struct TextureBatch: Codable {
    var frameIndex: Int
    var indices: [UInt32]
    // One UV pair per triangle corner; V follows the OBJ/SceneKit bottom-left origin.
    var uv: [Float]
}

struct TexturedRoomModel: Codable {
    var version = 1
    var vertices: [Point3]
    var batches: [TextureBatch]
    var keyframes: [PhotoKeyframe]
    var texturedFraction: Double
    var triangleCount: Int { batches.reduce(0) { $0 + $1.indices.count / 3 } }
    func validate() throws {
        guard version == 1, !vertices.isEmpty, vertices.count <= 650_000, keyframes.count <= 100, !keyframes.isEmpty, batches.count <= 101 else { throw SpatialError.message("Ungültige Größe des Foto-Raummodells.") }
        guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }), texturedFraction.isFinite else { throw SpatialError.message("Ungültige 3D-Koordinaten.") }
        guard Set(keyframes.map(\.id)).count == keyframes.count, triangleCount <= 1_500_000 else { throw SpatialError.message("Ungültige Fotoliste oder zu viele Dreiecke.") }
        for frame in keyframes {
            guard frame.pose.count == 16, frame.pose.allSatisfy(\.isFinite), frame.id >= 0, frame.id < 100, frame.filename == "photo-\(frame.id).jpg", frame.width > 0, frame.height > 0, frame.fx.isFinite, frame.fy.isFinite, frame.cx.isFinite, frame.cy.isFinite, frame.fx > 0, frame.fy > 0 else { throw SpatialError.message("Ungültiger Fotostandpunkt.") }
        }
        for batch in batches {
            guard batch.indices.count % 3 == 0, batch.uv.count == batch.indices.count * 2, batch.indices.allSatisfy({ Int($0) < vertices.count }), batch.uv.allSatisfy(\.isFinite), batch.frameIndex >= -1, batch.frameIndex < keyframes.count else { throw SpatialError.message("Ungültige Bildtextur-Zuordnung.") }
        }
    }
}

struct TextureDepthFrame {
    var photo: PhotoKeyframe
    var depth: [Float]
    var depthWidth: Int
    var depthHeight: Int
    var inverse: simd_float4x4
    var cameraPosition: SIMD3<Float>
    func visible(_ projected: SIMD3<Float>) -> Bool {
        guard depthWidth > 0, depthHeight > 0 else { return false }
        let x = min(depthWidth-1, max(0, Int(projected.x * Float(depthWidth))))
        let y = min(depthHeight-1, max(0, Int(projected.y * Float(depthHeight))))
        let measured = depth[y*depthWidth+x]
        return measured.isFinite && measured > 0 && abs(measured - projected.z) < max(0.10, projected.z * 0.045)
    }
}

enum RoomTexturing {
    static func build(mesh: MeshSnapshot, frames: [TextureDepthFrame], progress: (Double) -> Void) throws -> TexturedRoomModel {
        guard !mesh.faces.isEmpty, frames.count >= 3 else { throw SpatialError.message("Es werden mehr erfasste Oberflächen und mindestens drei gute Fotos benötigt.") }
        var batches = (0..<frames.count).map { TextureBatch(frameIndex: $0, indices: [], uv: []) }
        var missing = TextureBatch(frameIndex: -1, indices: [], uv: [])
        var colored = 0
        for i in stride(from: 0, to: mesh.faces.count, by: 3) {
            if i % 3000 == 0 { try Task.checkCancellation(); progress(Double(i) / Double(mesh.faces.count)) }
            let ids = [mesh.faces[i], mesh.faces[i+1], mesh.faces[i+2]]
            let p = ids.map { mesh.vertices[Int($0)] }
            let center = (p[0] + p[1] + p[2]) / 3
            let normalVector = simd_cross(p[1]-p[0], p[2]-p[0])
            guard simd_length_squared(normalVector) > 0.00000001 else { continue }
            let normal = simd_normalize(normalVector)
            var bestIndex = -1
            var bestScore: Float = 0
            var bestUV: [Float] = []
            for (index, frame) in frames.enumerated() {
                guard let c = PhotoMath.project(center, inverse: frame.inverse, frame: frame.photo), frame.visible(c) else { continue }
                let facing = abs(simd_dot(normal, simd_normalize(frame.cameraPosition-center)))
                guard facing > 0.20 else { continue }
                let edge = min(min(c.x, 1-c.x), min(c.y, 1-c.y))
                let score = facing * (0.4 + edge) / max(0.25, c.z*c.z)
                guard score > bestScore else { continue }
                var uv: [Float] = []
                for point in p {
                    guard let q = PhotoMath.project(point, inverse: frame.inverse, frame: frame.photo), frame.visible(q) else { break }
                    uv += [q.x, 1-q.y]
                }
                guard uv.count == 6 else { continue }
                bestScore = score; bestIndex = index; bestUV = uv
            }
            if bestIndex >= 0 { batches[bestIndex].indices += ids; batches[bestIndex].uv += bestUV; colored += 1 }
            else { missing.indices += ids; missing.uv += [0,0,0,0,0,0] }
        }
        batches.removeAll { $0.indices.isEmpty }
        if !missing.indices.isEmpty { batches.append(missing) }
        let total = batches.reduce(0) { $0 + $1.indices.count/3 }
        let result = TexturedRoomModel(vertices: mesh.vertices.map(Point3.init), batches: batches, keyframes: frames.map(\.photo), texturedFraction: Double(colored)/Double(max(total,1)))
        try result.validate(); progress(1)
        return result
    }
}
