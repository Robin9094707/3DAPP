import SwiftUI
import UIKit

enum SpatialStyle {
    static let mint = Color(red: 0.20, green: 0.88, blue: 0.73)
    static let blue = Color(red: 0.32, green: 0.58, blue: 1)
}

struct SpatialBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(colors: [SpatialStyle.blue.opacity(scheme == .dark ? 0.17 : 0.08), .clear, SpatialStyle.mint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }.ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            } else { fallback(content) }
            #else
            fallback(content)
            #endif
        }
    }
    private func fallback(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.08)))
    }
}

extension View {
    func spatialGlass() -> some View { modifier(GlassCard()) }
}

struct MetricTile: View {
    var title: String
    var value: String
    var icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundStyle(SpatialStyle.mint).font(.title3)
            Text(value).font(.system(.title3, design: .rounded, weight: .bold)).minimumScaleFactor(0.65).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).spatialGlass()
    }
}

struct ActionCard: View {
    var kind: ScanKind
    var available: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: kind.icon).font(.title2).foregroundStyle(available ? SpatialStyle.mint : .secondary)
                    .frame(width: 48, height: 52).background(SpatialStyle.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(kind.title).font(.headline).foregroundStyle(.primary)
                    Text(available ? kind.subtitle : "Auf diesem Gerät nicht verfügbar").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: available ? "arrow.up.right" : "info.circle").foregroundStyle(.secondary)
            }.padding(18).spatialGlass()
        }.buttonStyle(.plain)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SharePayload: Identifiable { let id = UUID(); var urls: [URL] }

func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType = .success) {
    let enabled = (UserDefaults.standard.object(forKey: "haptics") as? Bool) ?? true
    guard enabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(type)
}
