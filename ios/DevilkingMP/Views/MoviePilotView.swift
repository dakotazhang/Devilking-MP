import SwiftUI

struct MediaListRow: View {
    let item: MediaItem
    var body: some View {
        DKCard {
            HStack(spacing: 14) {
                DKPoster(url: item.poster, width: 55, height: 80)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title).font(.headline).foregroundStyle(.white).lineLimit(2)
                    Text(item.detail).font(.caption).foregroundStyle(DKTheme.muted).lineLimit(2)
                    if !item.kind.isEmpty { Text(item.kind).font(.caption2).foregroundStyle(DKTheme.accent) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(DKTheme.muted)
            }
        }
    }
}

struct MediaPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let service: ServiceKind
    @State private var confirmingFavorite = false
    @State private var confirmingPlayed = false
    private var current: MediaItem { service == .emby ? model.library.first(where: { $0.id == item.id }) ?? item : item }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    DKPoster(url: current.poster, width: 150, height: 224).shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                    Text(current.title).font(.title2.weight(.bold)).multilineTextAlignment(.center).textSelection(.enabled)
                    Text(current.detail).font(.subheadline).foregroundStyle(DKTheme.muted).multilineTextAlignment(.center)
                    if !current.overview.isEmpty {
                        DKCard {
                            DKSectionTitle(title: "内容简介")
                            Text(current.overview).font(.subheadline).lineSpacing(5).foregroundStyle(DKTheme.muted).textSelection(.enabled)
                        }
                    }
                    if service == .emby { embyActions }
                    DKCard {
                        DKServiceLink(kind: service, title: service == .emby ? "打开 Emby 查看与播放" : "打开 MoviePilot 搜索资源")
                        Text(service == .emby ? "影片播放与会话控制继续使用 Emby 原页面或官方客户端。" : "资源选择、订阅和下载在现有 MoviePilot 中完成。")
                            .font(.caption).foregroundStyle(DKTheme.muted)
                    }
                }.padding(20)
            }
            .navigationTitle("媒体详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert(current.favorite ? "取消收藏这部影片？" : "收藏这部影片？", isPresented: $confirmingFavorite) {
                Button("取消", role: .cancel) {}
                Button("确认") { Task { await model.setFavorite(current, value: !current.favorite) } }
            } message: { Text("仅修改当前 Emby 用户的收藏状态。") }
            .alert(current.played ? "标记为未看？" : "标记为已看？", isPresented: $confirmingPlayed) {
                Button("取消", role: .cancel) {}
                Button("确认") { Task { await model.setPlayed(current, value: !current.played) } }
            } message: { Text("仅修改当前 Emby 用户的观看状态，不会删除文件。") }
            .dkScreen()
        }.tint(DKTheme.accent).preferredColorScheme(.dark)
    }

    private var embyActions: some View {
        DKCard {
            HStack(spacing: 14) {
                Button { confirmingFavorite = true } label: {
                    Label(current.favorite ? "已收藏" : "收藏", systemImage: current.favorite ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.bordered)
                Button { confirmingPlayed = true } label: {
                    Label(current.played ? "已看" : "标记已看", systemImage: current.played ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.bordered)
            }.disabled(!model.canManage(.emby) || model.busy)
            if !model.canManage(.emby) {
                Label("如需修改，请先在设置启用 Emby 操作权限。", systemImage: "lock")
                    .font(.caption).foregroundStyle(DKTheme.muted)
            }
        }
    }
}
