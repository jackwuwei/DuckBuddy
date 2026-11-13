import SwiftUI

/// 虚拟摇杆：圆盘 + 旋钮，归一化到 [-1, 1]（x 向右、y 向下），死区由 duck-core 处理。
struct Joystick: View {
    let diameter: CGFloat
    let knob: CGFloat
    var fill: Color = Palette.stick
    var border: Color = Color.white.opacity(0.18)
    let label: String
    @Binding var value: CGPoint
    @State private var active = false

    var body: some View {
        let r = diameter / 2
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(border, lineWidth: 1.5)
            Circle().fill(Color.white.opacity(active ? 0.95 : 0.75))
                .frame(width: knob, height: knob)
                .offset(x: value.x * (r - knob / 2), y: value.y * (r - knob / 2))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    active = true
                    var x = (g.location.x - r) / r, y = (g.location.y - r) / r
                    let m = hypot(x, y)
                    if m > 1 { x /= m; y /= m }
                    value = CGPoint(x: x, y: y)
                }
                .onEnded { _ in active = false; value = .zero }
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "x %.2f, y %.2f", value.x, value.y))
    }
}

/// 长按环：按住计时、显示环形进度，松手回调持续秒数。
struct HoldGesture: ViewModifier {
    @Binding var held: Double
    var onDown: () -> Void = {}
    let onRelease: (Double) -> Void
    @State private var start: Date?
    @State private var timer: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard start == nil else { return }
                    let t0 = Date()
                    start = t0
                    onDown()
                    timer = Task { @MainActor in
                        while !Task.isCancelled {
                            held = Date().timeIntervalSince(t0)
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                    }
                }
                .onEnded { _ in
                    timer?.cancel()
                    let d = start.map { Date().timeIntervalSince($0) } ?? 0
                    start = nil
                    held = 0
                    onRelease(d)
                }
        )
    }
}

extension View {
    func onHold(_ held: Binding<Double>, down: @escaping () -> Void = {}, release: @escaping (Double) -> Void) -> some View {
        modifier(HoldGesture(held: held, onDown: down, onRelease: release))
    }

    /// 按下 / 抬起（设计稿的 pointerdown / pointerup 语义）。
    func onPress(down: @escaping () -> Void, up: @escaping () -> Void = {}) -> some View {
        modifier(PressGesture(down: down, up: up))
    }
}

private struct PressGesture: ViewModifier {
    let down: () -> Void
    let up: () -> Void
    @State private var pressed = false
    func body(content: Content) -> some View {
        content
            .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; down() } }
                .onEnded { _ in pressed = false; up() })
    }
}

/// 环形进度（从 12 点顺时针）。
struct Ring: View {
    var progress: Double
    var color: Color
    var track: Color = .clear
    var width: CGFloat = 3
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// 准星（28pt，四条 2pt 短线）。
struct Reticle: View {
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 2, height: 8)
                    .offset(y: -10).rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
