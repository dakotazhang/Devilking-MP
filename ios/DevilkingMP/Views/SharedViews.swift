import SwiftUI
import UIKit
import ImageIO

enum DKTheme {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let background = adaptive(light: UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1), dark: UIColor(red: 0.035, green: 0.055, blue: 0.10, alpha: 1))
    static let card = adaptive(light: .secondarySystemGroupedBackground, dark: UIColor(red: 0.075, green: 0.105, blue: 0.17, alpha: 1))
    static let text = Color(uiColor: .label)
    static let accent = adaptive(light: UIColor(red: 0.02, green: 0.40, blue: 0.70, alpha: 1), dark: UIColor(red: 0.48, green: 0.79, blue: 1.0, alpha: 1))
    static let muted = Color(uiColor: .secondaryLabel)
    static let green = adaptive(light: UIColor(red: 0.03, green: 0.45, blue: 0.30, alpha: 1), dark: UIColor(red: 0.43, green: 0.85, blue: 0.69, alpha: 1))
    static let amber = adaptive(light: UIColor(red: 0.62, green: 0.35, blue: 0.0, alpha: 1), dark: UIColor(red: 1.0, green: 0.76, blue: 0.38, alpha: 1))
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

extension AppFontSize {
    func dynamicTypeSize(system: DynamicTypeSize) -> DynamicTypeSize {
        switch self { case .system: return system; case .large: return max(system, .xLarge); case .extraLarge: return max(system, .xxxLarge) }
    }
}

extension ServiceKind {
    /// Protocol fallback only. Saved connections use their user-defined name.
    var compactTitle: String { title }
}

struct DKCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DKTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(DKTheme.muted.opacity(0.10), lineWidth: 1))
    }
}

struct DKSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title)).font(.title3.weight(.bold)).foregroundStyle(DKTheme.text)
            if let subtitle { Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(DKTheme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DKEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(DKTheme.accent)
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(DKTheme.muted).multilineTextAlignment(.center)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

struct DKStatus: View {
    let text: String
    var color: Color = DKTheme.green
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(LocalizedStringKey(text)).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
    }
}

struct DKMetric: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = DKTheme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(title), systemImage: symbol).font(.caption).foregroundStyle(DKTheme.muted)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DKInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(LocalizedStringKey(title)).font(.subheadline).foregroundStyle(DKTheme.muted)
            Spacer(minLength: 0)
            Text(LocalizedStringKey(value.isEmpty ? "—" : value)).font(.subheadline).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct DKPoster: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let url: String?
    var width: CGFloat = 64
    var height: CGFloat = 92
    var allowRetry = false
    @State private var posterImage: UIImage?
    @State private var failed = false
    @State private var retryToken = UUID()
    @State private var forceNextReload = false

    var body: some View {
        content
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(!allowRetry && !uiFixtureActive)
            .accessibilityLabel(Text(LocalizedStringKey(uiFixtureActive ? (posterImage == nil ? "合成海报占位" : "合成海报已载入") : "海报")))
            .task(id: loadKey) { await loadArtwork() }
    }

    @ViewBuilder private var content: some View {
        if let posterImage {
            Image(uiImage: posterImage).resizable().scaledToFill()
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [DKTheme.accent.opacity(0.18), DKTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "film").font(.title2).foregroundStyle(DKTheme.accent.opacity(0.65))
                if failed && allowRetry {
                    Button {
                        forceNextReload = true
                        retryToken = UUID()
                    } label: {
                        Label("重试海报", systemImage: "arrow.clockwise").font(.caption2)
                    }.buttonStyle(.bordered).accessibilityIdentifier("poster.retry")
                }
            }
        }
    }

    private var loadKey: String {
        "\(url?.hashValue ?? 0)|\(model.locked)|\(model.mpArtworkRefreshToken)|\(scenePhase == .active)|\(retryToken)"
    }

    private var uiFixtureActive: Bool {
        #if DEBUG
        return model.uiFixtureMode
        #else
        return false
        #endif
    }

    private func loadArtwork() async {
        let forceReload = forceNextReload
        forceNextReload = false
        posterImage = nil
        failed = false
        guard !model.locked, scenePhase == .active, let url, !url.isEmpty else { return }
        let data: Data?
        if url.hasPrefix("dkemby:") {
            let id = String(url.dropFirst("dkemby:".count))
            if id.isEmpty { data = nil }
            else { data = await model.loadPoster(id) }
        } else {
            // MP's own image proxy handles source anti-hotlink requirements.
            // Credentials never get attached to an external artwork request here.
            data = await model.loadMPArtwork(url, forceReload: forceReload)
        }
        guard !Task.isCancelled, !model.locked, scenePhase == .active else { return }
        if let data, let image = Self.thumbnail(data, width: width, height: height) {
            posterImage = image
        } else {
            failed = true
        }
    }

    /// Decode only the displayed pixel size. Full-resolution posters are not
    /// repeatedly decoded as the user scrolls through a recommendation grid.
    private static func thumbnail(_ data: Data, width: CGFloat, height: CGFloat) -> UIImage? {
        let scale = UIScreen.main.scale
        let pixels = min(1200, max(64, Int(max(width, height) * scale)))
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}

struct DKServiceLink: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let kind: ServiceKind
    var title: String = "打开原管理页面"
    var body: some View {
        if let url = model.webURL(kind) {
            Button { openURL(url) } label: { Label(LocalizedStringKey(title), systemImage: "arrow.up.right.square") }
                .font(.subheadline.weight(.medium)).foregroundStyle(DKTheme.accent)
        }
    }
}

struct DKProtectionNotice: View {
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(DKTheme.amber)
            VStack(alignment: .leading, spacing: 5) {
                Text("迁移保护已开启").font(.subheadline.weight(.semibold))
                if !compact {
                    Text("受保护的下载器仅查看。校验与交接期间，启动、停止和限速调整均保持锁定。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(DKTheme.amber.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DKScreenBackground: ViewModifier {
    @Environment(\.dkPageCharacter) private var character
    func body(content: Content) -> some View {
        content.background { DKCharacterBackdrop(character: character) }
            .toolbarBackground(DKTheme.background, for: .navigationBar)
    }
}

extension View {
    func dkScreen() -> some View { modifier(DKScreenBackground()) }
}
