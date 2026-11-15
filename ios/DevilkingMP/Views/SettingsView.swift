import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var editingService: ServiceKind?
    @State private var importing = false
    @State private var addingService = false
    @State private var confirmingMigrationUnlock = false
    @State private var importError: String?
    @State private var confirmingBiometric = false
    @State private var confirmingReadOnlyUnlock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    about
                    resources
                    appearance
                    dashboardModules
                    protection
                    privacy
                    accountHeader
                }.padding(18)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingService) { kind in ConnectionEditorView(kind: kind) }
            .sheet(isPresented: $addingService) { ConnectionEditorView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try model.importProfile(url)
                } catch { importError = AppModel.safeError(error) }
            }
            .alert("导入未完成", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("知道了", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
            .alert("关闭迁移保护？", isPresented: $confirmingMigrationUnlock) {
                Button("保持保护", role: .cancel) {}
                Button("确认迁移已结束，关闭保护", role: .destructive) { model.migrationProtection = false }
            } message: {
                Text("仅当受保护下载器的批量校验和交接已经完成，且你确认可以管理它们时再关闭。关闭后仍需分别启用服务操作权限，每次写入仍会确认。")
            }
            .alert("关闭全局只读锁？", isPresented: $confirmingReadOnlyUnlock) {
                Button("保持只读", role: .cancel) {}
                Button("确认开启管理模式") { model.readOnlyMode = false }
            } message: {
                Text("关闭后，只有已单独授权的服务才能操作。受保护的下载器仍受迁移保护限制，每次启停、限速或订阅都需要再次确认。可以随时重新开启只读锁。")
            }
            .alert("启用身份验证？", isPresented: $confirmingBiometric) {
                Button("取消", role: .cancel) {}
                Button("启用") {
                    model.biometricEnabled = true
                    model.protectOnBackground()
                    Task { await model.unlock() }
                }
            } message: { Text("离开 App 后重新进入，需要通过设备身份验证。请确保此设备已设置可用的 Face ID、Touch ID 或锁屏密码。") }
            .dkScreen()
        }
    }

    private var accountHeader: some View {
        DKCard {
            DKSectionTitle(title: "连接配置")
            Button { importing = true } label: {
                Label("从文件导入连接配置", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent)
            Text("连接文件可能包含账号信息。导入后凭据写入钥匙串，请妥善保存或删除原文件。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var connections: some View {
        VStack(spacing: 12) {
            DKSectionTitle(title: "服务连接", subtitle: "下载器可重复添加；每个实例独立保存账号、名称和权限。")
            if let error = model.configurationError {
                DKCard {
                    Label("服务器配置未读到", systemImage: "exclamationmark.triangle").foregroundStyle(DKTheme.amber)
                    Text(error).font(.caption).foregroundStyle(DKTheme.muted)
                    Text("原本机配置保留，未自动重置。请先检查连接配置，再恢复访问。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }.accessibilityIdentifier("servers.configurationError")
            }
            Button { addingService = true } label: {
                Label("添加服务器", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).frame(minHeight: 44)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("settings.addServer").disabled(model.configurationError != nil)
            if model.profiles.isEmpty {
                DKCard { DKEmptyState(symbol: "server.rack", title: "还没有服务器", detail: "添加 qBittorrent、Transmission、MoviePilot 或 Emby。名称和分组都由你决定。") }
            }
            ForEach(model.profiles) { profile in
                let kind = profile.kind
                Button { editingService = kind } label: {
                    DKCard {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).font(.title2).foregroundStyle(DKTheme.accent).frame(width: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: profile.displayName).font(.headline).foregroundStyle(DKTheme.text)
                                Text(verbatim: connectionDescription(kind)).font(.caption).foregroundStyle(DKTheme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(LocalizedStringKey(model.isConfigured(kind) ? "连接已启用" : model.hasSavedCredentials(kind) ? "已断开" : "待填写凭据")).font(.caption).foregroundStyle(model.isConfigured(kind) ? DKTheme.accent : DKTheme.muted)
                                if model.isConfigured(kind) {
                                    Text(LocalizedStringKey(model.canManage(kind) ? "可管理" : model.profile(kind).allowActions ? "权限已保存 · 当前只读" : "仅查看")).font(.caption2).foregroundStyle(DKTheme.muted)
                                }
                            }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DKTheme.muted)
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("servers.connection." + kind.rawValue)
            }
        }
    }

    private var resources: some View {
        DKCard {
            DKSectionTitle(title: "资源管理")
            NavigationLink {
                ScrollView { connections.padding(18) }
                    .navigationTitle("服务器设置").navigationBarTitleDisplayMode(.inline).dkScreen()
            } label: { Label("服务器设置", systemImage: "server.rack").frame(minHeight: 36) }
            .accessibilityIdentifier("settings.servers")
            Divider()
            NavigationLink { ServerGroupsSettingsView() } label: {
                Label("服务器分组", systemImage: "folder.badge.gearshape").frame(minHeight: 36)
            }.accessibilityIdentifier("settings.groups")
            Divider()
            NavigationLink { DownloadDirectorySettingsView() } label: {
                Label("预设下载目录", systemImage: "folder.fill").frame(minHeight: 36)
            }
            Divider()
            NavigationLink { DownloaderBindingsSettingsView() } label: {
                Label("确认下载器身份", systemImage: "checkmark.shield").frame(minHeight: 36)
            }
            Divider()
            HStack {
                Label("数据刷新频率", systemImage: "arrow.clockwise")
                Spacer(minLength: 8)
                Picker("数据刷新频率", selection: $preferences.refreshInterval) {
                    Text("关闭自动刷新").tag(0)
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                    Text("60 秒").tag(60)
                    Text("120 秒").tag(120)
                }.pickerStyle(.menu).labelsHidden()
                    .accessibilityLabel("数据刷新频率")
                    .accessibilityValue(preferences.text(preferences.refreshInterval == 0 ? "关闭自动刷新" : "\(preferences.refreshInterval) 秒"))
                    .accessibilityIdentifier("settings.refreshInterval")
            }.frame(minHeight: 44)
            Text("仅在 App 前台刷新状态表与当前下载器列表；关闭后仍可手动刷新。发现页下拉刷新，搜索结果不会被定时刷新覆盖。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var appearance: some View {
        DKCard {
            DKSectionTitle(title: "应用设置")
            Toggle(isOn: $preferences.characterBackgroundsEnabled) {
                Label("角色背景", systemImage: "photo")
            }.tint(DKTheme.accent).accessibilityIdentifier("settings.characterBackgrounds")
            Text("各页面使用不同角色背景；关闭后使用纯色背景，其他外观设置保持不变。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            HStack {
                Label("外观主题", systemImage: "paintpalette")
                Spacer(minLength: 8)
                Picker("外观主题", selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
                    .accessibilityLabel("外观主题").accessibilityValue(preferences.text(preferences.theme.title))
                    .accessibilityIdentifier("settings.theme")
            }.frame(minHeight: 44)
            HStack {
                Label("应用语言", systemImage: "globe")
                Spacer(minLength: 8)
                Picker("应用语言", selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
                    .accessibilityLabel("应用语言").accessibilityValue(preferences.language.title)
                    .accessibilityIdentifier("settings.language")
            }.frame(minHeight: 44)
            Text("界面支持简体中文与美式英语；影片名称、站点与服务返回的内容保留原文。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            HStack {
                Label("字体大小", systemImage: "textformat.size")
                Spacer(minLength: 8)
                Picker("字体大小", selection: $preferences.fontSize) {
                    ForEach(AppFontSize.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
                    .accessibilityLabel("字体大小").accessibilityValue(preferences.text(preferences.fontSize.title))
                    .accessibilityIdentifier("settings.fontSize")
            }.frame(minHeight: 44)
            Text("放大文字不会缩小系统辅助功能字体。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var dashboardModules: some View {
        DKCard {
            DKSectionTitle(title: "状态表定制", subtitle: "模块展示")
            ForEach(DashboardModule.allCases) { module in
                Toggle(LocalizedStringKey(module.title), isOn: Binding(get: { preferences.isVisible(module) }, set: { preferences.setVisible(module, $0) }))
                    .tint(DKTheme.accent).accessibilityIdentifier("settings.module.\(module.rawValue)")
            }
            Text("只改变本机状态表展示，不影响服务运行或下载任务。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var protection: some View {
        DKCard {
            DKSectionTitle(title: "迁移与操作保护")
            Toggle(isOn: Binding(get: { model.readOnlyMode }, set: { enabled in
                if enabled { model.readOnlyMode = true } else { confirmingReadOnlyUnlock = true }
            })) {
                Label("全局只读锁", systemImage: "lock.fill")
            }.tint(DKTheme.accent).accessibilityIdentifier("settings.readOnlyMode")
            Text("开启后可以浏览状态表、搜索影视和查看任务；订阅、启停与限速等写操作全部锁定。关闭需要确认，单个服务仍需另外授权。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            Divider().overlay(.white.opacity(0.05))
            Toggle(isOn: Binding(get: { model.migrationProtection }, set: { enabled in
                if enabled { model.migrationProtection = true } else { confirmingMigrationUnlock = true }
            })) {
                Label("下载器迁移保护", systemImage: "lock.shield")
            }.tint(DKTheme.accent)
            Text("保护开启时，已标记的下载器只能查看校验与任务状态，不能启停或修改上传上限。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            Divider().overlay(.white.opacity(0.05))
            Text("App 不提供删种、删除文件、移动数据、强制校验或批量重播功能。复杂操作请进入原服务管理页面核对。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var privacy: some View {
        DKCard {
            DKSectionTitle(title: "隐私与外出访问")
            Toggle(isOn: Binding(get: { model.biometricEnabled }, set: { enabled in
                if enabled { confirmingBiometric = true } else { model.biometricEnabled = false }
            })) {
                Label("进入 App 时验证身份", systemImage: "faceid")
            }.tint(DKTheme.accent)
            Text("切换到其他 App 时自动遮盖服务内容。凭据不写入 iCloud 配置或应用日志。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            Divider().overlay(.white.opacity(0.05))
            Label("按自己的网络方式连接", systemImage: "network.badge.shield.half.filled").font(.subheadline.weight(.medium))
            Text("App 直连你配置的服务器，无中转后台、统计 SDK 或广告。使用内网地址时，请先连接自己的 VPN。MP 资料与站点请求由你的服务端处理。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var about: some View {
        DKCard {
            NavigationLink { PocketRemAboutView() } label: {
                Label("关于口袋蕾姆", systemImage: "info.circle").frame(minHeight: 44)
            }.accessibilityIdentifier("settings.about")
        }
    }

    private func connectionDescription(_ kind: ServiceKind) -> String {
        guard !model.profile(kind).baseURL.isEmpty else { return kind.protocolKind.subtitle }
        guard let parts = URLComponents(string: model.profile(kind).baseURL), let host = parts.host else { return "已保存连接" }
        return parts.port.map { "\(host):\($0)" } ?? host
    }
}

private struct DownloaderBindingsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var downloaders: [MPResourceDownloader] = []
    @State private var loading = false
    @State private var loadError: String?
    private var baseURL: String { model.profile(.moviepilot).baseURL }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DKCard {
                    DKSectionTitle(title: "这一步是做什么？")
                    Text("告诉 App：MoviePilot 中的下载器，是你在“服务器设置”里添加的哪一台。确认后，才能把任务发到正确位置，并遵守这台下载器的操作保护。")
                        .font(.subheadline).foregroundStyle(DKTheme.muted)
                    Text("例如：MP 的“主力下载器”与 App 中你命名的“家中下载器”实际是同一台，就选择它。不同服务器不要互相绑定。")
                        .font(.subheadline)
                    Text("不确定时保持“暂不选择”。确认身份只保存本机设置，不会修改 MP，也不会开始下载。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }
                ForEach(downloaders) { downloader in
                    DKCard {
                        Text(downloader.name).font(.headline)
                        Text(downloader.type).font(.caption).foregroundStyle(DKTheme.muted)
                        if let endpoint = downloader.targetBaseURL {
                            Text(endpoint).font(.caption).foregroundStyle(DKTheme.muted).textSelection(.enabled)
                        }
                        HStack {
                            Label("App 中的同一台下载器", systemImage: "link")
                            Spacer(minLength: 8)
                            Picker("App 中的同一台下载器", selection: Binding<ServiceKind?>(get: {
                                preferences.boundDownloaderKind(for: downloader.bindingID, baseURL: baseURL)
                            }, set: {
                                preferences.setBoundDownloaderKind($0, for: downloader.bindingID, baseURL: baseURL)
                            })) {
                                Text("暂不选择").tag(ServiceKind?.none)
                                ForEach(availableKinds(for: downloader)) { kind in
                                    Text(verbatim: model.profile(kind).displayName).tag(Optional(kind))
                                }
                            }.pickerStyle(.menu).labelsHidden().accessibilityLabel("App 中的同一台下载器")
                        }.frame(minHeight: 44)
                        if availableKinds(for: downloader).isEmpty {
                            Text("请先配置与该类型相符的下载器连接。")
                                .font(.caption).foregroundStyle(DKTheme.amber)
                        }
                    }
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(DKTheme.amber) }
                Button { Task { await load() } } label: {
                    HStack {
                        if loading { ProgressView().controlSize(.small) }
                        Label("读取 MP 下载器", systemImage: "arrow.clockwise")
                    }
                }.buttonStyle(.bordered).disabled(loading || model.locked || !model.isConfigured(.moviepilot))
                Text("下载仍遵守全局只读锁、服务操作权限和迁移保护。重新保存 MP 或下载器连接后，需要重新确认身份。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
            }.padding(18)
        }
        .navigationTitle("确认下载器身份").navigationBarTitleDisplayMode(.inline).dkScreen()
        .task { await load() }.refreshable { await load() }
    }

    private func availableKinds(for downloader: MPResourceDownloader) -> [ServiceKind] {
        guard downloader.canBind else { return [] }
        let protocolKind: ServiceProtocol
        switch downloader.type.lowercased() {
        case "qbittorrent": protocolKind = .qbittorrent
        case "transmission": protocolKind = .transmission
        default: return []
        }
        return model.downloaderProfiles.filter { $0.protocolKind == protocolKind && model.isConfigured($0.kind) }.map(\.kind)
    }

    private func load() async {
        guard !loading, !model.locked, model.isConfigured(.moviepilot) else { return }
        loading = true; loadError = nil
        let requestedBaseURL = baseURL
        defer { loading = false }
        do {
            let result = try await model.resourceDownloaders()
            guard !Task.isCancelled, requestedBaseURL == baseURL, !model.locked else { return }
            downloaders = result
        } catch { loadError = AppModel.safeError(error) }
    }
}

private struct DownloadDirectorySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences

    private var baseURL: String { model.profile(.moviepilot).baseURL }
    private var selection: String? { preferences.preferredDownloadDirectoryID(for: baseURL) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DKCard {
                    DKSectionTitle(title: "预设下载目录")
                    Text("默认沿用已连接 MoviePilot 的下载目录。此处仅保存本机选择，不会修改 MoviePilot 配置；下载前仍可单次另选。")
                        .font(.subheadline).foregroundStyle(DKTheme.muted)
                    directoryRow(id: nil, name: preferences.text("沿用 MoviePilot 默认目录"), path: nil)
                    ForEach(model.resourceDirectoryOptions) { directory in
                        Divider()
                        directoryRow(id: directory.id, name: directory.name, path: directory.savePath)
                    }
                    if let error = model.resourceDirectoriesError {
                        Text(error).font(.caption).foregroundStyle(DKTheme.amber)
                    } else if !model.resourceDirectoriesLoading && model.resourceDirectoryOptions.isEmpty {
                        Text("MoviePilot 未返回可选目录，下载时沿用其默认配置。")
                            .font(.caption).foregroundStyle(DKTheme.muted)
                    }
                    Button { Task { await model.loadResourceDirectories() } } label: {
                        HStack {
                            if model.resourceDirectoriesLoading { ProgressView().controlSize(.small) }
                            Label("读取 MoviePilot 下载目录", systemImage: "arrow.clockwise")
                        }
                    }.buttonStyle(.bordered).disabled(!model.isConfigured(.moviepilot) || model.locked || model.resourceDirectoriesLoading)
                }
                Text("切换 MoviePilot 连接时不会沿用其他服务器的目录。若目录被移除，会恢复为 MoviePilot 默认目录。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
            }.padding(18)
        }
        .navigationTitle("预设下载目录").navigationBarTitleDisplayMode(.inline).dkScreen()
        .task { await model.loadResourceDirectories() }
        .refreshable { await model.loadResourceDirectories() }
    }

    private func directoryRow(id: String?, name: String, path: String?) -> some View {
        Button { preferences.setPreferredDownloadDirectoryID(id, for: baseURL) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).foregroundStyle(DKTheme.text).multilineTextAlignment(.leading)
                    if let path { Text(path).font(.caption).foregroundStyle(DKTheme.muted).multilineTextAlignment(.leading).textSelection(.enabled) }
                }
                Spacer(minLength: 8)
                if selection == id { Image(systemName: "checkmark.circle.fill").foregroundStyle(DKTheme.accent) }
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).disabled(model.locked)
            .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}
