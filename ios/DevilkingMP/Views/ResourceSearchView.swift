import SwiftUI

/// Station searches are deliberately user initiated. Loading this screen reads
/// connection metadata only; changing query, season or station never searches.
struct MPResourceSearchView: View {
    @EnvironmentObject private var model: AppModel
    let media: MPDiscoveryItem?
    let season: Int?
    @State private var query: String
    @State private var sites: [MPResourceSite] = []
    @State private var downloaders: [MPResourceDownloader] = []
    @State private var directories: [MPResourceDirectory] = []
    @State private var selectedSites = Set<String>()
    @State private var results: [MPResourceItem] = []
    @State private var selectedResource: MPResourceItem?
    @State private var loadingConfiguration = false
    @State private var searching = false
    @State private var configurationError: String?
    @State private var searchError: String?
    @State private var submittedQuery: String?
    @State private var sitesExpanded = true
    @State private var searchTask: Task<Void, Never>?
    @State private var searchCycle: UUID?
    @State private var configurationEpoch: UUID?
    @State private var configurationReloadID = UUID()
    @FocusState private var editingQuery: Bool

    init(media: MPDiscoveryItem? = nil, season: Int? = nil) {
        self.media = media
        self.season = season
        _query = State(initialValue: media?.title ?? "")
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedSites.isEmpty && !searching && !model.locked && model.isConfigured(.moviepilot)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !model.isConfigured(.moviepilot) {
                        DKCard { DKEmptyState(symbol: "network", title: "连接 MoviePilot", detail: "在设置中连接 MoviePilot 后，可选择它已配置的 PT 站点搜索。") }
                    } else {
                        searchForm
                        siteSelection
                        if let configurationError {
                            DKCard {
                                Label("部分连接配置未读到", systemImage: "exclamationmark.triangle").foregroundStyle(DKTheme.amber)
                                Text(configurationError).font(.caption).foregroundStyle(DKTheme.muted)
                                Button("重新读取配置") { Task { await loadConfiguration() } }.disabled(loadingConfiguration)
                            }
                        }
                        searchResults
                    }
                }.padding(18).frame(minHeight: geometry.size.height + 1, alignment: .top)
            }
            .refreshable { await loadConfiguration() }
            .task(id: configurationReloadID) { await loadConfiguration() }
            .onDisappear { searchTask?.cancel() }
            .onChange(of: model.resourceConnectionEpoch) { _ in resetForConnectionChange() }
            .sheet(item: $selectedResource) { resource in
                MPResourceDownloadView(item: resource, downloaders: downloaders, directories: directories)
            }
        }
    }

    private var searchForm: some View {
        DKCard {
            DKSectionTitle(title: "搜索 PT 站点资源", subtitle: "手动选择站点后搜索；查看结果不会新增下载任务。")
            if let media {
                Text(media.title + (season.map { " · 第 \($0) 季" } ?? ""))
                    .font(.subheadline.weight(.medium)).foregroundStyle(DKTheme.text)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(DKTheme.muted)
                TextField("片名、原名或资源关键词", text: $query)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .submitLabel(.search).focused($editingQuery)
                    .onSubmit { beginSearch() }.accessibilityIdentifier("resources.query")
            }.padding(12).background(DKTheme.background, in: RoundedRectangle(cornerRadius: 12))
            Button { beginSearch() } label: {
                HStack {
                    if searching { ProgressView() }
                    Label(searching ? "正在搜索所选站点" : "搜索所选站点", systemImage: "network")
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(!canSearch).accessibilityIdentifier("resources.search")
            if searching {
                Button("取消本次搜索") { searchTask?.cancel() }.font(.caption).accessibilityIdentifier("resources.cancelSearch")
            }
            Text("资源搜索会访问所选站点；不会随输入或刷新频率自动执行。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var siteSelection: some View {
        DKCard {
            DisclosureGroup(isExpanded: $sitesExpanded) {
                if loadingConfiguration && sites.isEmpty {
                    ProgressView("正在读取已连接站点").padding(.vertical, 12)
                } else if sites.isEmpty {
                    Text("没有可搜索的已启用站点，请在 MoviePilot 中检查站点配置。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(sites) { site in
                            Button {
                                if selectedSites.contains(site.id) { selectedSites.remove(site.id) }
                                else { selectedSites.insert(site.id) }
                            } label: {
                                Label(site.name, systemImage: selectedSites.contains(site.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8).foregroundStyle(selectedSites.contains(site.id) ? DKTheme.accent : DKTheme.text)
                            }.buttonStyle(.plain).disabled(searching)
                                .accessibilityIdentifier("resources.site." + site.id)
                                .accessibilityAddTraits(selectedSites.contains(site.id) ? .isSelected : [])
                        }
                    }.padding(.top, 10)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择 PT 站点").font(.headline)
                    Text(selectedSites.isEmpty ? "尚未选择，不会发起搜索" : "已选 \(selectedSites.count) 个站点")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }
            }.accessibilityIdentifier("resources.sites")
        }
    }

    @ViewBuilder private var searchResults: some View {
        if let searchError {
            DKCard {
                Label("本次搜索未完成", systemImage: "wifi.exclamationmark").foregroundStyle(DKTheme.amber)
                Text(searchError).font(.caption).foregroundStyle(DKTheme.muted)
            }
        }
        if let submittedQuery {
            DKSectionTitle(title: "站点资源结果", subtitle: "“\(submittedQuery)” · \(results.count) 份资源")
            if results.isEmpty && !searching && searchError == nil {
                DKCard { DKEmptyState(symbol: "doc.text.magnifyingglass", title: "没有匹配的种子", detail: "尝试其他片名或站点。此结果只代表本次所选站点的搜索。") }
            }
            ForEach(results) { resource in
                Button { selectedResource = resource } label: { MPResourceRow(item: resource) }
                    .buttonStyle(.plain).accessibilityIdentifier("resources.result." + resource.id)
            }
        } else {
            DKCard { DKEmptyState(symbol: "checklist", title: "先选站点，再搜索", detail: "影视资料用于订阅，PT 资源用于挑选具体种子，两种操作互不替代。") }
        }
    }

    private func loadConfiguration() async {
        guard !loadingConfiguration, !model.locked, model.isConfigured(.moviepilot) else { return }
        let epoch = model.resourceConnectionEpoch
        configurationEpoch = epoch
        loadingConfiguration = true
        defer { if configurationEpoch == epoch { loadingConfiguration = false } }
        var errors: [String] = []
        do {
            let loaded = try await model.resourceSites()
            guard !Task.isCancelled, model.resourceConnectionEpoch == epoch else { return }
            sites = loaded
            selectedSites.formIntersection(Set(loaded.map(\.id)))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), model.resourceConnectionEpoch == epoch else { return }
            errors.append(AppModel.safeError(error))
        }
        do {
            let loaded = try await model.resourceDownloaders()
            guard !Task.isCancelled, model.resourceConnectionEpoch == epoch else { return }
            downloaders = loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), model.resourceConnectionEpoch == epoch else { return }
            errors.append(AppModel.safeError(error))
        }
        do {
            let loaded = try await model.resourceDirectories()
            guard !Task.isCancelled, model.resourceConnectionEpoch == epoch else { return }
            directories = loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), model.resourceConnectionEpoch == epoch else { return }
            errors.append(AppModel.safeError(error))
        }
        guard !Task.isCancelled, model.resourceConnectionEpoch == epoch else { return }
        configurationError = errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: "\n")
    }

    private func resetForConnectionChange() {
        searchTask?.cancel()
        searchCycle = nil
        searching = false
        selectedResource = nil
        results = []
        submittedQuery = nil
        searchError = nil
        sites = []
        selectedSites = []
        downloaders = []
        directories = []
        configurationError = nil
        configurationEpoch = nil
        loadingConfiguration = false
        sitesExpanded = true
        configurationReloadID = UUID()
    }

    private func beginSearch() {
        editingQuery = false
        guard canSearch else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenSites = selectedSites.sorted()
        searching = true
        searchError = nil
        results = []
        submittedQuery = term
        sitesExpanded = false
        let cycle = UUID()
        searchCycle = cycle
        searchTask = Task {
            defer { if searchCycle == cycle { searching = false } }
            do {
                let rows = try await model.searchResources(query: term, sites: chosenSites, media: media, season: season)
                guard !Task.isCancelled, !model.locked, searchCycle == cycle else { return }
                results = rows
            } catch {
                guard !Task.isCancelled, searchCycle == cycle else { return }
                searchError = AppModel.safeError(error)
            }
        }
    }
}

private struct MPResourceRow: View {
    let item: MPResourceItem
    var body: some View {
        DKCard {
            HStack(alignment: .top) {
                Text(item.title).font(.headline).foregroundStyle(DKTheme.text).lineLimit(3)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(DKTheme.muted)
            }
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(DKTheme.muted).lineLimit(3) }
            HStack(spacing: 12) {
                Label(item.siteName, systemImage: "globe")
                Text(item.size.map { Format.bytes($0) } ?? "体积未知")
            }.font(.caption).foregroundStyle(DKTheme.muted)
            HStack(spacing: 12) {
                Label(item.seeders.map { String($0) } ?? "未知", systemImage: "arrow.up.circle")
                Label(item.peers.map { String($0) } ?? "未知", systemImage: "arrow.down.circle")
                Text(resourcePromotion(item))
                Text(resourceHR(item))
            }.font(.caption).foregroundStyle(DKTheme.muted)
            if let until = item.freeUntil, !until.isEmpty {
                Text("促销期限：\(until)").font(.caption).foregroundStyle(DKTheme.amber)
            }
        }
    }
}

private struct MPResourceDownloadView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    let item: MPResourceItem
    let downloaders: [MPResourceDownloader]
    let directories: [MPResourceDirectory]
    @State private var downloaderID = ""
    @State private var directoryID = ""
    @State private var confirming = false
    @State private var submitting = false
    @State private var attempted = false
    @State private var accepted = false
    @State private var resultFeedback: String?

    private var downloader: MPResourceDownloader? { downloaders.first { $0.id == downloaderID } }
    private var directory: MPResourceDirectory? { directories.first { $0.id == directoryID } }
    private var boundKind: ServiceKind? {
        downloader.flatMap { preferences.boundDownloaderKind(for: $0.bindingID, baseURL: model.profile(.moviepilot).baseURL) }
    }
    private var permitted: Bool { downloader.map { model.canDownloadResource($0) } ?? false }
    private var canSubmit: Bool { item.canDownload && model.isCurrentResource(item) && permitted && !submitting && !attempted }
    private var directoryTitle: String { directory.map { $0.name.isEmpty ? $0.savePath : $0.name } ?? "沿用 MoviePilot 默认目录" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MPResourceRow(item: item)
                    DKCard {
                        DKSectionTitle(title: "本次下载位置", subtitle: "新增任务由 MoviePilot 发送；不会修改服务器默认设置。")
                        Picker("下载器", selection: $downloaderID) {
                            Text("请选择下载器").tag("")
                            ForEach(downloaders) { value in Text(value.name).tag(value.id) }
                        }.accessibilityIdentifier("resources.downloader")
                        if downloader != nil {
                            Text(boundKind.map { preferences.text("对应应用连接：") + model.profile($0).displayName } ?? "未绑定：请先在设置确认下载器身份。")
                                .font(.caption).foregroundStyle(boundKind == nil ? DKTheme.amber : DKTheme.muted)
                                .accessibilityIdentifier("resources.binding")
                        }
                        Picker("下载目录", selection: $directoryID) {
                            Text("沿用 MoviePilot 默认目录").tag("")
                            ForEach(directories) { value in
                                Text(value.name.isEmpty ? value.savePath : value.name).tag(value.id)
                            }
                        }.accessibilityIdentifier("resources.directory")
                        if let directory {
                            Text(directory.savePath).font(.caption).foregroundStyle(DKTheme.muted).textSelection(.enabled)
                        }
                        if downloaders.isEmpty {
                            Text("未读到可用下载器，请返回刷新连接配置后再选。")
                                .font(.caption).foregroundStyle(DKTheme.amber)
                        }
                    }
                    DKCard {
                        if accepted {
                            Label("下载请求已提交", systemImage: "checkmark.circle.fill").foregroundStyle(DKTheme.green)
                            Text("请在下载器或 MoviePilot 中核对任务；此页面不会重复提交。")
                                .font(.caption).foregroundStyle(DKTheme.muted)
                        } else if submitting {
                            ProgressView("正在提交一次下载请求")
                            Text("请等待结果，勿在其他页面重复添加。")
                                .font(.caption).foregroundStyle(DKTheme.muted)
                        } else if attempted {
                            Label("请核对下载结果", systemImage: "clock.badge.exclamationmark").foregroundStyle(DKTheme.amber)
                            Text("本次操作已尝试一次。即使回读未完成，也请先到原管理页核对。")
                                .font(.caption).foregroundStyle(DKTheme.muted)
                            if let resultFeedback { Text(resultFeedback).font(.caption).foregroundStyle(DKTheme.amber) }
                        } else {
                            Button { confirming = true } label: {
                                HStack {
                                    if submitting { ProgressView() }
                                    Label("新增下载任务", systemImage: "arrow.down.circle")
                                }.frame(maxWidth: .infinity).padding(.vertical, 5)
                            }.buttonStyle(.borderedProminent).disabled(!canSubmit).accessibilityIdentifier("resources.download")
                            if !model.canManage(.moviepilot) {
                                Label("仅查看：请在设置中启用操作权限后再下载。", systemImage: "lock")
                                    .font(.caption).foregroundStyle(DKTheme.amber).accessibilityIdentifier("resources.readonly")
                            } else if downloader == nil {
                                Text("请明确选择本次使用的下载器。") .font(.caption).foregroundStyle(DKTheme.muted)
                            } else if !permitted {
                                Label("此下载器受迁移保护或尚未匹配可管理的连接。", systemImage: "lock")
                                    .font(.caption).foregroundStyle(DKTheme.amber)
                            } else if !model.isCurrentResource(item) {
                                Text("连接已变化，请返回重新搜索这份资源。")
                                    .font(.caption).foregroundStyle(DKTheme.amber)
                            } else if !item.canDownload {
                                Text("这份资源缺少可用下载信息，请在 MoviePilot 原页面核对。")
                                    .font(.caption).foregroundStyle(DKTheme.amber)
                            }
                            Text("免费和 HR 以站点实时规则为准；未知状态不会按免费或免 HR 处理。")
                                .font(.caption).foregroundStyle(DKTheme.muted)
                        }
                    }
                }.padding(18)
            }
            .navigationTitle("资源详情")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() }.disabled(submitting) }
            }
            .task {
                let id = preferences.preferredDownloadDirectoryID(for: model.profile(.moviepilot).baseURL)
                directoryID = directories.contains(where: { $0.id == id }) ? (id ?? "") : ""
            }
            .interactiveDismissDisabled(submitting)
            .onChange(of: model.interactionEpoch) { _ in confirming = false }
            .onChange(of: boundKind) { _ in confirming = false }
            .onChange(of: model.resourceConnectionEpoch) { _ in
                confirming = false
                if !submitting { dismiss() }
            }
            .alert("确认新增下载任务？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("确认下载") { Task { await submit() } }
            } message: {
                Text("\(item.title)\n站点：\(item.siteName)\n下载器：\(downloader?.name ?? "未选择")\n应用连接：\(boundKind.map { model.profile($0).displayName } ?? preferences.text("未绑定"))\n目录：\(directoryTitle)\n将实际新增一个下载任务，并可能产生站点下载量。")
            }
            .dkScreen()
        }
    }

    private func submit() async {
        guard canSubmit, let downloader else { return }
        submitting = true
        attempted = true
        accepted = await model.downloadResource(MPResourceDownloadRequest(item: item, downloader: downloader, directory: directory))
        resultFeedback = model.message
        submitting = false
    }
}

private func resourcePromotion(_ item: MPResourceItem) -> String {
    guard let factor = item.downloadFactor else { return "促销未知" }
    let download = factor == 0 ? "免费" : (factor == 1 ? "正常下载量" : "下载量 ×" + String(format: "%g", factor))
    guard let upload = item.uploadFactor, upload != 1 else { return download }
    return download + " · 上传 ×" + String(format: "%g", upload)
}

private func resourceHR(_ item: MPResourceItem) -> String {
    guard let hasHR = item.hasHR else { return "HR 未知" }
    return hasHR ? "有 HR" : "无 HR"
}
