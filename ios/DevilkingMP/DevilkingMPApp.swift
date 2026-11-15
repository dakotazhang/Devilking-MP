import SwiftUI

@main
@MainActor
struct DevilkingMPApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(model)
                    .environmentObject(model.preferences)
                    .accessibilityHidden(scenePhase != .active)

                // Cover the app switcher snapshot without relocking on a Face ID
                // prompt's temporary inactive state. Only background locks it.
                if scenePhase != .active {
                    privacyCover
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .task {
                guard !started else { return }
                started = true
                guard !model.locked else { return }
                await model.refreshAll()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    model.protectOnBackground()
                } else if phase == .active, started, !model.locked {
                    Task { await model.refreshAll() }
                }
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                guard !model.locked else {
                    model.message = "请先解锁应用，再打开连接配置文件。"
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try model.importProfile(url)
                } catch {
                    model.message = AppModel.safeError(error)
                }
            }
        }
    }

    private var privacyCover: some View {
        ZStack {
            Color(red: 0.035, green: 0.06, blue: 0.105)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(Color(red: 0.57, green: 0.81, blue: 0.96))
                Text("Devilking MP管理")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
        .accessibilityLabel("家庭媒体管理内容已隐藏")
    }
}
