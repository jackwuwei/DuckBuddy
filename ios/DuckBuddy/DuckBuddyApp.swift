import SwiftUI

@main
struct DuckBuddyApp: App {
    @State private var model = AppModel(demo: ProcessInfo.processInfo.arguments.contains("-demo"))
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            AdaptiveRoot {
                RootView()
            }
            .environment(model)
            .id(model.lang) // 语言全局生效
            .onChange(of: phase) { _, p in
                // 后台立即关闭视频与控制通道，机器人"死人开关"约 0.6 s 内停下（PRD §6）。
                if p == .background { model.session.media.close() }
                if p == .active, model.session.linkState == .ready, let ip = model.session.mediaIP {
                    model.session.media.open(ip: ip, session: model.session)
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ConnectScreen()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .setup: SetupScreen()
                        case .drive: DriveScreen()
                        case .status: StatusScreen()
                        case .policy: PolicyScreen()
                        case .gamepad: GamepadScreen()
                        case .settings: SettingsScreen()
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden()
                }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast, model.path.last != .drive {
                Toast(text: toast.text, warn: toast.warn).padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
        .task { await debugRoute() }
    }

    /// 调试：演示模式下 `-route drive|status|policy|gamepad|settings|setup` 直接打开某页（截图对照设计稿用），
    /// `-colourway cream|graphite|lavender|sky` 选状态页 3D 配色。
    private func debugRoute() async {
        let args = ProcessInfo.processInfo.arguments
        guard model.session.isDemo, let i = args.firstIndex(of: "-route"), i + 1 < args.count else { return }
        let target = args[i + 1]
        if args.contains("-en") { model.lang = .en }
        if target == "setup" { model.path = [.setup]; return }
        await model.connectSelected()
        if args.contains("-started") { model.session.power = .stiff }
        if let j = args.firstIndex(of: "-colourway"), j + 1 < args.count { model.setColourway(colourwayFromKey(key: args[j + 1])) }
        let map: [String: Route] = ["status": .status, "policy": .policy, "gamepad": .gamepad, "settings": .settings]
        if let r = map[target] { model.path = [.drive, r] }
    }
}
