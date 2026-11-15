import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isVisible=false
    @State private var displayNow = Date()
    let openSettings: () -> Void
    var openDownloaders: (ServiceKind?, DashboardTaskFilter) -> Void = { _, _ in }

    private var configuredKinds: [ServiceKind] {
        model.visibleDownloaderProfiles.filter { model.isConfigured($0.kind) }.map(\.kind)
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        let scopeKinds = configuredKinds
        let aggregate = DashboardAggregate(configured: scopeKinds, snapshots: model.dashboardSnapshots, now: displayNow)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DKCharacterHeader()
                    refreshHeader
                    if let error = model.configurationError {
                        DKCard {
                            Label("服务器配置未读到", systemImage: "exclamationmark.triangle").foregroundStyle(DKTheme.amber)
                            Text(error).font(.caption).foregroundStyle(DKTheme.muted)
                            Text("原本机配置保留，未自动重置。请先检查连接配置，再恢复访问。")
                                .font(.caption).foregroundStyle(DKTheme.muted)
                        }.accessibilityIdentifier("servers.configurationError")
                    }
                    DKGroupScopePicker(context: "status")
                    if scopeKinds.isEmpty {
                        firstRun
                    } else {
                        if preferences.isVisible(.traffic) { traffic(aggregate) }
                        if preferences.isVisible(.tasks) { taskOverview(aggregate) }
                        if model.migrationProtection && scopeKinds.contains(where: { model.profile($0).migrationProtected }) { DKProtectionNotice(compact: true) }
                        if preferences.isVisible(.services) {
                            DKSectionTitle(title: "下载器状态", subtitle: "点开查看任务与筛选；每个服务独立读取。")
                            ForEach(scopeKinds) { kind in
                                DownloaderDashboardCard(kind: kind, snapshot: model.dashboardSnapshots[kind], now: displayNow) {
                                    openDownloaders(kind, .all)
                                }
                            }
                        }
                        if preferences.isVisible(.storage) { storage(now: displayNow) }
                        if preferences.isVisible(.services) { serviceEntrances }
                    }
                }.padding(18)
            }
            .refreshable { await model.refreshDashboard() }
            .navigationTitle("状态表")
            .navigationBarTitleDisplayMode(.inline)
            .dkScreen()
            .task(id: refreshScheduleID) {
                guard isVisible && scenePhase == .active && !model.locked else{return}
                await model.refreshDashboard(manual:false)
                guard preferences.refreshInterval > 0 else{return}
                while !Task.isCancelled && isVisible && scenePhase == .active && !model.locked {
                    do { try await Task.sleep(nanoseconds:UInt64(preferences.refreshInterval)*1_000_000_000) } catch { return }
                    guard !Task.isCancelled else{return}
                    await model.refreshDashboard(manual:false)
                }
            }
            .task(id: freshnessScheduleID) {
                guard isVisible, scenePhase == .active, !model.locked else { return }
                while !Task.isCancelled && isVisible && scenePhase == .active && !model.locked {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    displayNow = Date()
                }
            }
            .onAppear { isVisible=true; displayNow=Date() }
            .onDisappear { isVisible=false;model.cancelDashboardRefresh() }
        }
    }

    private var refreshScheduleID:String { "\(preferences.selectedGroupID ?? "all-groups")-\(configuredKinds.map(\.rawValue).joined(separator: ","))-\(preferences.refreshInterval)-\(scenePhase == .active)-\(model.locked)-\(isVisible)" }
    private var freshnessScheduleID: String { "\(isVisible)-\(scenePhase == .active)-\(model.locked)" }

    private var refreshHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) { headerTitle; Spacer(minLength: 8); refreshButton }
            VStack(alignment: .leading, spacing: 12) { headerTitle; refreshButton }
        }
    }
    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("下载与保种").font(.title2.weight(.bold))
            Text(preferences.refreshInterval == 0 ? "仅手动刷新 · 默认只读" : "前台每\(preferences.refreshInterval)秒更新 · 默认只读")
                .font(.caption).foregroundStyle(DKTheme.muted)
        }
    }
    private var refreshButton: some View {
        Button { Task { await model.refreshDashboard() } } label: {
            HStack(spacing: 7) {
                if model.dashboardManualRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
                Text(model.dashboardManualRefreshing ? "更新中" : "刷新")
            }.font(.subheadline.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44)
        }.buttonStyle(.bordered)
        .disabled(model.dashboardManualRefreshing || model.locked || configuredKinds.isEmpty)
        .accessibilityLabel("刷新状态表，只读取下载器状态")
        .accessibilityIdentifier("dashboard.refresh")
    }
    private var firstRun: some View {
        DKCard {
            DKEmptyState(symbol: "server.rack", title: model.downloaderProfiles.isEmpty ? "连接你的下载器" : "当前范围没有已连接下载器", detail: model.downloaderProfiles.isEmpty ? "添加任意数量的 qBittorrent 或 Transmission，按自己的分组查看流量、任务和磁盘余量。未连接时不显示演示统计。" : "可切换统计范围、调整分组成员，或在服务器设置中连接已保存的下载器。")
            Button(action: openSettings) {
                Label("配置服务连接", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).frame(minHeight: 44)
            }.buttonStyle(.borderedProminent)
            Text("使用内网地址时请先连接自己的 VPN。登录资料仅存本机钥匙串。").font(.caption).foregroundStyle(DKTheme.muted)
        }
    }
    private func traffic(_ aggregate: DashboardAggregate) -> some View {
        DKCard {
            Text("实时流量").font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                DashboardMetric(title: "总下载", value: aggregate.downloadRate.map(Format.rate) ?? "—", symbol: "arrow.down.circle.fill", color: DKTheme.accent)
                DashboardMetric(title: "总上传", value: aggregate.uploadRate.map(Format.rate) ?? "—", symbol: "arrow.up.circle.fill", color: DKTheme.green)
            }
            Text(coverage(aggregate)).font(.caption).foregroundStyle(aggregate.hasPartialCoverage ? DKTheme.amber : DKTheme.muted)
            if let oldest = aggregate.oldestUpdate, let newest = aggregate.newestUpdate {
                Text(oldest == newest ? "更新于 \(newest.formatted(date: .omitted, time: .standard))" : "各服务更新于 \(oldest.formatted(date: .omitted, time: .standard))–\(newest.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(DKTheme.muted).monospacedDigit()
            }
        }
    }
    private func taskOverview(_ aggregate: DashboardAggregate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DKSectionTitle(title: "任务监控", subtitle: aggregate.hasPartialCoverage ? "以下为已更新下载器的部分合计。" : "任务按下载器计数；跨站辅种会分别计入。")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(DashboardTaskFilter.allCases) { filter in
                    Button { openDownloaders(nil, filter) } label: {
                        DKCard {
                            DashboardMetric(title: filter.title, value: aggregate.counts.map { String($0[filter]) } ?? "—", symbol: symbol(filter), color: filter == .errors || filter == .verifying ? DKTheme.amber : DKTheme.accent)
                            Label("查看任务", systemImage: "chevron.right").font(.caption2).foregroundStyle(DKTheme.muted)
                        }.frame(maxHeight: .infinity, alignment: .top)
                    }.buttonStyle(.plain).disabled(aggregate.counts == nil)
                        .accessibilityIdentifier("dashboard.tasks.\(filter.rawValue)")
                }
            }
            if let counts = aggregate.counts, counts.queued > 0 || counts.unknown > 0 {
                Text("另有 \(counts.queued) 个排队任务、\(counts.unknown) 个其他或未知状态。")
                    .font(.caption).foregroundStyle(counts.unknown > 0 ? DKTheme.amber : DKTheme.muted)
            }
            Text("异常可能与下载、做种状态重叠；不额外发起 Tracker 或连接测试。")
                .font(.caption2).foregroundStyle(DKTheme.muted)
        }
    }
    private func storage(now: Date) -> some View {
        DKCard {
            DKSectionTitle(title: "磁盘余量", subtitle: "仅显示各下载器默认下载位置；共用 NAS 的余量不相加。")
            ForEach(configuredKinds) { kind in
                let snapshot = model.dashboardSnapshots[kind]
                let current = snapshot?.isFresh(now: now) == true
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: model.profile(kind).displayName).font(.subheadline.weight(.semibold))
                    if let disk = snapshot?.disk {
                        Text("\(disk.label) · 可用 \(Format.bytes(disk.freeBytes))\(current ? "" : "（上次数据）")")
                            .font(.subheadline).foregroundStyle(current ? DKTheme.accent : DKTheme.muted).monospacedDigit()
                        if let total = disk.totalBytes, total > 0 {
                            ProgressView(value: min(1, max(0, 1 - disk.freeBytes / total))).tint(current ? DKTheme.accent : DKTheme.muted)
                            Text("已用 \(Format.bytes(total - disk.freeBytes)) / \(Format.bytes(total))").font(.caption2).foregroundStyle(DKTheme.muted)
                        }
                    } else {
                        Text(current ? "余量未返回" : "等待读取磁盘余量").font(.caption).foregroundStyle(DKTheme.muted)
                    }
                }.padding(.vertical, 3)
            }
        }
    }
    private var serviceEntrances: some View {
        DKCard {
            Text("管理入口").font(.headline)
            ForEach(configuredKinds + model.profiles.filter { !$0.kind.isDownloader && model.isConfigured($0.kind) }.map(\.kind)) { kind in
                DKServiceLink(kind: kind, title: "打开 \(model.profile(kind).displayName)").frame(minHeight: 36)
            }
            Button(action: openSettings) { Label("连接与只读权限", systemImage: "lock.shield") }.font(.subheadline).frame(minHeight: 44)
        }
    }
    private func coverage(_ aggregate: DashboardAggregate) -> String {
        if aggregate.currentCount == 0 { return "尚无当前数据；请检查连接后刷新。" }
        if aggregate.hasPartialCoverage { return "\(aggregate.currentCount) / \(aggregate.configuredCount) 个下载器已更新 · 仅合计这些服务" }
        return "\(aggregate.currentCount) / \(aggregate.configuredCount) 个下载器已更新 · 不含历史缓存"
    }
    private func symbol(_ filter: DashboardTaskFilter) -> String {
        switch filter {
        case .all: return "square.stack.3d.up"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "leaf"
        case .verifying: return "checkmark.shield"
        case .stopped: return "pause.circle"
        case .errors: return "exclamationmark.triangle"
        }
    }
}

private struct DashboardMetric: View {
    var title: String
    var value: String
    var symbol: String
    var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(DKTheme.muted)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DownloaderDashboardCard: View {
    @EnvironmentObject private var model: AppModel
    let kind: ServiceKind
    let snapshot: DashboardSnapshot?
    let now: Date
    let openTasks: () -> Void
    private var current: Bool { snapshot?.isFresh(now: now) == true }
    private var state: String {
        guard let snapshot else { return "待刷新" }
        if snapshot.error != nil { return "读取失败" }
        return current ? "已更新" : "数据已过期"
    }
    var body: some View {
        DKCard {
            Button(action: openTasks) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: kind.symbol).font(.title2).foregroundStyle(DKTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: model.profile(kind).displayName).font(.headline).foregroundStyle(DKTheme.text)
                        Text(LocalizedStringKey(kind.protocolKind.title)).font(.caption).foregroundStyle(DKTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DKTheme.muted)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityIdentifier("dashboard.server." + kind.rawValue)
            DKStatus(text: state, color: current ? DKTheme.green : DKTheme.amber)
            if let snapshot {
                if let error = snapshot.error { Text(error).font(.caption).foregroundStyle(DKTheme.amber) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { speedLabels(snapshot) }
                    VStack(alignment: .leading, spacing: 8) { speedLabels(snapshot) }
                }.font(.subheadline).monospacedDigit()
                if let counts = snapshot.counts {
                    Text("\(counts.total) 个任务 · \(counts.seeding) 做种 · \(counts.downloading) 下载\(current ? "" : "（上次数据）")").font(.caption).foregroundStyle(DKTheme.muted)
                }
                if let connectivity = snapshot.peerConnectivity {
                    Text(connectivity).font(.caption).foregroundStyle(connectivity == "入站已连接" ? DKTheme.muted : DKTheme.amber)
                }
                if snapshot.cumulativeUploaded != nil || snapshot.cumulativeDownloaded != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("客户端累计流量\(current ? "" : "（上次数据）")").font(.caption2).foregroundStyle(DKTheme.muted)
                        Text("↑ \(snapshot.cumulativeUploaded.map(Format.bytes) ?? "—")   ↓ \(snapshot.cumulativeDownloaded.map(Format.bytes) ?? "—")").font(.caption).foregroundStyle(DKTheme.muted).monospacedDigit()
                    }
                }
                ForEach(snapshot.warnings, id: \.self) { warning in Text(warning).font(.caption2).foregroundStyle(DKTheme.amber) }
                Text("读取于 \(snapshot.updatedAt.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(DKTheme.muted)
            } else {
                Text("等待读取真实流量与任务状态。").font(.caption).foregroundStyle(DKTheme.muted)
            }
        }
    }

    @ViewBuilder private func speedLabels(_ snapshot: DashboardSnapshot) -> some View {
        Label(current ? snapshot.downloadRate.map(Format.rate) ?? "—" : "—", systemImage: "arrow.down")
            .foregroundStyle(DKTheme.accent).fixedSize(horizontal: true, vertical: false)
        Label(current ? snapshot.uploadRate.map(Format.rate) ?? "—" : "—", systemImage: "arrow.up")
            .foregroundStyle(DKTheme.green).fixedSize(horizontal: true, vertical: false)
    }
}
