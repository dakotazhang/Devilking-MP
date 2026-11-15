import SwiftUI

struct MPDiscoveryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: MPDiscoveryItem
    @State private var detail: MPDiscoveryDetail?
    @State private var loading = true
    @State private var loadError: String?
    @State private var selectedSeason: Int?
    @State private var confirmingRequest: MPSubscriptionRequest?
    @State private var submitting = false
    @State private var attemptedKeys = Set<String>()
    @State private var submittedKeys = Set<String>()
    @State private var showingResources = false

    private var current: MPDiscoveryItem { detail?.item ?? item }
    private var request: MPSubscriptionRequest { MPSubscriptionRequest(item: current, season: current.isTV ? selectedSeason : nil) }
    private var alreadySubscribed: Bool { model.hasSubscription(current, season: current.isTV ? selectedSeason : nil) }
    private var hasAttempt: Bool { attemptedKeys.contains(request.identityKey) }
    private var canSubmit: Bool {
        detail != nil && request.isValid && model.canManage(.moviepilot) && !submitting && !hasAttempt && !alreadySubscribed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("影视详情").font(.headline)
                        Spacer()
                        Button("完成") { dismiss() }.disabled(submitting).accessibilityIdentifier("media.detail.done")
                    }
                    HStack(alignment: .top, spacing: 20) {
                        DKPoster(url: current.poster, width: 116, height: 174)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(current.title).font(.title2.weight(.bold)).textSelection(.enabled).accessibilityIdentifier("media.detail.title")
                            Text(current.metadataLine).font(.subheadline).foregroundStyle(DKTheme.muted)
                            if let rating = current.rating {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.headline).foregroundStyle(DKTheme.amber)
                            }
                            if !current.genres.isEmpty {
                                Text(current.genres.joined(separator: " · ")).font(.caption).foregroundStyle(DKTheme.muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if loading {
                        ProgressView("正在读取作品详情").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    if let loadError {
                        DKCard {
                            Text(loadError).font(.subheadline).foregroundStyle(DKTheme.amber)
                            Button("重新读取详情") { Task { await loadDetail() } }.disabled(loading || submitting)
                        }
                    }
                    DKCard {
                        DKSectionTitle(title: "内容简介")
                        Text(current.overview.isEmpty ? "暂无简介" : current.overview)
                            .font(.subheadline).foregroundStyle(DKTheme.muted).lineSpacing(5).textSelection(.enabled)
                    }
                    if current.isTV { seasonSelection }
                    subscriptionAction
                    resourceAction
                }.padding(20)
            }
            .navigationBarHidden(true)
            .task(id: item.id) { await loadDetail() }
            .sheet(isPresented: $showingResources) {
                NavigationStack {
                    MPResourceSearchView(media: current, season: selectedSeason)
                        .navigationTitle("站点资源")
                        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showingResources = false } } }
                        .dkScreen()
                }
            }
            .interactiveDismissDisabled(submitting)
            .onChange(of: model.interactionEpoch) { _ in confirmingRequest = nil }
            .alert("确认新增订阅？", isPresented: Binding(get: { confirmingRequest != nil }, set: { if !$0 { confirmingRequest = nil } }), presenting: confirmingRequest) { confirmed in
                Button("取消", role: .cancel) {}
                Button("确认订阅") { Task { await submit(confirmed) } }
            } message: { confirmed in
                Text("\(confirmed.item.title)\n\(confirmed.item.metadataLine)\(confirmed.item.isTV ? " · " + seasonTitle(confirmed.season) : "")\nMoviePilot 将按现有订阅规则自动搜索并下载匹配资源。只提交这一条订阅。")
            }
            .dkScreen()
        }.tint(DKTheme.accent)
    }

    private var seasonSelection: some View {
        DKCard {
            DKSectionTitle(title: "选择要追订的季", subtitle: "每次只订阅明确选中的一季。")
            if let detail, !detail.seasons.isEmpty {
                Picker("剧集季", selection: $selectedSeason) {
                    Text("请选择一季").tag(Optional<Int>.none)
                    ForEach(detail.seasons) { season in
                        Text(season.title + (model.hasSubscription(current, season: season.number) ? " · 已订阅" : ""))
                            .tag(Optional(season.number))
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("media.seasonPicker")
                if let number = selectedSeason, let selected = detail.seasons.first(where: { $0.number == number }), let episodes = selected.episodeCount {
                    Text("\(selected.title) · \(episodes) 集").font(.caption).foregroundStyle(DKTheme.muted).accessibilityIdentifier("media.selectedSeason")
                }
            } else if !loading {
                Text("暂未获得可选季，不能在这里新增剧集订阅。请在 MoviePilot 中核对。")
                    .font(.caption).foregroundStyle(DKTheme.amber)
            }
        }
    }

    private var subscriptionAction: some View {
        DKCard {
            if alreadySubscribed || submittedKeys.contains(request.identityKey) {
                Label("已订阅", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(DKTheme.green)
                Text("可在“订阅”页查看追订进度，无需重复添加。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
            } else if hasAttempt {
                Label("请先核对订阅结果", systemImage: "clock.badge.exclamationmark").foregroundStyle(DKTheme.amber)
                Text("请查看操作提示，刷新订阅列表或在 MoviePilot 核对。此页面不会重复提交本次操作。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
            } else {
                Button { confirmingRequest = request } label: {
                    HStack {
                        if submitting { ProgressView() }
                        Label(submitting ? "正在提交" : "按默认规则订阅", systemImage: "bookmark.badge.plus")
                    }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).disabled(!canSubmit).accessibilityIdentifier("media.subscribe")
                Text("沿用 MoviePilot 电脑端的订阅规则，由它自动挑选匹配资源。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
                if !model.canManage(.moviepilot) {
                    Label("当前仅查看。请在设置中启用 MoviePilot 操作权限后再订阅。", systemImage: "lock")
                        .font(.caption).foregroundStyle(DKTheme.amber).accessibilityIdentifier("media.detail.readonly")
                } else if !current.hasSubscribableIdentity {
                    Text("作品标识或类型不完整，暂不能创建订阅。")
                        .font(.caption).foregroundStyle(DKTheme.amber)
                } else if current.isTV && selectedSeason == nil {
                    Text("请先选择要追订的一季。") .font(.caption).foregroundStyle(DKTheme.muted)
                }
            }
            DKServiceLink(kind: .moviepilot, title: "打开 MoviePilot")
        }
    }

    private var resourceAction: some View {
        DKCard {
            DKSectionTitle(title: "自己挑选具体资源", subtitle: "选择已连接的 PT 站点，查看种子后再决定下载。")
            Button { showingResources = true } label: {
                Label("搜索站点资源", systemImage: "magnifyingglass").frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.bordered)
                .disabled(loading || submitting || (current.isTV && selectedSeason == nil))
                .accessibilityIdentifier("media.searchResources")
            if current.isTV && selectedSeason == nil {
                Text("请先选择要查找的剧集季。") .font(.caption).foregroundStyle(DKTheme.muted)
            }
        }
    }

    private func loadDetail() async {
        guard !submitting else { return }
        loading = true
        defer { loading = false }
        loadError = nil
        do {
            let result = try await model.loadMediaDetail(item)
            guard !Task.isCancelled else { return }
            guard !model.locked else {
                loadError = "应用已锁定，解锁后可重新读取详情。"
                return
            }
            detail = result
            if !result.seasons.contains(where: { $0.number == selectedSeason }) { selectedSeason = nil }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = AppModel.safeError(error)
        }
    }

    private func seasonTitle(_ number: Int?) -> String {
        guard let number else { return "未选择剧集季" }
        return detail?.seasons.first(where: { $0.number == number })?.title ?? (number == 0 ? "特别篇" : "第 \(number) 季")
    }

    private func submit(_ confirmed: MPSubscriptionRequest) async {
        guard !submitting, confirmed.isValid, model.canManage(.moviepilot),
              !attemptedKeys.contains(confirmed.identityKey), !model.hasSubscription(confirmed.item, season: confirmed.season) else { return }
        submitting = true
        attemptedKeys.insert(confirmed.identityKey)
        let accepted = await model.createSubscription(confirmed)
        if accepted { submittedKeys.insert(confirmed.identityKey) }
        submitting = false
    }
}
