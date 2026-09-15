import Foundation

// Streaming, uncompressed ZIP export avoids loading an entire original photo set into memory.
enum PhotoZIP {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
    private static func update(_ crc: UInt32, bytes: Data) -> UInt32 {
        bytes.reduce(crc) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }
    private static func u16(_ v: UInt16) -> Data { var n = v.littleEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    private static func u32(_ v: UInt32) -> Data { var n = v.littleEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    private static func join(_ parts: [Data]) -> Data {
        var result = Data()
        for part in parts { result.append(part) }
        return result
    }
    static func write(folder: URL, filename: String) throws -> URL {
        let url = try Exporter.temporaryURL(filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw SpatialError.message("ZIP-Datei konnte nicht erstellt werden.") }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: .skipsHiddenFiles) else { throw SpatialError.message("Exportordner nicht lesbar.") }
        var central = Data()
        var count: UInt16 = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = String(file.path.dropFirst(folder.path.count+1))
            let name = Data(path.utf8)
            let size64 = UInt64(values.fileSize ?? 0), offset64 = try output.offset()
            guard size64 < UInt32.max, offset64 < UInt32.max, name.count < UInt16.max, count < UInt16.max else { throw SpatialError.message("Dieser Export überschreitet das unterstützte ZIP-Limit von 4 GB.") }
            let size = UInt32(size64), offset = UInt32(offset64)
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var crc: UInt32 = 0xffffffff
            while let data = try input.read(upToCount: 262144), !data.isEmpty { crc = update(crc, bytes: data) }
            crc ^= 0xffffffff
            try input.seek(toOffset: 0)
            let local = join([u32(0x04034b50), u16(20), u16(0x0800), u16(0), u16(0), u16(33), u32(crc), u32(size), u32(size), u16(UInt16(name.count)), u16(0), name])
            try output.write(contentsOf: local)
            while let data = try input.read(upToCount: 262144), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
            try input.close()
            let record = join([u32(0x02014b50), u16(20), u16(20), u16(0x0800), u16(0), u16(0), u16(33), u32(crc), u32(size), u32(size), u16(UInt16(name.count)), u16(0), u16(0), u16(0), u16(0), u32(0), u32(offset), name])
            central += record; count += 1
        }
        let start = try output.offset()
        guard start < UInt32.max, central.count < UInt32.max else { throw SpatialError.message("ZIP-Datei zu groß.") }
        try output.write(contentsOf: central)
        let end = join([u32(0x06054b50), u16(0), u16(0), u16(count), u16(count), u32(UInt32(central.count)), u32(UInt32(start)), u16(0)])
        try output.write(contentsOf: end)
        return url
    }
}

enum TexturedOBJ {
    static func export(model: TexturedRoomModel, assets: URL) throws -> URL {
        let root = try Exporter.temporaryURL("model.obj").deletingLastPathComponent()
        let target = root.appendingPathComponent("model.obj")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        try write("# RJ Spatial textured room; meters; Y up\nmtllib materials.mtl\no Room\n")
        var buffer = ""
        for (index, p) in model.vertices.enumerated() {
            buffer += "v \(p.x) \(p.y) \(p.z)\n"
            if index % 4000 == 3999 { try write(buffer); buffer = "" }
        }
        try write(buffer)
        var materials = ""
        var textureOffset = 1
        for batch in model.batches {
            try Task.checkCancellation()
            let name = batch.frameIndex < 0 ? "unobserved" : "photo_\(batch.frameIndex)"
            materials += "newmtl \(name)\nKd \(batch.frameIndex < 0 ? "0.55 0.55 0.55" : "1 1 1")\nillum 1\n"
            if batch.frameIndex >= 0 {
                let photo = model.keyframes[batch.frameIndex]
                materials += "map_Kd \(photo.filename)\n"
                try FileManager.default.copyItem(at: assets.appendingPathComponent(photo.filename), to: root.appendingPathComponent(photo.filename))
            }
            try write("usemtl \(name)\n")
            buffer = ""
            for i in stride(from: 0, to: batch.uv.count, by: 2) {
                buffer += "vt \(batch.uv[i]) \(batch.uv[i+1])\n"
                if buffer.utf8.count > 262144 { try write(buffer); buffer = "" }
            }
            try write(buffer); buffer = ""
            for i in stride(from: 0, to: batch.indices.count, by: 3) {
                buffer += "f \(batch.indices[i]+1)/\(textureOffset+i) \(batch.indices[i+1]+1)/\(textureOffset+i+1) \(batch.indices[i+2]+1)/\(textureOffset+i+2)\n"
                if buffer.utf8.count > 262144 { try write(buffer); buffer = "" }
            }
            try write(buffer); textureOffset += batch.indices.count
        }
        try output.synchronize()
        try materials.write(to: root.appendingPathComponent("materials.mtl"), atomically: true, encoding: .utf8)
        return try PhotoZIP.write(folder: root, filename: "RJ-Spatial-Foto-Raum.zip")
    }
}
