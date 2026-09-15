import SwiftUI
import simd

struct PlanProjection {
    var scale: CGFloat
    var offset: CGPoint
    init(project: ScanProject, rect: CGRect) {
        var points = project.elements.filter { $0.kind == .wall }.flatMap(\.endpoints)
        points += project.floorPolygons.flatMap { $0 }
        points += project.measurements.flatMap { $0.points.map(\.simd) }
        if points.isEmpty { points = [SIMD3(-1,0,-1), SIMD3(1,0,1)] }
        let minX = CGFloat(points.map(\.x).min() ?? -1), maxX = CGFloat(points.map(\.x).max() ?? 1)
        let minZ = CGFloat(points.map(\.z).min() ?? -1), maxZ = CGFloat(points.map(\.z).max() ?? 1)
        let width = max(maxX - minX, 0.5), height = max(maxZ - minZ, 0.5)
        scale = min(max(1, rect.width - 90) / width, max(1, rect.height - 90) / height)
        offset = CGPoint(x: rect.midX - (minX+maxX)/2*scale, y: rect.midY - (minZ+maxZ)/2*scale)
    }
    func point(_ v: SIMD3<Float>) -> CGPoint { CGPoint(x: CGFloat(v.x)*scale + offset.x, y: CGFloat(v.z)*scale + offset.y) }
}

enum PlanPainter {
    static func draw(project: ScanProject, in rect: CGRect, context: CGContext, units: DisplayUnits, labels: Bool = true, furniture: Bool = true, dark: Bool = false, selected: UUID? = nil) {
        let projection = PlanProjection(project: project, rect: rect)
        let foreground: UIColor = dark ? .white : UIColor(red: 0.08, green: 0.15, blue: 0.21, alpha: 1)
        context.saveGState(); context.clip(to: rect)
        context.setStrokeColor(foreground.withAlphaComponent(0.07).cgColor); context.setLineWidth(0.5)
        let grid = max(14, projection.scale / 2)
        for x in stride(from: rect.minX, through: rect.maxX, by: grid) { context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY)) }
        for y in stride(from: rect.minY, through: rect.maxY, by: grid) { context.move(to: CGPoint(x: rect.minX, y: y)); context.addLine(to: CGPoint(x: rect.maxX, y: y)) }
        context.strokePath()
        for polygon in project.floorPolygons {
            guard let first = polygon.first else { continue }
            context.move(to: projection.point(first))
            polygon.dropFirst().forEach { context.addLine(to: projection.point($0)) }; context.closePath()
            context.setFillColor(UIColor.systemMint.withAlphaComponent(0.12).cgColor); context.fillPath()
        }
        if furniture {
            for element in project.elements where element.kind == .furniture {
                let d = element.dimensions
                let points = [SIMD3(-d.x/2,0,-d.z/2), SIMD3(d.x/2,0,-d.z/2), SIMD3(d.x/2,0,d.z/2), SIMD3(-d.x/2,0,d.z/2)].map { projection.point(element.world($0)) }
                context.move(to: points[0]); points.dropFirst().forEach { context.addLine(to: $0) }; context.closePath()
                context.setFillColor(UIColor.systemIndigo.withAlphaComponent(0.18).cgColor); context.setStrokeColor(UIColor.systemIndigo.withAlphaComponent(0.5).cgColor); context.setLineWidth(1); context.drawPath(using: .fillStroke)
            }
        }
        for kind in [ElementKind.wall, .opening, .door, .window] {
            for e in project.elements where e.kind == kind {
                let a = projection.point(e.endpoints[0]), b = projection.point(e.endpoints[1])
                let color: UIColor = selected == e.id ? .systemYellow : kind == .wall ? foreground : RoomSceneView.Coordinator.color(kind)
                context.setStrokeColor(color.cgColor); context.setLineWidth(kind == .wall ? 4 : 5); context.setLineCap(.round)
                if kind == .opening { context.setLineDash(phase: 0, lengths: [4, 4]) } else { context.setLineDash(phase: 0, lengths: []) }
                context.move(to: a); context.addLine(to: b); context.strokePath()
                if labels && (kind == .wall || selected == e.id) {
                    let length = max(hypot(b.x-a.x, b.y-a.y), 1)
                    let mid = CGPoint(x: (a.x+b.x)/2 - (b.y-a.y)/length*15, y: (a.y+b.y)/2 + (b.x-a.x)/length*15)
                    let text = units.length(Double(e.dimensions.x)) as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: foreground]
                    let size = text.size(withAttributes: attributes)
                    text.draw(at: CGPoint(x: mid.x-size.width/2, y: mid.y-size.height/2), withAttributes: attributes)
                }
            }
        }
        context.setLineDash(phase: 0, lengths: [])
        for m in project.measurements {
            guard let first = m.points.first else { continue }
            context.move(to: projection.point(first.simd)); m.points.dropFirst().forEach { context.addLine(to: projection.point($0.simd)) }
            if m.isArea { context.closePath() }
            context.setStrokeColor(UIColor.systemTeal.cgColor); context.setLineWidth(2); context.strokePath()
        }
        context.restoreGState()
    }
}

final class PlanUIView: UIView {
    var project: ScanProject?
    var units: DisplayUnits = .metric
    var labels = true
    var furniture = true
    var selected: UUID?
    var onSelect: ((UUID?) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let project else { return }
        PlanPainter.draw(project: project, in: bounds, context: context, units: units, labels: labels, furniture: furniture, dark: traitCollection.userInterfaceStyle == .dark, selected: selected)
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let project else { return }
        let projection = PlanProjection(project: project, rect: bounds)
        let point = gesture.location(in: self)
        var best: (UUID, CGFloat)?
        for e in project.elements where [.wall, .window, .door, .opening].contains(e.kind) {
            let a = projection.point(e.endpoints[0]), b = projection.point(e.endpoints[1])
            let dx = b.x-a.x, dy = b.y-a.y
            let t = max(0, min(1, ((point.x-a.x)*dx + (point.y-a.y)*dy) / max(0.001, dx*dx+dy*dy)))
            let distance = hypot(point.x - a.x - t*dx, point.y - a.y - t*dy)
            if distance < 22 && (best == nil || distance < best!.1) { best = (e.id, distance) }
        }
        onSelect?(best?.0)
    }
}

struct FloorPlanView: UIViewRepresentable {
    var project: ScanProject
    var units: DisplayUnits
    var labels: Bool
    var furniture: Bool
    @Binding var selected: UUID?
    func makeUIView(context: Context) -> PlanUIView { PlanUIView() }
    func updateUIView(_ view: PlanUIView, context: Context) {
        view.project = project; view.units = units; view.labels = labels; view.furniture = furniture; view.selected = selected
        view.onSelect = { selected = $0 }; view.setNeedsDisplay()
    }
}
