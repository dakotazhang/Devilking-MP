import SwiftUI
import UIKit

enum DKTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.10)
    static let card = Color(red: 0.075, green: 0.105, blue: 0.17)
    static let accent = Color(red: 0.48, green: 0.79, blue: 1.0)
    static let muted = Color(red: 0.57, green: 0.65, blue: 0.77)
    static let green = Color(red: 0.43, green: 0.85, blue: 0.69)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.38)
}

extension ServiceKind {
    var compactTitle: String {
        switch self {
        case .qb1: return "家庭 qB1"
        case .qb2: return "家庭 qB2"
        case .tr: return "长期保种 TR"
        case .moviepilot: return "MoviePilot"
        case .emby: return "Emby"
        }
    }
}

struct DKCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DKTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.055), lineWidth: 1))
    }
}

struct DKSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.white)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(DKTheme.muted) }
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
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(DKTheme.muted).multilineTextAlignment(.center)
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
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
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
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(DKTheme.muted)
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
            Text(title).font(.subheadline).foregroundStyle(DKTheme.muted)
            Spacer(minLength: 0)
            Text(value.isEmpty ? "—" : value).font(.subheadline).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct DKPoster: View {
    @EnvironmentObject private var model: AppModel
    let url: String?
    var width: CGFloat = 64
    var height: CGFloat = 92
    @State private var authenticatedImage: UIImage?

    var body: some View {
        content
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            .task(id: loadKey) { await loadAuthenticatedPoster() }
    }

    @ViewBuilder private var content: some View {
        if url?.hasPrefix("dkemby:") == true {
            if let authenticatedImage {
                Image(uiImage: authenticatedImage).resizable().scaledToFill()
            } else {
                placeholder
            }
        } else {
            publicPoster
        }
    }

    private var publicPoster: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [DKTheme.accent.opacity(0.18), DKTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film").font(.title2).foregroundStyle(DKTheme.accent.opacity(0.65))
        }
    }

    private var loadKey: String {
        "\(url ?? "")|\(model.locked)|\(model.profile(.emby).baseURL)"
    }

    private func loadAuthenticatedPoster() async {
        authenticatedImage = nil
        guard !model.locked, let url, url.hasPrefix("dkemby:") else { return }
        let id = String(url.dropFirst("dkemby:".count))
        guard !id.isEmpty, let data = await model.loadPoster(id), !Task.isCancelled, !model.locked else { return }
        authenticatedImage = UIImage(data: data)
    }
}

struct DKServiceLink: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let kind: ServiceKind
    var title: String = "打开原管理页面"
    var body: some View {
        if let url = model.webURL(kind) {
            Button { openURL(url) } label: { Label(title, systemImage: "arrow.up.right.square") }
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
                    Text("家庭 qB1 和 TR 仅查看。校验与交接期间，启动、停止和限速调整均保持锁定。")
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
    func body(content: Content) -> some View {
        content.background(DKTheme.background).toolbarBackground(DKTheme.background, for: .navigationBar)
    }
}

extension View {
    func dkScreen() -> some View { modifier(DKScreenBackground()) }
}
