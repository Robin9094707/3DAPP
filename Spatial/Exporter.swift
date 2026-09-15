import Foundation
import UIKit

enum Exporter {
    static func temporaryURL(_ filename: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(filename)
    }
    static func csv(_ project: ScanProject) throws -> URL {
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["type,name,width_m,height_m,depth_m,length_m,area_m2,confidence"]
        for e in project.elements {
            lines.append([e.kind.rawValue, quote(e.label), String(e.dimensions.x), String(e.dimensions.y), String(e.dimensions.z), "", "", e.confidence].joined(separator: ","))
        }
        for m in project.measurements {
            lines.append(["measurement", quote(m.name), "", "", "", String(m.length), m.area.map { String($0) } ?? "", ""].joined(separator: ","))
        }
        if let area = project.floorArea { lines.append("summary,\"Floor area (estimated)\",,,,,\(area),") }
        if let height = project.roomHeight { lines.append("summary,\"Room height (estimated)\",,\(height),,,,") }
        let url = try temporaryURL("RJ-Spatial-Masse.csv")
        try ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    static func svg(_ project: ScanProject, units: DisplayUnits) throws -> URL {
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let projection = PlanProjection(project: project, rect: CGRect(x: 0, y: 80, width: 1000, height: 750))
        func p(_ v: SIMD3<Float>) -> String { let q = projection.point(v); return "\(q.x),\(q.y)" }
        var xml = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 900">
        <rect width="1000" height="900" fill="#fff"/>
        <text x="40" y="42" font-family="sans-serif" font-size="24" fill="#122636">\(escape(project.name))</text>
        <text x="40" y="66" font-family="sans-serif" font-size="12">RJ Spatial · Grundriss · Näherungswerte</text>
        """
        for polygon in project.floorPolygons { xml += "<polygon points=\"\(polygon.map(p).joined(separator: " "))\" fill=\"#dcf7f0\"/>\n" }
        for e in project.elements where e.kind == .furniture {
            let d = e.dimensions
            let points = [SIMD3(-d.x/2,0,-d.z/2), SIMD3(d.x/2,0,-d.z/2), SIMD3(d.x/2,0,d.z/2), SIMD3(-d.x/2,0,d.z/2)].map { p(e.world($0)) }
            xml += "<polygon points=\"\(points.joined(separator: " "))\" fill=\"#e4e2ff\" stroke=\"#7970d6\"/>\n"
        }
        for kind in [ElementKind.wall, .opening, .door, .window] {
            for e in project.elements where e.kind == kind {
                let a = projection.point(e.endpoints[0]), b = projection.point(e.endpoints[1])
                let color = kind == .wall ? "#122636" : kind == .window ? "#2589e8" : kind == .door ? "#e58936" : "#d75188"
                xml += "<line x1=\"\(a.x)\" y1=\"\(a.y)\" x2=\"\(b.x)\" y2=\"\(b.y)\" stroke=\"\(color)\" stroke-width=\"5\" stroke-linecap=\"round\"/>\n"
                if kind == .wall {
                    xml += "<text x=\"\((a.x+b.x)/2)\" y=\"\((a.y+b.y)/2-12)\" text-anchor=\"middle\" font-family=\"sans-serif\" font-size=\"13\">\(escape(units.length(Double(e.dimensions.x))))</text>\n"
                }
            }
        }
        for m in project.measurements {
            let points = m.points.map { p($0.simd) }.joined(separator: " ")
            let tag = m.isArea ? "polygon" : "polyline"
            xml += "<\(tag) points=\"\(points)\" fill=\"none\" stroke=\"#00897b\" stroke-width=\"3\"/>\n"
        }
        xml += "<text x=\"40\" y=\"862\" font-family=\"sans-serif\" font-size=\"12\">Fenster: Blau · Türen: Orange · Durchgänge: Rosa · Möbel: Violett</text>\n</svg>"
        let url = try temporaryURL("RJ-Spatial-Grundriss.svg")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    static func pdf(_ project: ScanProject, units: DisplayUnits) throws -> URL {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let url = try temporaryURL("RJ-Spatial-Bericht.pdf")
        try renderer.writePDF(to: url) { context in
            var y: CGFloat = 40
            var page = 0
            func beginPage() {
                context.beginPage(); y = 42; page += 1
                ("RJ SPATIAL · \(page)" as NSString).draw(at: CGPoint(x: 40, y: 802), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
            }
            func line(_ text: String, size: CGFloat = 11, bold: Bool = false) {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black, .paragraphStyle: paragraph]
                let rect = (text as NSString).boundingRect(with: CGSize(width: 515, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
                if y + rect.height + 12 > 775 { beginPage() }
                (text as NSString).draw(in: CGRect(x: 40, y: y, width: 515, height: rect.height + 4), withAttributes: attrs)
                y += rect.height + 12
            }
            beginPage()
            line(project.name, size: 24, bold: true)
            line("\(project.kind.title) · \(project.createdAt.formatted(date: .long, time: .shortened))")
            if !project.elements.isEmpty || !project.measurements.isEmpty {
                PlanPainter.draw(project: project, in: CGRect(x: 40, y: y, width: 515, height: 310), context: context.cgContext, units: units)
                y += 325
                line("Grundriss · Fenster blau · Türen orange · Möbel violett", size: 9)
            }
            if let area = project.floorArea { line("Grundfläche ≈ \(units.area(area))", size: 15, bold: true) }
            if let height = project.roomHeight { line("Raumhöhe ≈ \(units.length(height))") }
            if let volume = project.volume { line("Rauminhalt ≈ \(units.volume(volume))") }
            if !project.elements.isEmpty {
                line("Wandfläche brutto ≈ \(units.area(project.wallArea)) · abzüglich Öffnungen ≈ \(units.area(project.netWallArea))")
            }
            line("Sensorbasierte Näherungswerte. Volumen = Grundfläche × Raumhöhe; Dachschrägen werden nicht berücksichtigt. Vor verbindlicher Planung nachmessen.", size: 9)
            if !project.elements.isEmpty {
                line("Erkannte Elemente", size: 17, bold: true)
                for e in project.elements { line("\(e.label): \(units.length(Double(e.dimensions.x))) × \(units.length(Double(e.dimensions.y))) × \(units.length(Double(e.dimensions.z))) · Erkennung: \(e.confidenceTitle)") }
            }
            if !project.measurements.isEmpty {
                line("AR-Messungen", size: 17, bold: true)
                for m in project.measurements {
                    line("\(m.name): \(units.length(m.length))\(m.area.map { " · " + units.area($0) } ?? "")")
                }
            }
            if project.hasMesh { line("LiDAR-Netz: \(project.meshVertexCount) Punkte · \(project.meshFaceCount) Dreiecke. 3D-Geometrie separat als OBJ exportieren.") }
            if !project.notes.isEmpty {
                line("Notizen", size: 17, bold: true)
                for paragraph in project.notes.components(separatedBy: .newlines) {
                    var remaining = paragraph
                    while !remaining.isEmpty { let chunk = String(remaining.prefix(600)); line(chunk); remaining.removeFirst(chunk.count) }
                }
            }
        }
        return url
    }
}
