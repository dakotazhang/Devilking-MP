import SwiftUI

/// The selected local group is shared by the status page and task page.
struct DKGroupScopePicker: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// Distinguishes active controls from views retained by another tab or
    /// preconstructed navigation destination in the accessibility hierarchy.
    let context: String
    @State private var selectionError: String?
    private var selectedName: String {
        preferences.selectedGroup?.name ?? preferences.text("全部服务器")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("统计范围", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Menu {
                    Button { choose(nil) } label: {
                        HStack {
                            Text("全部服务器")
                            if preferences.selectedGroupID == nil { Image(systemName: "checkmark") }
                        }
                    }.accessibilityLabel(Text(preferences.text("全部服务器")))
                    ForEach(preferences.serverGroups) { group in
                        Button { choose(group.id) } label: {
                            HStack {
                                Text(verbatim: group.name)
                                if preferences.selectedGroupID == group.id { Image(systemName: "checkmark") }
                            }
                        }.accessibilityLabel(Text(verbatim: group.name))
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: selectedName).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .background(DKTheme.card, in: Capsule())
                }
                .accessibilityLabel("统计范围")
                .accessibilityValue(Text(verbatim: selectedName))
                .accessibilityIdentifier("servers.groupScope." + context)
            }.frame(minHeight: 44)
            Text("状态表与下载器共用此范围；分组不修改服务器任务。")
                .font(.caption2).foregroundStyle(DKTheme.muted)
            if let selectionError { Text(selectionError).font(.caption).foregroundStyle(DKTheme.amber) }
            if let error = preferences.groupConfigurationError {
                Text(error).font(.caption).foregroundStyle(DKTheme.amber)
            }
        }
        .padding(.horizontal, 2)
    }

    private func choose(_ id: String?) {
        do { try preferences.setSelectedGroupID(id); selectionError = nil }
        catch { selectionError = AppModel.safeError(error) }
    }
}

struct ServerGroupsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var editing: ServerGroup?
    @State private var adding = false
    @State private var pendingDelete: ServerGroup?
    @State private var error: String?
    @State private var confirmingReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DKCard {
                    DKSectionTitle(title: "按用途分组", subtitle: "例如“家庭”“刷流”。一台下载器可以属于多个分组，同一分组内只统计一次。")
                    DKGroupScopePicker(context: "group-settings")
                    Button { adding = true } label: { Label("新建分组", systemImage: "folder.badge.plus").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("groups.add")
                        .disabled(preferences.groupConfigurationError != nil)
                    Text("删除分组只移除本机分类，保留服务器、凭据和所有远端任务。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }
                ForEach(preferences.serverGroups) { group in
                    DKCard {
                        HStack {
                            Text(verbatim: group.name).font(.headline)
                            Spacer()
                            Button { editing = group } label: { Label("编辑", systemImage: "pencil") }
                                .accessibilityIdentifier("groups.edit." + group.id)
                        }
                        let members = model.downloaderProfiles.filter { group.memberIDs.contains($0.kind) }
                        Text(verbatim: members.isEmpty ? preferences.text("还没有下载器成员") : members.map(\.displayName).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(DKTheme.muted)
                        Button("删除此分组", role: .destructive) { pendingDelete = group }.font(.caption).frame(minHeight: 44)
                            .accessibilityLabel(Text(preferences.text("删除分组：") + group.name))
                    }
                }
                if let configurationError = preferences.groupConfigurationError {
                    DKCard {
                        Text(configurationError).foregroundStyle(DKTheme.amber)
                        Button("重置本机分组", role: .destructive) { confirmingReset = true }
                        Text("仅清空无法读取的分组设置，服务器连接、凭据与远端任务保持不变。")
                            .font(.caption).foregroundStyle(DKTheme.muted)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(DKTheme.amber) }
            }.padding(18)
        }
        .navigationTitle("服务器分组").navigationBarTitleDisplayMode(.inline).dkScreen()
        .sheet(item: $editing) { ServerGroupEditorView(group: $0) }
        .sheet(isPresented: $adding) { ServerGroupEditorView() }
        .alert("删除这个分组？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除分组", role: .destructive) {
                guard let group = pendingDelete else { return }
                do { try preferences.deleteGroup(group.id); pendingDelete = nil }
                catch { self.error = AppModel.safeError(error) }
            }
        } message: { Text("仅删除本机分组，不移除服务器或远端任务。") }
        .alert("重置本机分组？", isPresented: $confirmingReset) {
            Button("取消", role: .cancel) {}
            Button("重置分组", role: .destructive) {
                do { try preferences.resetServerGroups(); error = nil }
                catch { self.error = AppModel.safeError(error) }
            }
        } message: { Text("原有分组与统计范围将清空。服务器连接、凭据与远端任务保持不变。") }
    }
}

private struct ServerGroupEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    var group: ServerGroup? = nil
    @State private var name = ""
    @State private var memberIDs = Set<ServiceID>()
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("分组名称") {
                    TextField("例如：家庭、刷流", text: $name).accessibilityIdentifier("groups.name")
                }
                Section {
                    ForEach(model.downloaderProfiles) { profile in
                        Toggle(isOn: Binding(get: { memberIDs.contains(profile.kind) }, set: { enabled in
                            if enabled { memberIDs.insert(profile.kind) } else { memberIDs.remove(profile.kind) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: profile.displayName)
                                Text(LocalizedStringKey(profile.protocolKind.title)).font(.caption).foregroundStyle(DKTheme.muted)
                            }
                        }.accessibilityIdentifier("groups.member." + profile.kind.rawValue)
                    }
                    if model.downloaderProfiles.isEmpty { Text("先添加下载器，再选择分组成员。") }
                } header: { Text("下载器成员") }
                  footer: { Text("未连接的成员保留在分组内，连接后会自动参与统计。MP 与 Emby 不计入下载器流量合计。") }
                if let error { Section { Text(error).foregroundStyle(DKTheme.amber) } }
            }
            .navigationTitle(Text(LocalizedStringKey(group == nil ? "新建分组" : "编辑分组"))).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            let validIDs = Set(model.downloaderProfiles.map(\.kind))
                            try preferences.saveGroup(id: group?.id, name: name, memberIDs: memberIDs.intersection(validIDs).sorted { $0.rawValue < $1.rawValue })
                            dismiss()
                        } catch { self.error = AppModel.safeError(error) }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("groups.save")
                }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                name = group?.name ?? ""; memberIDs = Set(group?.memberIDs ?? [])
            }
        }.tint(DKTheme.accent)
    }
}

struct ConnectionEditorView: View {
    private enum InputField: Hashable { case name, address, username, password, apiKey }
    @FocusState private var focusedField: InputField?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    var kind: ServiceKind? = nil
    @State private var protocolKind: ServiceProtocol = .qbittorrent
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var allowActions = false
    @State private var migrationProtected = false
    @State private var confirmingMigrationUnlock = false
    @State private var confirmingActions = false
    @State private var confirmingClear = false
    @State private var confirmingRemoval = false
    @State private var saveError: String?
    @State private var loaded = false

    private var supportsAPIKey: Bool { protocolKind == .moviepilot || protocolKind == .emby }
    private var availableProtocols: [ServiceProtocol] {
        ServiceProtocol.allCases.filter { candidate in
            candidate.isDownloader || !model.profiles.contains(where: { $0.protocolKind == candidate })
        }
    }
    private var title: String { kind.map { model.profile($0).displayName } ?? preferences.text("添加服务器") }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器身份") {
                    if kind == nil {
                        protocolMenu
                    } else {
                        DKInfoRow(title: "服务类型", value: protocolKind.title)
                    }
                    TextField("自定义名称", text: $name).focused($focusedField, equals: .name).accessibilityIdentifier("server.name")
                    Text("名称只用于本机区分服务器，不会修改服务端名称。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                    if let kind, name.trimmingCharacters(in: .whitespacesAndNewlines) != model.profile(kind).displayName {
                        Button("仅保存名称") {
                            do { try model.renameConnection(kind, name: name); dismiss() }
                            catch { saveError = AppModel.safeError(error) }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("server.rename")
                    }
                }
                Section("连接地址") {
                    TextField("服务地址", text: $address).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .address)
                        .accessibilityLabel("服务完整地址").accessibilityIdentifier("server.address")
                    Text("填写 http:// 或 https:// 开头的完整地址。内网地址需在同一网络或连接自己的 VPN。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                }
                Section("身份凭据") {
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .focused($focusedField, equals: .username)
                        .accessibilityIdentifier("server.username")
                    SecureField("密码", text: $password).textContentType(.password).privacySensitive()
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("server.password")
                    if supportsAPIKey {
                        SecureField("API Key / Token（可选）", text: $apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .focused($focusedField, equals: .apiKey)
                            .accessibilityIdentifier("server.apiKey")
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
                    if protocolKind.isDownloader {
                        Toggle(isOn: Binding(get: { migrationProtected }, set: { enabled in
                            if enabled { migrationProtected = true }
                            else if let kind, model.profile(kind).migrationProtected { confirmingMigrationUnlock = true }
                            else { migrationProtected = false }
                        })) { Label("保护此下载器的迁移任务", systemImage: "lock.shield") }
                            .accessibilityIdentifier("server.migrationProtection")
                        Text("全局迁移保护开启时，标记的下载器只能查看；不影响下载器自身运行。保存连接后生效。")
                            .font(.caption).foregroundStyle(DKTheme.muted)
                    }
                    if model.migrationProtection && migrationProtected {
                        Label("迁移保护开启，保存授权后仍保持只读。", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(DKTheme.amber)
                    }
                }
                Section {
                    Button("保存连接") { save() }.frame(maxWidth: .infinity).font(.headline)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("server.save")
                }
                if let kind {
                    connectionLifecycle(kind)
                }
                if let saveError { Section { Text(saveError).foregroundStyle(DKTheme.amber) } }
            }
            .scrollContentBackground(.hidden).background(DKTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(verbatim: title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                        .accessibilityIdentifier("server.dismissKeyboard")
                }
            }
            .onAppear(perform: load)
            .onChange(of: protocolKind) { next in
                guard kind == nil else { return }
                name = next.title; address = ""
                username = ""; password = ""; apiKey = ""
                allowActions = false; migrationProtected = false
            }
            .alert("启用此服务的操作权限？", isPresented: $confirmingActions) {
                Button("保持只读", role: .cancel) {}
                Button("允许操作") { allowActions = true }
            } message: { Text(preferences.text(permissionDescription) + "\n" + preferences.text("每次实际操作仍需确认。此授权将在保存连接后生效。")) }
            .alert("解除这个下载器的迁移标记？", isPresented: $confirmingMigrationUnlock) {
                Button("保持保护", role: .cancel) {}
                Button("确认迁移已结束") { migrationProtected = false }
            } message: { Text("确认该下载器已完成校验与交接后再解除。全局只读锁和服务操作授权仍独立生效。") }
            .alert("清理这个服务器的凭据？", isPresented: $confirmingClear) {
                Button("取消", role: .cancel) {}
                Button("清理本机凭据", role: .destructive) {
                    guard let kind else { return }
                    do { try model.clearCredentials(kind); dismiss() }
                    catch { saveError = AppModel.safeError(error) }
                }
            } message: { Text("仅清除本机钥匙串里的账号、密码与令牌，并断开连接。服务器设置和远端任务保留；重新连接需再次填写凭据。") }
            .alert("移除这个服务器？", isPresented: $confirmingRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除本机服务器", role: .destructive) {
                    guard let kind else { return }
                    do { try model.removeConnection(kind); dismiss() }
                    catch { saveError = AppModel.safeError(error) }
                }
            } message: { Text("从本机移除此服务器、凭据及分组关联。不会删除服务器、种子、下载文件或任何远端任务。") }
        }.tint(DKTheme.accent)
    }

    private var protocolMenu: some View {
        Menu {
            ForEach(availableProtocols) { option in
                Button {
                    focusedField = nil
                    protocolKind = option
                } label: {
                    HStack {
                        Text(LocalizedStringKey(option.title))
                        if protocolKind == option { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityLabel(Text(LocalizedStringKey(option.title)))
                .accessibilityIdentifier("server.type.option." + option.rawValue)
            }
        } label: {
            HStack(spacing: 10) {
                Text("服务类型").foregroundStyle(DKTheme.text)
                Spacer(minLength: 8)
                Text(LocalizedStringKey(protocolKind.title))
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("服务类型")
        .accessibilityValue(Text(LocalizedStringKey(protocolKind.title)))
        .accessibilityIdentifier("server.type")
    }

    @ViewBuilder private func connectionLifecycle(_ kind: ServiceID) -> some View {
        Section {
            if model.hasSavedCredentials(kind) {
                Button {
                    do {
                        let enabled = !model.profile(kind).enabled
                        try model.setConnectionEnabled(kind, enabled: enabled)
                        if enabled { Task { await model.refresh(kind) } }
                    } catch { saveError = AppModel.safeError(error) }
                } label: {
                    Label(model.profile(kind).enabled ? "断开连接" : "连接", systemImage: model.profile(kind).enabled ? "pause.circle" : "link")
                }.accessibilityIdentifier("server.toggleConnection")
            }
            DKServiceLink(kind: kind)
        } footer: { Text("断开只停止 App 访问并保留凭据；服务器继续运行。连接后只读取状态，不会启动或停止种子。") }
        Section {
            if model.hasSavedCredentials(kind) {
                Button("清理凭据", role: .destructive) { confirmingClear = true }
                    .accessibilityIdentifier("server.clearCredentials")
            }
            Button("移除服务器", role: .destructive) { confirmingRemoval = true }
                .accessibilityIdentifier("server.remove")
        } header: { Text("本机资料") } footer: { Text("以上操作仅影响这台手机，不删除任何远端任务或文件。") }
    }

    private var permissionDescription: String {
        switch protocolKind {
        case .qbittorrent, .transmission: return "允许单个任务启动、停止和全局上传限速；不包含删除、移动与强制校验。"
        case .moviepilot: return "允许确认后新增影视订阅，以及暂停或恢复现有订阅；已发出的资源搜索不会因此取消。"
        case .emby: return "允许修改当前用户的收藏与已看状态；不包含删除影片。"
        }
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        guard let kind else { name = protocolKind.title; address = ""; return }
        let profile = model.profile(kind), credential = model.credential(kind)
        protocolKind = profile.protocolKind; name = profile.displayName; address = profile.baseURL
        username = credential.username.isEmpty ? profile.username : credential.username
        password = credential.password; apiKey = credential.apiKey; allowActions = profile.allowActions; migrationProtected = profile.migrationProtected
    }

    private func save() {
        do {
            let savedKind: ServiceID
            if let kind {
                try model.saveConnection(kind, baseURL: address, username: username, password: password, apiKey: apiKey, allowActions: allowActions, name: name, migrationProtected: migrationProtected)
                savedKind = kind
            } else {
                savedKind = try model.createConnection(protocolKind: protocolKind, name: name, baseURL: address, username: username, password: password, apiKey: apiKey, allowActions: allowActions, migrationProtected: migrationProtected)
            }
            dismiss()
            Task { await model.refresh(savedKind) }
        } catch { saveError = AppModel.safeError(error) }
    }
}

struct PocketRemAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DKCard {
                    HStack(spacing: 14) {
                        Image("BrandMark").resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("口袋蕾姆").font(.title2.weight(.bold))
                            Text("完全开源、免费、无广告").font(.subheadline).foregroundStyle(DKTheme.accent)
                        }
                    }
                    Text("一款在 iPhone 上管理 qBittorrent、Transmission、刷流盒子与 MoviePilot 的工具。")
                        .font(.subheadline).foregroundStyle(DKTheme.muted)
                    DKInfoRow(title: "作者", value: "dk(dakotazhang)")
                    DKInfoRow(title: "版本", value: version)
                    DKInfoRow(title: "兼容", value: "iOS 16.1 及以上")
                }
                DKCard {
                    DKSectionTitle(title: "你的服务器，你来管理")
                    Text("App 直连你配置的服务器，无中转后台、统计 SDK 或广告。使用内网地址时，请先连接自己的 VPN。MP 资料与站点请求由你的服务端处理。")
                        .font(.subheadline).foregroundStyle(DKTheme.muted)
                    Text("前台按设置刷新；iOS 不保证后台常驻监控。分组和名称仅存本机，原有自动化与迁移流程独立运行。")
                        .font(.caption).foregroundStyle(DKTheme.muted)
                    Link(destination: URL(string: "https://github.com/dakotazhang/Devilking-MP")!) {
                        Label("查看开源项目", systemImage: "arrow.up.right.square")
                    }.frame(minHeight: 44)
                }
            }.padding(18)
        }.navigationTitle("关于").navigationBarTitleDisplayMode(.inline).dkScreen()
    }
    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
