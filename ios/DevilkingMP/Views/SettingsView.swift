import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var editingService: ServiceKind?
    @State private var importing = false
    @State private var confirmingMigrationUnlock = false
    @State private var importError: String?
    @State private var confirmingBiometric = false
    @State private var confirmingReadOnlyUnlock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    accountHeader
                    resources
                    appearance
                    dashboardModules
                    protection
                    privacy
                    about
                }.padding(18)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingService) { kind in ConnectionEditorView(kind: kind) }
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
                Text("仅当 qB1 → TR 批量校验和交接已经完成，且你确认可以管理这两个下载器时再关闭。关闭后仍需分别启用服务操作权限，每次写入仍会确认。")
            }
            .alert("关闭全局只读锁？", isPresented: $confirmingReadOnlyUnlock) {
                Button("保持只读", role: .cancel) {}
                Button("确认开启管理模式") { model.readOnlyMode = false }
            } message: {
                Text("关闭后，只有已单独授权的服务才能操作。qB1 / TR 仍受迁移保护限制，每次启停、限速或订阅都需要再次确认。可以随时重新开启只读锁。")
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
            HStack(spacing: 14) {
                Image("BrandMark").resizable().scaledToFill().frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Devilking MP管理").font(.headline)
                    Text("家庭专用 · 本机安全存储").font(.caption).foregroundStyle(DKTheme.muted)
                }
                Spacer()
            }
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
            DKSectionTitle(title: "服务连接", subtitle: "独立配置五个服务；日常默认只读。")
            ForEach(ServiceKind.allCases) { kind in
                Button { editingService = kind } label: {
                    DKCard {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).font(.title2).foregroundStyle(DKTheme.accent).frame(width: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(LocalizedStringKey(kind.compactTitle)).font(.headline).foregroundStyle(DKTheme.text)
                                Text(LocalizedStringKey(connectionDescription(kind))).font(.caption).foregroundStyle(DKTheme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(LocalizedStringKey(model.isConfigured(kind) ? "已配置" : "添加连接")).font(.caption).foregroundStyle(model.isConfigured(kind) ? DKTheme.green : DKTheme.accent)
                                if model.isConfigured(kind) {
                                    Text(LocalizedStringKey(model.canManage(kind) ? "可管理" : model.profile(kind).allowActions ? "权限已保存 · 当前只读" : "仅查看")).font(.caption2).foregroundStyle(DKTheme.muted)
                                }
                            }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DKTheme.muted)
                        }
                    }
                }.buttonStyle(.plain)
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
            Divider()
            NavigationLink { DownloadDirectorySettingsView() } label: {
                Label("预设下载目录", systemImage: "folder.fill").frame(minHeight: 36)
            }
            Divider()
            NavigationLink { DownloaderBindingsSettingsView() } label: {
                Label("MP 下载器对应关系", systemImage: "link").frame(minHeight: 36)
            }
            Divider()
            Picker(selection: $preferences.refreshInterval) {
                Text("关闭自动刷新").tag(0)
                Text("15 秒").tag(15)
                Text("30 秒").tag(30)
                Text("60 秒").tag(60)
                Text("120 秒").tag(120)
            } label: { Label("数据刷新频率", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("settings.refreshInterval")
            Text("仅在 App 前台刷新仪表盘与当前下载器列表；关闭后仍可手动刷新。发现页下拉刷新，搜索结果不会被定时刷新覆盖。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var appearance: some View {
        DKCard {
            DKSectionTitle(title: "应用设置")
            Picker("外观主题", selection: $preferences.theme) {
                ForEach(AppTheme.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.accessibilityIdentifier("settings.theme")
            Picker("应用语言", selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }.accessibilityIdentifier("settings.language")
            Text("界面支持简体中文、繁體中文与 English；影片名称、站点与服务返回的内容保留原文。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            Picker("字体大小", selection: $preferences.fontSize) {
                ForEach(AppFontSize.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.accessibilityIdentifier("settings.fontSize")
            Text("放大文字不会缩小系统辅助功能字体。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var dashboardModules: some View {
        DKCard {
            DKSectionTitle(title: "仪表盘定制", subtitle: "模块展示")
            ForEach(DashboardModule.allCases) { module in
                Toggle(LocalizedStringKey(module.title), isOn: Binding(get: { preferences.isVisible(module) }, set: { preferences.setVisible(module, $0) }))
                    .tint(DKTheme.accent).accessibilityIdentifier("settings.module.\(module.rawValue)")
            }
            Text("只改变本机仪表盘展示，不影响服务运行或下载任务。")
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
            Text("开启后可以浏览仪表盘、搜索影视和查看任务；订阅、启停与限速等写操作全部锁定。关闭需要确认，单个服务仍需另外授权。")
                .font(.caption).foregroundStyle(DKTheme.muted)
            Divider().overlay(.white.opacity(0.05))
            Toggle(isOn: Binding(get: { model.migrationProtection }, set: { enabled in
                if enabled { model.migrationProtection = true } else { confirmingMigrationUnlock = true }
            })) {
                Label("qB1 / TR 迁移保护", systemImage: "lock.shield")
            }.tint(DKTheme.accent)
            Text("保护开启时，只读取校验与任务状态，不从 App 启停 qB1 / TR 或修改其上传上限。")
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
            Label("在外先连家庭 VPN", systemImage: "network.badge.shield.half.filled").font(.subheadline.weight(.medium))
            Text("本应用直接访问你填写的服务地址。使用内网地址时，请先连接家庭 VPN；不需要把下载器、Emby 或 MoviePilot 新增映射到公网。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var about: some View {
        DKCard {
            DKSectionTitle(title: "关于")
            DKInfoRow(title: "版本", value: version)
            DKInfoRow(title: "兼容", value: "iOS 16.1 及以上")
            DKInfoRow(title: "家庭分工", value: "qB1 下载 · qB2 备用 · TR 保种")
            Text("前台刷新状态，不承诺 iOS 后台常驻监控。原有 MoviePilot、IYUU 与迁移流程继续独立运行。")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func connectionDescription(_ kind: ServiceKind) -> String {
        guard model.isConfigured(kind) else { return kind.subtitle }
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
                Text("请将 MoviePilot 中的下载器，明确对应到 App 已配置的同一个下载器。名称和地址可能不同，请核对后选择；未绑定的下载器不能从 App 发起下载。")
                    .font(.subheadline).foregroundStyle(DKTheme.muted)
                ForEach(downloaders) { downloader in
                    DKCard {
                        Text(downloader.name).font(.headline)
                        Text(downloader.type).font(.caption).foregroundStyle(DKTheme.muted)
                        if let endpoint = downloader.targetBaseURL {
                            Text(endpoint).font(.caption).foregroundStyle(DKTheme.muted).textSelection(.enabled)
                        }
                        Picker("对应 App 下载器", selection: Binding<ServiceKind?>(get: {
                            preferences.boundDownloaderKind(for: downloader.bindingID, baseURL: baseURL)
                        }, set: {
                            preferences.setBoundDownloaderKind($0, for: downloader.bindingID, baseURL: baseURL)
                        })) {
                            Text("未绑定").tag(ServiceKind?.none)
                            ForEach(availableKinds(for: downloader)) { kind in
                                Text(LocalizedStringKey(kind.compactTitle)).tag(Optional(kind))
                            }
                        }
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
                Text("对应关系仅存本机，不改 MoviePilot 的下载器设置。下载仍遵守全局只读锁、服务操作权限和迁移保护。重新保存 MP 连接后需要重新确认。")
                    .font(.caption).foregroundStyle(DKTheme.muted)
            }.padding(18)
        }
        .navigationTitle("MP 下载器对应关系").navigationBarTitleDisplayMode(.inline).dkScreen()
        .task { await load() }.refreshable { await load() }
    }

    private func availableKinds(for downloader: MPResourceDownloader) -> [ServiceKind] {
        guard downloader.canBind else { return [] }
        let kinds: [ServiceKind]
        switch downloader.type.lowercased() {
        case "qbittorrent": kinds = [.qb1, .qb2]
        case "transmission": kinds = [.tr]
        default: kinds = []
        }
        return kinds.filter { model.isConfigured($0) }
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

private struct ConnectionEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    let kind: ServiceKind
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var allowActions = false
    @State private var confirmingActions = false
    @State private var confirmingDisconnect = false
    @State private var saveError: String?
    @State private var loaded = false

    private var supportsAPIKey: Bool { kind == .moviepilot || kind == .emby }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务地址", text: $address).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("服务完整地址")
                    Text("填写 http:// 或 https:// 开头的完整地址。家庭内网与 VPN 使用相同地址即可。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                } header: { Text(preferences.text(kind.compactTitle) + " · " + preferences.text("连接地址")) }

                Section("身份凭据") {
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    SecureField("密码", text: $password).textContentType(.password).privacySensitive()
                    if supportsAPIKey {
                        SecureField("API Key / Token（可选）", text: $apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    }
                    Text(LocalizedStringKey(supportsAPIKey ? "可使用账号密码，或服务支持的 API Key。凭据保存在本机钥匙串中。" : "账号密码仅存本机钥匙串，不包含在普通连接设置中。"))
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }

                Section("操作权限") {
                    Toggle(isOn: Binding(get: { allowActions }, set: { enabled in
                        if enabled { confirmingActions = true } else { allowActions = false }
                    })) { Text("允许从 App 操作此服务") }.tint(DKTheme.accent)
                    Text(LocalizedStringKey(permissionDescription)).font(.caption).foregroundStyle(DKTheme.muted)
                    if model.readOnlyMode {
                        Label("全局只读锁已开启，保存此授权后仍保持只读。", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(DKTheme.amber)
                    }
                    if model.migrationProtection && (kind == .qb1 || kind == .tr) {
                        Label("迁移保护开启，保存授权后仍保持只读。", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(DKTheme.amber)
                    }
                }

                Section {
                    Button("保存连接") { save() }.frame(maxWidth: .infinity).font(.headline)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.isConfigured(kind) {
                    Section {
                        DKServiceLink(kind: kind)
                        Button("清除本机连接与凭据", role: .destructive) { confirmingDisconnect = true }
                    } footer: { Text("仅清除本机保存的连接，不会修改服务器或下载任务。") }
                }
            }
            .scrollContentBackground(.hidden).background(DKTheme.background)
            .navigationTitle(Text(LocalizedStringKey(kind.compactTitle))).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear(perform: load)
            .alert("启用此服务的操作权限？", isPresented: $confirmingActions) {
                Button("保持只读", role: .cancel) {}
                Button("允许操作") { allowActions = true }
            } message: { Text(preferences.text(permissionDescription) + "\n" + preferences.text("每次实际操作仍需确认。此授权将在保存连接后生效。")) }
            .alert("清除此连接？", isPresented: $confirmingDisconnect) {
                Button("取消", role: .cancel) {}
                Button("清除本机配置", role: .destructive) { model.disconnect(kind); dismiss() }
            } message: { Text(preferences.text(kind.compactTitle) + "\n" + preferences.text("本机凭据会从钥匙串中移除；服务器上的数据保留。")) }
            .alert("连接未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("知道了", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
        }.tint(DKTheme.accent)
    }

    private var permissionDescription: String {
        switch kind {
        case .qb1, .qb2, .tr: return "允许单个任务启动、停止和全局上传限速；不包含删除、移动与强制校验。"
        case .moviepilot: return "允许确认后新增影视订阅，以及暂停或恢复现有订阅；已发出的资源搜索不会因此取消。"
        case .emby: return "允许修改当前用户的收藏与已看状态；不包含删除影片。"
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let profile = model.profile(kind)
        let credential = model.credential(kind)
        address = profile.baseURL
        username = credential.username.isEmpty ? profile.username : credential.username
        password = credential.password
        apiKey = credential.apiKey
        allowActions = profile.allowActions
    }

    private func save() {
        do {
            try model.saveConnection(kind, baseURL: address, username: username, password: password, apiKey: apiKey, allowActions: allowActions)
            dismiss()
            Task { await model.refresh(kind) }
        } catch { saveError = AppModel.safeError(error) }
    }
}
