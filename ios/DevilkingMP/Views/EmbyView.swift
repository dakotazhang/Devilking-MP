import SwiftUI

struct EmbyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selectedMedia: MediaItem?
    private let columns = [GridItem(.adaptive(minimum: 135), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    if !model.isConfigured(.emby) {
                        DKCard { DKEmptyState(symbol: "play.rectangle", title: "让家庭片库随身可见", detail: "先在设置中登录 Emby。这里会显示真实片库、观看状态与当前播放会话。") }
                    } else {
                        header
                        if !model.sessions.isEmpty { sessions }
                        DKSectionTitle(title: query.isEmpty ? "家庭片库" : "搜索结果", subtitle: query.isEmpty ? "最近媒体 · 点击海报查看详情" : "\(model.library.count) 个匹配结果")
                        if model.library.isEmpty {
                            DKCard { DKEmptyState(symbol: "film.stack", title: model.busy ? "正在读取片库" : "暂无媒体数据", detail: "下拉刷新，或调整搜索关键词。连接错误会显示在服务状态中。") }
                        } else {
                            LazyVGrid(columns: columns, alignment: .center, spacing: 22) {
                                ForEach(model.library) { item in
                                    Button { selectedMedia = item } label: { posterCell(item) }.buttonStyle(.plain)
                                }
                            }
                        }
                        DKServiceLink(kind: .emby, title: "打开 Emby 完整片库").padding(.vertical, 8)
                    }
                }.padding(18)
            }
            .searchable(text: $query, prompt: "搜索家庭片库")
            .onSubmit(of: .search) { Task { await reload() } }
            .onChange(of: query) { if $0.isEmpty { Task { await reload() } } }
            .navigationTitle("Emby 片库")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await reload() } } label: {
                        if model.busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }.disabled(model.busy || !model.isConfigured(.emby)).accessibilityLabel("刷新 Emby")
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
            .sheet(item: $selectedMedia) { item in MediaPreviewView(item: item, service: .emby) }
            .dkScreen()
        }
    }

    private var header: some View {
        DKCard {
            HStack {
                Label("家的放映室", systemImage: "play.rectangle.fill").font(.headline)
                Spacer()
                if let snapshot = model.snapshots[.emby] {
                    DKStatus(text: snapshot.online ? "已连接" : "连接异常", color: snapshot.online ? DKTheme.green : DKTheme.amber)
                }
            }
            if let snapshot = model.snapshots[.emby] {
                Text(snapshot.error ?? snapshot.detail).font(.caption).foregroundStyle(snapshot.error == nil ? DKTheme.muted : DKTheme.amber)
            }
            if model.snapshots[.emby]?.online != true {
                Text("等待读取播放状态").font(.subheadline).foregroundStyle(DKTheme.muted)
            } else if model.sessions.isEmpty {
                Text("当前没有播放会话").font(.subheadline).foregroundStyle(DKTheme.muted)
            } else {
                Text("\(model.sessions.count) 个播放会话").font(.subheadline).foregroundStyle(DKTheme.green)
            }
        }
    }

    private var sessions: some View {
        VStack(spacing: 12) {
            DKSectionTitle(title: "正在播放")
            ForEach(model.sessions) { session in
                DKCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: session.paused ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title).foregroundStyle(DKTheme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.title).font(.headline).lineLimit(2)
                            Text("\(session.user) · \(session.device)").font(.caption).foregroundStyle(DKTheme.muted)
                        }
                        Spacer(minLength: 0)
                        DKStatus(text: session.paused ? "暂停" : "播放中", color: session.paused ? DKTheme.amber : DKTheme.green)
                    }
                    if session.duration > 0 {
                        ProgressView(value: min(1, max(0, session.position / session.duration))).tint(DKTheme.accent)
                        HStack {
                            Text(duration(session.position))
                            Spacer()
                            Text(duration(session.duration))
                        }.font(.caption2).foregroundStyle(DKTheme.muted).monospacedDigit()
                    }
                }
            }
        }
    }

    private func posterCell(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DKPoster(url: item.poster, width: 135, height: 198)
                HStack(spacing: 5) {
                    if item.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    if item.played { Image(systemName: "checkmark.circle.fill").foregroundStyle(DKTheme.green) }
                }
                .font(.caption).padding(7).background(.black.opacity(0.6), in: Capsule()).padding(7)
                .opacity(item.favorite || item.played ? 1 : 0)
            }
            Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                .frame(height: 40, alignment: .topLeading)
            Text(item.detail).font(.caption2).foregroundStyle(DKTheme.muted).lineLimit(1)
        }.frame(width: 135, alignment: .leading)
    }

    private func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds, 3_600_000))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func reload() async {
        guard model.isConfigured(.emby) else { return }
        await model.loadEmby(query)
    }
}
