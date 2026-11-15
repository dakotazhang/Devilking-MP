import SwiftUI

struct MoviePilotView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var category = MPBrowseCategory.all
    @State private var selectedMedia: MPDiscoveryItem?
    @State private var searchMode = MPDiscoverySearchMode.media

    private var searching: Bool { !submittedQuery.isEmpty }
    private var filteredResults: [MPDiscoveryItem] { model.discoveryResults.filter { category.includes($0) } }
    private var visibleSections: [MPDiscoverySection] {
        model.discoverySections.filter { category == .all || $0.category == category || $0.items.contains(where: { category.includes($0) }) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("搜索范围", selection: $searchMode) {
                    Text("影视").tag(MPDiscoverySearchMode.media)
                    Text("PT资源").tag(MPDiscoverySearchMode.resources)
                }
                .pickerStyle(.segmented).padding(.horizontal, 18).padding(.vertical, 10)
                .accessibilityIdentifier("discovery.searchMode")
                if searchMode == .resources {
                    MPResourceSearchView()
                } else {
                    mediaPage
                }
            }
            .navigationTitle("发现")
            .toolbar {
                if searchMode == .media {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            if model.discoveryLoading { model.cancelDiscoveryRefresh() }
                            else { Task { await reload() } }
                        } label: {
                            Label(model.discoveryLoading ? "取消刷新" : "刷新", systemImage: model.discoveryLoading ? "xmark.circle" : "arrow.clockwise")
                        }
                            .disabled(model.discoverySearchLoading)
                            .accessibilityIdentifier("discovery.refresh")
                    }
                }
            }
            .sheet(item: $selectedMedia) { item in MPDiscoveryDetailView(item: item) }
            .dkScreen()
        }
    }

    private var mediaPage: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    DKCharacterHeader()
                    if !model.isConfigured(.moviepilot) {
                        DKCard { DKEmptyState(symbol: "sparkles.tv", title: "连接 MoviePilot", detail: "在设置中添加家庭 MoviePilot，即可发现影视、搜索资料并订阅想看的作品。") }
                    } else {
                        introduction
                        categoryPicker
                        if let error = model.discoveryError {
                            DKCard {
                                Label("资料暂未完整更新", systemImage: "wifi.exclamationmark").font(.headline).foregroundStyle(DKTheme.amber)
                                Text(error).font(.caption).foregroundStyle(DKTheme.muted)
                                Text("已读取的内容继续保留，可下拉刷新。") .font(.caption).foregroundStyle(DKTheme.muted)
                            }
                        }
                        if searching { results } else { discovery }
                        DKServiceLink(kind: .moviepilot, title: "打开 MoviePilot 高级功能")
                            .padding(.vertical, 8)
                    }
                }.padding(18)
                    // A short or empty recommendation page must still allow a
                    // real pull-to-refresh gesture on iOS 16.1.
                    .frame(minHeight: geometry.size.height + 1, alignment: .top)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索电影、剧集和动漫")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submittedQuery = "" }
            }
            .refreshable { await reload() }
            .task { if model.discoverySections.isEmpty { await reload() } }
            .onDisappear { model.cancelDiscoveryRefresh() }
        }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(searching ? "找到想看的下一部" : "好作品，随时追订").font(.title3.weight(.bold))
                Text(searching ? "选择作品后，按默认规则订阅，或搜索站点资源。" : "发现作品后订阅；想挑选具体种子，可切换“PT资源”。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
                if let updated = model.discoveryUpdatedAt, !searching {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(DKTheme.muted)
                }
            }
            Spacer(minLength: 0)
            Label(model.canManage(.moviepilot) ? "可订阅" : "仅查看", systemImage: model.canManage(.moviepilot) ? "bookmark" : "lock")
                .font(.caption).foregroundStyle(model.canManage(.moviepilot) ? DKTheme.green : DKTheme.amber)
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MPBrowseCategory.allCases) { value in
                    Button { category = value } label: {
                        Text(value.title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .foregroundStyle(category == value ? DKTheme.background : DKTheme.muted)
                            .background(category == value ? DKTheme.accent : DKTheme.card, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
                        .accessibilityIdentifier("discovery.category." + value.rawValue)
                }
            }
        }
    }

    @ViewBuilder private var discovery: some View {
        if model.discoveryLoading && model.discoverySections.isEmpty {
            ProgressView("正在读取影视推荐").frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if visibleSections.isEmpty {
            DKCard { DKEmptyState(symbol: "film.stack", title: "暂无推荐资料", detail: "可直接搜索片名，或下拉重新读取 MoviePilot 推荐。") }
        } else {
            ForEach(visibleSections) { section in
                VStack(alignment: .leading, spacing: 14) {
                    DKSectionTitle(title: section.title, subtitle: section.subtitle.isEmpty ? nil : section.subtitle)
                    if let error = section.error {
                        DKCard {
                            Label("栏目读取失败", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.medium)).foregroundStyle(DKTheme.amber)
                            Text(error).font(.caption).foregroundStyle(DKTheme.muted)
                            Text("可下拉重新读取；仍可浏览其他已载入的栏目。")
                                .font(.caption).foregroundStyle(DKTheme.muted)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(section.items.filter { category.includes($0) }) { item in
                                Button { selectedMedia = item } label: { MPDiscoveryPosterCard(item: item) }
                                    .buttonStyle(.plain).accessibilityIdentifier("discovery.media." + item.mediaID)
                            }
                        }.padding(.vertical, 2)
                    }
                    if section.items.isEmpty && section.error == nil {
                        Text("该栏目暂无资料").font(.caption).foregroundStyle(DKTheme.muted)
                    }
                }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            DKSectionTitle(title: "搜索结果", subtitle: "“\(submittedQuery)” · 本页 \(filteredResults.count) 部")
            if model.discoverySearchLoading {
                ProgressView("正在搜索影视资料").frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if filteredResults.isEmpty {
                DKCard { DKEmptyState(symbol: "magnifyingglass", title: "没有匹配的作品", detail: "试试其他片名、原名，或切换“全部”分类。") }
            } else {
                ForEach(filteredResults) { item in
                    Button { selectedMedia = item } label: { MPDiscoverySearchRow(item: item) }.buttonStyle(.plain)
                        .accessibilityIdentifier("discovery.media." + item.mediaID)
                }
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submittedQuery = text
        Task { await model.searchDiscovery(text) }
    }

    private func reload() async {
        guard model.isConfigured(.moviepilot) else { return }
        if searching { await model.searchDiscovery(submittedQuery) } else { await model.loadDiscovery() }
    }
}

private enum MPDiscoverySearchMode: Hashable { case media, resources }

struct MPDiscoveryPosterCard: View {
    let item: MPDiscoveryItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DKPoster(url: item.poster, width: 132, height: 194)
                if let rating = item.rating {
                    Text(String(format: "%.1f", rating)).font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(.black.opacity(0.75), in: Capsule()).padding(7)
                }
            }
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(DKTheme.text).lineLimit(2)
                .frame(height: 40, alignment: .topLeading)
            Text(item.metadataLine).font(.caption2).foregroundStyle(DKTheme.muted).lineLimit(1)
        }.frame(width: 132, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct MPDiscoverySearchRow: View {
    let item: MPDiscoveryItem
    var body: some View {
        DKCard {
            HStack(alignment: .top, spacing: 14) {
                DKPoster(url: item.poster, width: 76, height: 112)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title).font(.headline).foregroundStyle(DKTheme.text).lineLimit(2)
                    HStack(spacing: 8) {
                        if let rating = item.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(DKTheme.amber)
                        }
                        Text(item.metadataLine).foregroundStyle(DKTheme.muted)
                    }.font(.caption)
                    Text(item.overview.isEmpty ? "暂无简介" : item.overview)
                        .font(.caption).foregroundStyle(DKTheme.muted).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(DKTheme.muted).padding(.top, 4)
            }
        }
    }
}
