import SwiftUI

extension DashboardTaskFilter {
    var shortTitle: String {
        switch self {
        case .all: return "全部"
        case .downloading: return "下载"
        case .seeding: return "做种"
        case .verifying: return "校验"
        case .stopped: return "停止"
        case .errors: return "异常"
        }
    }
    func includes(_ task: TorrentTask) -> Bool {
        if self == .all { return true }
        if self == .errors { return !(task.error ?? "").isEmpty }
        if task.kind == .tr {
            switch self {
            case .downloading: return task.rawState == "4"
            case .seeding: return task.rawState == "6"
            case .verifying: return ["1", "2"].contains(task.rawState)
            case .stopped: return task.rawState == "0"
            default: return false
            }
        }
        switch self {
        case .downloading: return ["downloading", "stalledDL", "forcedDL", "metaDL", "forcedMetaDL"].contains(task.rawState)
        case .seeding: return ["uploading", "stalledUP", "forcedUP"].contains(task.rawState)
        case .verifying: return ["checkingUP", "checkingDL", "checkingResumeData"].contains(task.rawState)
        case .stopped: return ["stoppedUP", "stoppedDL", "pausedUP", "pausedDL"].contains(task.rawState)
        default: return false
        }
    }
}

private struct SelectedDownloaderTask: Identifiable {
    var task: TorrentTask
    var id: String { task.qualifiedID }
}

struct DownloadersView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selectedKind: ServiceKind?
    @Binding var filter: DashboardTaskFilter
    @State private var query = ""
    @State private var selectedTask: SelectedDownloaderTask?
    @State private var limitKind: ServiceKind?
    @State private var refreshRequests = 0
    @State private var lastRead: [ServiceKind: Date] = [:]
    @State private var readErrors: [ServiceKind: String] = [:]
    @State private var displayNow = Date()
    @State private var isVisible=false
    private let kinds: [ServiceKind] = [.qb1, .qb2, .tr]
    private var refreshing: Bool { refreshRequests > 0 }

    private var activeKinds: [ServiceKind] {
        kinds.filter { (selectedKind == nil || $0 == selectedKind) && model.isConfigured($0) }
    }
    private var currentTasks: [TorrentTask] { model.tasks.filter { activeKinds.contains($0.kind) } }
    private var filteredTasks: [TorrentTask] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return currentTasks.filter {
            filter.includes($0) && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)
                || $0.category.localizedCaseInsensitiveContains(text)
                || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(text) }))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    controls
                    downloaderPicker
                    if model.readOnlyMode { readOnlyNotice }
                    if model.migrationProtection && selectedKind != .qb2 { DKProtectionNotice(compact: true) }
                    if activeKinds.isEmpty {
                        DKCard {
                            DKEmptyState(symbol: "link.badge.plus", title: "还未连接下载器", detail: "先在设置中添加所需连接。每个下载器独立保存账号、权限和状态。")
                        }
                    } else {
                        summary
                        filters
                        ForEach(activeKinds) { kind in
                            if let error = readErrors[kind] {
                                DKCard {
                                    Label("\(kind.compactTitle) · 列表未更新", systemImage: "exclamationmark.triangle")
                                        .font(.subheadline).foregroundStyle(DKTheme.amber)
                                    Text(error).font(.caption).foregroundStyle(DKTheme.muted)
                                    Text("保留上次列表；下面的旧数据不代表当前状态。").font(.caption).foregroundStyle(DKTheme.muted)
                                }
                            } else if !taskDataIsCurrent(kind), currentTasks.contains(where: { $0.kind == kind }) {
                                DKCard {
                                    Label("\(kind.compactTitle) · 上次列表", systemImage: "clock.badge.exclamationmark")
                                        .font(.subheadline).foregroundStyle(DKTheme.amber)
                                    Text("任务列表已过期或尚未在本页重新读取。旧速度不计为当前流量，请刷新核对。")
                                        .font(.caption).foregroundStyle(DKTheme.muted)
                                }
                            }
                        }
                        if filteredTasks.isEmpty {
                            DKCard {
                                DKEmptyState(symbol: "tray", title: currentTasks.isEmpty ? "尚无已载入任务" : "没有匹配的任务",
                                             detail: currentTasks.isEmpty ? "刷新读取真实任务。读取失败不代表下载器为空。" : "换个关键词或筛选条件试试。排队任务可在“全部”查看。")
                            }
                        } else {
                            Text("已载入 \(currentTasks.count) 个 · 显示 \(filteredTasks.count) 个\(selectedKind == nil ? " · 跨下载器分别计数" : "")")
                                .font(.caption).foregroundStyle(DKTheme.muted).padding(.horizontal, 3)
                            ForEach(filteredTasks, id: \.qualifiedID) { task in
                                Button { selectedTask = SelectedDownloaderTask(task: task) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if selectedKind == nil {
                                            Text(task.kind.compactTitle).font(.caption.weight(.semibold)).foregroundStyle(DKTheme.accent).padding(.leading, 8)
                                        }
                                        TorrentTaskRow(task: task, isCurrent: taskDataIsCurrent(task.kind))
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("downloaders.task.\(task.qualifiedID)")
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(activeKinds) { kind in
                                DKServiceLink(kind: kind, title: "打开 \(kind.compactTitle) 原页面").frame(minHeight: 44)
                            }
                        }.padding(.top, 8)
                    }
                }.padding(18)
            }
            .searchable(text: $query, prompt: "搜索名称、站点或标签")
            .navigationTitle("下载器")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await reload() }
            .task(id: refreshScheduleID) {
                guard isVisible && scenePhase == .active && !model.locked else{return}
                await reload()
                guard preferences.refreshInterval > 0 else{return}
                while !Task.isCancelled && isVisible && scenePhase == .active && !model.locked {
                    do { try await Task.sleep(nanoseconds:UInt64(preferences.refreshInterval)*1_000_000_000) } catch {return}
                    guard !Task.isCancelled else{return}
                    await reload()
                }
            }
            .onAppear { isVisible=true }
            .onDisappear { isVisible=false }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    displayNow = Date()
                }
            }
            .sheet(item: $selectedTask) { item in
                TaskDetailView(original: item.task)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if !taskDataIsCurrent(item.task.kind) {
                            Label("上次列表 · 请刷新核对当前任务状态", systemImage: "clock.badge.exclamationmark")
                                .font(.caption).foregroundStyle(DKTheme.amber).padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading).background(DKTheme.card)
                        }
                    }
            }
            .sheet(item: $limitKind) { kind in UploadLimitView(kind: kind) }
            .dkScreen()
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { refreshButton; if let kind = selectedKind { limitButton(kind) }; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { refreshButton; if let kind = selectedKind { limitButton(kind) } }
        }
    }
    private var refreshButton: some View {
        Button { Task { await reload() } } label: {
            HStack(spacing: 7) {
                if refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                Text(refreshing ? "正在读取" : "刷新任务")
            }.frame(minHeight: 44).padding(.horizontal, 8)
        }.buttonStyle(.bordered).disabled(refreshing || activeKinds.isEmpty || model.locked)
            .accessibilityIdentifier("downloaders.refresh")
    }
    private func limitButton(_ kind: ServiceKind) -> some View {
        Button { limitKind = kind } label: {
            Label("上传上限", systemImage: "speedometer").frame(minHeight: 44).padding(.horizontal, 8)
        }.buttonStyle(.bordered).disabled(!model.canManage(kind) || model.busy || refreshing)
            .accessibilityLabel("设置\(kind.compactTitle)上传上限")
            .accessibilityIdentifier("downloaders.uploadLimit")
    }
    private var downloaderPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                downloaderChoice(nil, title: "全部下载器")
                ForEach(kinds) { kind in downloaderChoice(kind, title: kind.compactTitle) }
            }
        }
    }
    private func downloaderChoice(_ kind: ServiceKind?, title: String) -> some View {
        Button { selectedKind = kind } label: {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(selectedKind == kind ? DKTheme.background : DKTheme.muted)
                .background(selectedKind == kind ? DKTheme.accent : DKTheme.card, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("downloaders.service.\(kind?.rawValue ?? "all")")
            .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
    }
    private var readOnlyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(DKTheme.amber)
            Text("全局只读已开启 · 可以查看，启停与限速保持锁定。").font(.caption).foregroundStyle(DKTheme.muted)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DKTheme.amber.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
    }
    private var summary: some View {
        let aggregate = DashboardAggregate(configured: activeKinds, snapshots: model.dashboardSnapshots, now: displayNow)
        return DKCard {
            Text(selectedKind?.compactTitle ?? "全部家庭下载器").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 12) {
                DKMetric(title: "当前下载", value: aggregate.downloadRate.map(Format.rate) ?? "—", symbol: "arrow.down")
                DKMetric(title: "当前上传", value: aggregate.uploadRate.map(Format.rate) ?? "—", symbol: "arrow.up", color: DKTheme.green)
            }
            Text("\(aggregate.currentCount) / \(aggregate.configuredCount) 个下载器有当前流量；任务列表另行读取。")
                .font(.caption).foregroundStyle(aggregate.hasPartialCoverage ? DKTheme.amber : DKTheme.muted)
            ForEach(activeKinds) { kind in
                if let date = lastRead[kind] {
                    Text("\(kind.compactTitle) 列表读取于 \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(DKTheme.muted)
                }
            }
        }
    }
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DashboardTaskFilter.allCases) { item in
                    Button { filter = item } label: {
                        Text(LocalizedStringKey(item.shortTitle)).font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                            .foregroundStyle(filter == item ? DKTheme.background : DKTheme.muted)
                            .background(filter == item ? DKTheme.accent : DKTheme.card, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("downloaders.filter.\(item.rawValue)")
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        }
    }
    private func reload() async {
        guard !refreshing && !model.locked && !Task.isCancelled else { return }
        let requestedKinds = activeKinds
        guard !requestedKinds.isEmpty else { return }
        refreshRequests += 1
        defer { refreshRequests -= 1 }
        async let dashboard:Void=model.refreshDashboard(manual:false)
        let sharedModel=model
        await withTaskGroup(of:(ServiceKind,Bool).self) { group in
            for kind in requestedKinds {
                group.addTask { (kind,await sharedModel.loadTasks(kind)) }
            }
            for await (kind,success) in group {
                guard !Task.isCancelled && !model.locked else {continue}
                if success {
                    let completedAt=Date()
                    lastRead[kind]=completedAt;displayNow=completedAt;readErrors[kind]=nil
                } else {readErrors[kind]="接口读取未完成，请检查连接并稍后刷新。"}
            }
        }
        await dashboard
    }

    private var refreshScheduleID:String { "\(selectedKind?.rawValue ?? "all")-\(preferences.refreshInterval)-\(scenePhase == .active)-\(model.locked)-\(isVisible)" }

    private func taskDataIsCurrent(_ kind: ServiceKind) -> Bool {
        guard readErrors[kind] == nil, let read = lastRead[kind] else { return false }
        let age = displayNow.timeIntervalSince(read)
        return age >= -5 && age <= 125
    }
}

private struct TorrentTaskRow: View {
    let task: TorrentTask
    var isCurrent = true
    private var progress: Double { min(1, max(0, task.verification ?? task.progress)) }
    var body: some View {
        DKCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: task.verification != nil ? "checkmark.shield" : task.isStopped ? "pause.circle" : task.isComplete ? "arrow.up.circle" : "arrow.down.circle")
                    .font(.title3).foregroundStyle(!isCurrent || task.isStopped ? DKTheme.muted : task.isComplete ? DKTheme.green : DKTheme.accent)
                Text(task.name).font(.subheadline.weight(.semibold)).foregroundStyle(DKTheme.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(DKTheme.muted)
            }
            ProgressView(value: progress).tint(task.verification != nil ? DKTheme.amber : DKTheme.accent)
            if !isCurrent {
                Label("上次列表", systemImage: "clock").font(.caption2).foregroundStyle(DKTheme.amber)
            }
            HStack(spacing: 8) {
                Text(task.verification != nil ? "校验 \(Int(progress * 100))%" : "\(Int(progress * 100))% · \(task.state)")
                Spacer(minLength: 0)
                Text(Format.bytes(Double(task.size)))
            }.font(.caption).foregroundStyle(DKTheme.muted).monospacedDigit()
            HStack(spacing: 14) {
                Label(isCurrent ? Format.rate(task.downloadRate) : "—", systemImage: "arrow.down").foregroundStyle(isCurrent ? DKTheme.accent : DKTheme.muted)
                Label(isCurrent ? Format.rate(task.uploadRate) : "—", systemImage: "arrow.up").foregroundStyle(isCurrent ? DKTheme.green : DKTheme.muted)
                Spacer(minLength: 0)
                if !task.category.isEmpty { Text(task.category).foregroundStyle(DKTheme.muted).lineLimit(1) }
            }.font(.caption2).monospacedDigit()
            if let error = task.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(DKTheme.amber).lineLimit(3)
            }
        }
    }
}

private struct TaskDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: TorrentTask
    @State private var showingConfirmation = false
    private var task: TorrentTask { model.tasks.first { $0.id == original.id && $0.kind == original.kind } ?? original }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    DKCard {
                        Text(task.name).font(.headline).textSelection(.enabled)
                        DKStatus(text: task.state, color: task.isStopped ? DKTheme.muted : DKTheme.green)
                        ProgressView(value: min(1, max(0, task.verification ?? task.progress))).tint(DKTheme.accent)
                        DKInfoRow(title: "完成进度", value: String(format: "%.2f%%", task.progress * 100))
                        if let verification = task.verification { DKInfoRow(title: "校验进度", value: String(format: "%.2f%%", verification * 100)) }
                        DKInfoRow(title: "大小", value: Format.bytes(Double(task.size)))
                        DKInfoRow(title: "下载 / 上传", value: "\(Format.rate(task.downloadRate)) / \(Format.rate(task.uploadRate))")
                        DKInfoRow(title: "分享率", value: Format.ratio(task.ratio))
                        DKInfoRow(title: "种子 / 用户连接", value: "\(task.seeds) / \(task.peers)")
                    }
                    DKCard {
                        DKSectionTitle(title: "归属与文件")
                        DKInfoRow(title: "下载器", value: task.kind.compactTitle)
                        DKInfoRow(title: "分类", value: task.category)
                        DKInfoRow(title: "标签", value: task.tags.joined(separator: "、"))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("保存路径").font(.caption).foregroundStyle(DKTheme.muted)
                            Text(task.path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let error = task.error, !error.isEmpty {
                        DKCard { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(DKTheme.amber).textSelection(.enabled) }
                    }
                    if model.migrationProtection && task.kind != .qb2 { DKProtectionNotice() }
                    DKCard {
                        Button { showingConfirmation = true } label: {
                            Label(task.isStopped ? "启动此任务" : "停止此任务", systemImage: task.isStopped ? "play.fill" : "pause.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }.buttonStyle(.borderedProminent).disabled(!model.canManage(task.kind) || model.busy || task.verification != nil)
                        Text(model.canManage(task.kind) ? "仅操作当前任务；每次操作都需要确认。校验中的任务不能在此操作。" : "当前仅查看。请在设置检查操作权限与迁移保护。")
                            .font(.caption).foregroundStyle(DKTheme.muted)
                        DKServiceLink(kind: task.kind)
                    }
                }.padding(18)
            }
            .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert(task.isStopped ? "启动这个任务？" : "停止这个任务？", isPresented: $showingConfirmation) {
                Button("取消", role: .cancel) {}
                Button(task.isStopped ? "确认启动" : "确认停止") {
                    let start = task.isStopped
                    Task { await model.performTask(task, start: start) }
                }
            } message: { Text("\(task.kind.compactTitle)\n\(task.name)\n操作前会重新核对任务；失败不会自动重试。") }
            .dkScreen()
        }.tint(DKTheme.accent)
    }
}

private struct UploadLimitView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: ServiceKind
    @State private var input = ""
    @State private var confirming = false
    private var value: Double? { Double(input.replacingOccurrences(of: ",", with: ".")) }
    private var valid: Bool { value.map { $0.isFinite && $0 >= 0 && $0 <= 10_000 } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(kind.compactTitle) · 全局上传上限") {
                    HStack {
                        TextField("请输入带宽", text: $input).keyboardType(.decimalPad)
                        Text("Mbps").foregroundStyle(DKTheme.muted)
                    }
                    if let value, valid {
                        Text(value == 0 ? "0 表示不限制上传。" : "约 \(String(format: "%.2f", value / 8)) MB/s（十进制）。")
                            .font(.caption).foregroundStyle(DKTheme.muted)
                    }
                }
                Section {
                    Text("单位是兆比特每秒，60 Mbps 约为 7.5 MB/s。仅修改所选下载器，其他下载器不受影响。")
                        .font(.footnote).foregroundStyle(DKTheme.muted)
                    Button("核对并设置") { confirming = true }
                        .disabled(!valid || !model.canManage(kind) || model.busy)
                }
            }
            .scrollContentBackground(.hidden).background(DKTheme.background)
            .navigationTitle("上传限速").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("确认修改上传上限？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("确认设置") {
                    guard let value, valid else { return }
                    Task { await model.setUploadLimit(kind, mbps: value); dismiss() }
                }
            } message: { Text("\(kind.compactTitle)：\(input) Mbps。此次写入失败后不会自动重试。") }
        }.tint(DKTheme.accent)
    }
}
