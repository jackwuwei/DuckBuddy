import SwiftUI

/// 布局类别：只看**当前窗口的实际尺寸**，不看设备型号。
///
/// 这样同一套规则覆盖：
/// - iPhone 竖 / 横屏；
/// - **iPhone Duo**：合上时外屏（5.4"）是普通竖屏手机 → `phonePortrait`；展开后内屏（7.6"）接近正方形 →
///   `dual`。折叠 / 展开时系统只会改变窗口尺寸，界面状态全部保存在模型里，切换后无缝继续（驾驶中不断连）；
/// - **iPad**：全屏、Split View、Slide Over、台前调度任意窗口大小，窄窗口自动退回手机布局。
enum LayoutClass: Equatable {
    /// 窄竖屏：iPhone 竖屏、Duo 外屏、iPad 窄分屏。
    case phonePortrait
    /// 矮横屏：iPhone 横屏（高 < 500）。
    case phoneLandscape
    /// 接近正方形的大屏：Duo 展开、iPad 竖屏分屏一半。两栏等分，正好避开中间折痕。
    case dual
    /// 宽大屏：iPad 全屏 / 宽窗口。
    case expanded

    static func of(_ size: CGSize) -> LayoutClass {
        let (w, h) = (size.width, size.height)
        guard w > 0, h > 0 else { return .phonePortrait }
        if w < 600 { return h < 500 && w > h ? .phoneLandscape : .phonePortrait }
        if h < 500 { return .phoneLandscape }
        let aspect = w / h
        if aspect < 1.3 { return .dual }
        return .expanded
    }

    var isWide: Bool { self == .dual || self == .expanded }
    var gutter: CGFloat { isWide ? 24 : 16 }
}

private struct LayoutClassKey: EnvironmentKey { static let defaultValue = LayoutClass.phonePortrait }
private struct WindowSizeKey: EnvironmentKey { static let defaultValue = CGSize(width: 390, height: 844) }

extension EnvironmentValues {
    var layoutClass: LayoutClass {
        get { self[LayoutClassKey.self] }
        set { self[LayoutClassKey.self] = newValue }
    }
    var windowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}

/// 根视图包一层：测量窗口并把布局类别放进环境。折叠 / 展开 / 分屏改变尺寸时自动刷新。
struct AdaptiveRoot<Content: View>: View {
    @ViewBuilder var content: () -> Content

    /// 调试：`-simulateWindow 820x904` 把界面限制在指定窗口大小里（模拟 iPhone Duo 内屏 / 外屏、分屏宽度），
    /// 用于没有对应模拟器时检查布局。
    private var simulated: CGSize? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-simulateWindow"), i + 1 < args.count else { return nil }
        let p = args[i + 1].split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }

    var body: some View {
        if let s = simulated {
            ZStack {
                Color.gray.opacity(0.25).ignoresSafeArea()
                measured
                    .frame(width: s.width, height: s.height)
                    .clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.4)))
            }
        } else {
            measured
        }
    }

    private var measured: some View {
        GeometryReader { geo in
            let size = CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                              height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            content()
                .environment(\.layoutClass, LayoutClass.of(size))
                .environment(\.windowSize, size)
                .animation(.easeInOut(duration: 0.25), value: LayoutClass.of(size))
        }
    }
}

/// 两栏：宽布局时左右并排（`dual` 等分，正好落在 Duo 折痕两侧），窄布局时上下堆叠。
struct TwoPane<Primary: View, Secondary: View>: View {
    @Environment(\.layoutClass) private var layout
    /// `expanded` 时主栏占比。
    var primaryFraction: CGFloat = 0.58
    /// 窄布局时是否把副栏放进滚动区（页面通常自己滚动）。
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        switch layout {
        case .dual, .expanded:
            GeometryReader { geo in
                let fraction = layout == .dual ? 0.5 : primaryFraction
                let hinge: CGFloat = layout == .dual ? 24 : 20
                HStack(spacing: hinge) {
                    primary().frame(width: (geo.size.width - hinge) * fraction)
                    secondary().frame(maxWidth: .infinity)
                }
            }
        case .phoneLandscape:
            HStack(spacing: 16) {
                primary().frame(maxWidth: .infinity)
                secondary().frame(maxWidth: .infinity)
            }
        case .phonePortrait:
            VStack(spacing: 16) {
                primary()
                secondary()
            }
        }
    }
}

/// 网格列数随宽度变化（卡片列表、Wi-Fi 列表、策略槽位）。
func adaptiveColumns(_ layout: LayoutClass, minimum: CGFloat = 160) -> [GridItem] {
    switch layout {
    case .phonePortrait: [GridItem(.adaptive(minimum: minimum), spacing: 14)]
    case .phoneLandscape: [GridItem(.adaptive(minimum: minimum), spacing: 14)]
    case .dual, .expanded: [GridItem(.adaptive(minimum: minimum + 40), spacing: 18)]
    }
}
