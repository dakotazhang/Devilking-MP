import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var filter = MPSubscriptionFilter.all

    private var filtered: [Subscription] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.subscriptions.filter {
            filter.includes($0.state) && (text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || $0.detail.localizedCaseInsensitiveContains(text))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !model.isConfigured(.moviepilot) {
                        DKCard { DKEmptyState(symbol: "bookmark", title: "连接后查看订阅", detail: "在设置中连接 MoviePilot，已订阅的电影和剧集会出现在这里。") }
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("我的追订").font(.title3.weight(.bold))
                                Text("已载入 \(model.subscriptions.count) 条 · 当前显示 \(filtered.count) 条")
                                    .font(.caption).foregroundStyle(DKTheme.muted)
                            }
                            Spacer()
                            Label(model.canManage(.moviepilot) ? "可管理" : "仅查看", systemImage: model.canManage(.moviepilot) ? "bookmark" : "lock")
                                .font(.caption).foregroundStyle(model.canManage(.moviepilot) ? DKTheme.green : DKTheme.amber)
                        }
                        Picker("订阅状态", selection: $filter) {
                            ForEach(MPSubscriptionFilter.allCases) { value in Text(value.title).tag(value) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("subscriptions.filter")
                        if filtered.isEmpty {
                            DKCard { DKEmptyState(symbol: "bookmark", title: model.busy ? "正在读取订阅" : "没有匹配的订阅", detail: "可以调整搜索和筛选条件，或到“发现”搜索并订阅新作品。") }
                        } else {
                            ForEach(filtered) { subscription in MPSubscriptionCard(subscription: subscription) }
                        }
                        DKServiceLink(kind: .moviepilot, title: "打开 MoviePilot 订阅管理").padding(.vertical, 8)
                    }
                }.padding(18)
            }
            .navigationTitle("订阅")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索已订阅作品")
            .refreshable { await reload() }
            .task { await reload() }
            .dkScreen()
        }
    }

    private func reload() async {
        guard model.isConfigured(.moviepilot) else { return }
        await model.loadMoviePilot()
    }
}

private struct MPSubscriptionCard: View {
    @EnvironmentObject private var model: AppModel
    let subscription: Subscription
    @State private var confirming = false
    @State private var submitting = false
    private var state: String { MPSubscriptionFilter.canonicalState(subscription.state) }
    private var paused: Bool { state == "S" }

    var body: some View {
        DKCard {
            HStack(alignment: .top, spacing: 14) {
                DKPoster(url: subscription.poster, width: 68, height: 100, allowRetry: true)
                VStack(alignment: .leading, spacing: 9) {
                    Text(subscription.title).font(.headline).lineLimit(2)
                        .accessibilityIdentifier("subscription.title." + subscription.id)
                    Text(subscription.detail).font(.caption).foregroundStyle(DKTheme.muted).lineLimit(2)
                    DKStatus(text: MPSubscriptionFilter.title(for: subscription.state), color: paused ? DKTheme.amber : DKTheme.accent)
                    if !subscription.progressKnown {
                        Text("进度待更新").font(.caption2).foregroundStyle(DKTheme.muted)
                    } else if subscription.progress > 0 {
                        ProgressView(value: min(1, max(0, subscription.progress))).tint(DKTheme.accent)
                        Text("\(Int(min(1, max(0, subscription.progress)) * 100))%")
                            .font(.caption2).foregroundStyle(DKTheme.muted).monospacedDigit()
                    } else {
                        Text("等待匹配与完成进度").font(.caption2).foregroundStyle(DKTheme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if ["R", "S", "P"].contains(state) {
                Button { confirming = true } label: {
                    Label(submitting ? "正在提交" : (paused ? "恢复订阅" : "暂停订阅"), systemImage: paused ? "play.circle" : "pause.circle")
                        .font(.subheadline.weight(.medium))
                }.disabled(!model.canManage(.moviepilot) || model.busy || submitting)
                    .accessibilityIdentifier("subscription.action." + subscription.id)
            }
        }
        .onChange(of: model.interactionEpoch) { _ in confirming = false }
        .alert(paused ? "恢复这个订阅？" : "暂停这个订阅？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("确认") {
                guard !submitting else { return }
                submitting = true
                Task {
                    await model.setSubscriptionState(subscription, paused: !paused)
                    submitting = false
                }
            }
        } message: {
            Text("\(subscription.title)\n只改变此订阅的自动调度状态。已经开始的搜索不会取消，失败不会自动重试。")
        }
    }
}
