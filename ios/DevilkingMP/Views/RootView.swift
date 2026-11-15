import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    @State private var selectedTab = 0
    @State private var selectedDownloader: ServiceKind? = nil
    @State private var downloaderFilter: DashboardTaskFilter = .all

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                OverviewView(openSettings: { selectedTab = 4 }, openDownloaders: { kind, filter in
                    selectedDownloader = kind
                    downloaderFilter = filter
                    selectedTab = 1
                })
                    .environment(\.dkPageCharacter, .rem)
                    .tabItem { Label("状态表", systemImage: "chart.bar.fill") }.tag(0)
                DownloadersView(selectedKind: $selectedDownloader, filter: $downloaderFilter)
                    .environment(\.dkPageCharacter, .emilia)
                    .tabItem { Label("下载器", systemImage: "arrow.up.arrow.down") }.tag(1)
                MoviePilotView()
                    .environment(\.dkPageCharacter, .ram)
                    .tabItem { Label("发现", systemImage: "sparkles.tv") }.tag(2)
                SubscriptionsView()
                    .environment(\.dkPageCharacter, .beatrice)
                    .tabItem { Label("订阅", systemImage: "bookmark") }.tag(3)
                SettingsView()
                    .environment(\.dkPageCharacter, .echidna)
                    .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(4)
            }
            .tint(DKTheme.accent)
            .blur(radius: model.locked ? 18 : 0)
            .disabled(model.locked)
            .accessibilityHidden(model.locked)

            if model.locked { lockScreen }
        }
        .preferredColorScheme(preferences.theme.colorScheme)
        .alert("操作结果", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(LocalizedStringKey(model.message ?? "")) }
        .environment(\.locale, preferences.language.locale)
        .environment(\.dynamicTypeSize, preferences.fontSize.dynamicTypeSize(system: systemTypeSize))
    }

    private var lockScreen: some View {
        ZStack {
            DKTheme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield").font(.system(size: 54, weight: .light)).foregroundStyle(DKTheme.accent)
                Text("服务连接已锁定").font(.title2.weight(.bold))
                Text("验证身份后继续查看与管理。")
                    .font(.subheadline).foregroundStyle(DKTheme.muted)
                Button { Task { await model.unlock() } } label: {
                    Label("验证并解锁", systemImage: "faceid").font(.headline).padding(.horizontal, 20).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent)
            }.padding(28)
        }
    }
}
