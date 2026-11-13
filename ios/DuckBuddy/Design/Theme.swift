import SwiftUI

/// 设计 Token，数值逐一取自设计画布（与 Android `design/Theme.kt` 一一对应）。
enum Palette {
    static let bg = Color(hex: 0x08080C)
    static let card = Color(hex: 0x101018)
    static let inset = Color(hex: 0x1D1D29)
    static let orange = Color(hex: 0xFF7A2F)
    static let yellow = Color(hex: 0xFFD23F)
    static let pink = Color(hex: 0xFF2FA8)
    static let cyan = Color(hex: 0x2FF0E6)
    static let purple = Color(hex: 0x9D87E8)
    static let text = Color.white
    /// 浅色正文 / 次要文字 / 说明 / 不可用（#dcd7cc / #a19fa9 / #8e8c96 / #6e6c78）
    static let light = Color(hex: 0xDCD7CC)
    static let dim = Color(hex: 0xA19FA9)
    static let muted = Color(hex: 0x8E8C96)
    static let disabled = Color(hex: 0x6E6C78)
    /// 细边 rgba(255,255,255,.09)、输入框边 .22、虚线 .35
    static let hairline = Color.white.opacity(0.09)
    static let field = Color.white.opacity(0.22)
    static let dashed = Color.white.opacity(0.35)
    /// 视频框 / 3D 区域 / 摇杆 / 搜索结果底色
    static let video = Color(hex: 0x13131B)
    static let panel = Color(hex: 0x0D0D14)
    static let stick = Color(hex: 0x111119)
    static let result = Color(hex: 0x15151F)

    /// 策略来源色点：官方橙、社区紫、本地浅色。
    static func origin(_ o: Origin?) -> Color {
        switch o {
        case .official: orange
        case .community: purple
        case .local: light
        default: disabled
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 字体：标题 Anton 全大写（中文由系统黑体最粗字重回退），正文 DM Sans。字体随 App 打包（app/shared/fonts）。
enum Typo {
    static func title(_ size: CGFloat) -> Font { .custom("Anton", size: size).weight(.black) }
    static func body(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .custom("DM Sans", size: size).weight(weight)
    }
}

/// Anton 标题：拉丁字符用 Anton 全大写，中文用系统黑体最粗字重（设计稿 `Anton, 'Noto Sans SC'` 900，
/// 禁止合成粗体），字距 0.02em。
func Title(_ s: String, _ size: CGFloat, tracking: CGFloat = 0.02) -> Text {
    var out = Text("")
    var run = ""
    var cjk: Bool?
    func flush() {
        guard !run.isEmpty, let c = cjk else { return }
        let t = c ? Text(run).font(.system(size: size * 0.92, weight: .black))
                  : Text(run.uppercased()).font(.custom("Anton", size: size))
        out = out + t.tracking(size * tracking)
        run = ""
    }
    for ch in s {
        let isCJK = ch.unicodeScalars.contains { $0.value >= 0x2E80 }
        if cjk != isCJK { flush(); cjk = isCJK }
        run.append(ch)
    }
    flush()
    return out
}

// MARK: - 硬投影 / 选中态 / 卡片

/// 原型中的 `box-shadow: 4px 4px 0`：内容下方偏移 (4,4) 画实色矩形，无模糊。
struct HardShadow: ViewModifier {
    var color: Color
    var offset: CGFloat = 4
    func body(content: Content) -> some View {
        content.background(alignment: .topLeading) {
            GeometryReader { g in
                Rectangle().fill(color).frame(width: g.size.width, height: g.size.height).offset(x: offset, y: offset)
            }
        }
    }
}

extension View {
    func hardShadow(_ color: Color, offset: CGFloat = 4) -> some View { modifier(HardShadow(color: color, offset: offset)) }

    /// 统一选中态：2pt 橙描边 + 4pt 橙硬投影；未选中为透明 2pt 边（不跳动）。
    func selectable(_ selected: Bool) -> some View {
        self.overlay(Rectangle().strokeBorder(selected ? Palette.orange : .clear, lineWidth: 2))
            .hardShadow(selected ? Palette.orange : .clear)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 卡片：#101018 + 1px 细边，直角。
    func card(_ fill: Color = Palette.card) -> some View {
        self.background(fill).overlay(Rectangle().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    /// 按下时向右下平移 2pt（设计稿 `button:active{transform:translate(2px,2px)}`）。
    func pressable() -> some View { buttonStyle(PressStyle()) }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
    }
}

// MARK: - 组件

/// 主按钮：橙底、2px 黑描边、4px 黄硬投影、Anton；不可用时 #1d1d29 底、灰字、无投影。
struct PrimaryButton: View {
    let title: String
    var enabled = true
    var height: CGFloat = 50
    var fontSize: CGFloat = 18
    /// 加载进度（0…1），叠一层半透明白条。
    var progress: Double? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if let progress {
                    GeometryReader { g in Rectangle().fill(.white.opacity(0.35)).frame(width: g.size.width * progress) }
                }
                Title(title, fontSize).frame(maxWidth: .infinity)
            }
            .foregroundStyle(enabled ? Palette.bg : Palette.disabled)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(enabled ? Palette.orange : Palette.inset)
            .overlay(Rectangle().strokeBorder(enabled ? Palette.bg : .clear, lineWidth: 2))
            .hardShadow(enabled ? Palette.yellow : .clear)
        }
        .pressable()
        .disabled(!enabled)
    }
}

/// 36pt 圆形图标按钮（返回、重新扫描、策略…）。
struct CircleIconButton: View {
    let icon: Icon
    let label: String
    var tint: Color = Palette.text
    var size: CGFloat = 36
    var fill: Color = Palette.card
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            IconView(icon, size: size * 0.5, weight: icon == .back ? 2.2 : 1.9)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(Palette.hairline))
                .contentShape(Circle())
        }
        .pressable()
        .accessibilityLabel(label)
    }
}

/// 标题栏右侧方形操作：36 高，图标 + 12pt 粗体字。
struct SquareAction: View {
    let icon: Icon
    let title: String
    var tint: Color = Palette.text
    var fill: Color = Palette.card
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IconView(icon, size: 18)
                Text(title).font(Typo.body(12, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 36)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Palette.hairline))
        }
        .pressable()
        .disabled(!enabled)
    }
}

/// 统一标题栏：左 36pt 圆形返回、Anton 标题（竖屏 26 / 横屏 24）、右侧操作。
struct TitleBar<Trailing: View>: View {
    @Environment(\.layoutClass) private var layout
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let back { CircleIconButton(icon: .back, label: L("back"), action: back) }
            Title(title, layout == .phoneLandscape ? 24 : 26).foregroundStyle(Palette.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(height: 36)
    }
}

extension TitleBar where Trailing == EmptyView {
    init(title: String, back: (() -> Void)?) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// 一组选项（radio 语义）：34 高、2pt 选中描边 + 硬投影。
struct ChoiceChips<T: Hashable>: View {
    let options: [(T, String, Icon?)]
    @Binding var selection: T
    var badge: ((T) -> Bool)? = nil
    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { value, label, icon in
                let on = selection == value
                Button { selection = value } label: {
                    HStack(spacing: 6) {
                        if let icon { IconView(icon, size: 16) }
                        Text(label).font(Typo.body(13, weight: .bold))
                        if badge?(value) == true { Dot(color: Palette.pink, size: 7) }
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(on ? Palette.inset : Palette.card)
                    .selectable(on)
                }
                .pressable()
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}

/// 页面底色。
struct Screen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            content()
        }
        .preferredColorScheme(.dark)
        .tint(Palette.orange)
    }
}

/// 输入框：#08080c 底、.22 边（出错时粉），左侧图标，可选右侧按钮。
struct FieldBox<Content: View>: View {
    var icon: Icon? = nil
    var error = false
    var height: CGFloat = 44
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) {
            if let icon { IconView(icon, size: 18).foregroundStyle(Palette.dim) }
            content()
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: height)
        .background(Palette.bg)
        .overlay(Rectangle().strokeBorder(error ? Palette.pink : Palette.field, lineWidth: 1))
    }
}

/// 密码 / 密钥输入（可显示明文）。
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var shown: Bool
    var mono = false
    var body: some View {
        Group {
            if shown { TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.disabled)) }
            else { SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.disabled)) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(mono ? .system(size: 13, design: .monospaced) : Typo.body(14))
        .foregroundStyle(Palette.text)
        Button { shown.toggle() } label: {
            IconView(shown ? .eyeOff : .eye, size: 18).foregroundStyle(Palette.dim).frame(width: 36, height: 36)
        }
        .accessibilityLabel(L("showPw"))
    }
}

/// 小节标题：11pt 粗体、#a19fa9、字距 0.04em。
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(Typo.body(11, weight: .bold)).tracking(0.44).foregroundStyle(Palette.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 信号格（3 格，4pt 宽，高 7/10/13）。
struct SignalBars: View {
    let level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { b in
                Rectangle().fill(b <= level ? Palette.cyan : Color.white.opacity(0.18)).frame(width: 4, height: CGFloat(4 + b * 3))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityLabel(L(["sigWeak", "sigWeak", "sigFair", "sigStrong"][min(3, max(0, level))]))
    }
}

/// 电池图标（设计稿 26×16 视窗，青色填充按电量）。
struct BatteryGlyph: View {
    var fraction: Double
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 26
            ctx.stroke(Path(roundedRect: CGRect(x: 1 * s, y: 2 * s, width: 21 * s, height: 12 * s), cornerRadius: 3 * s),
                       with: .foreground, lineWidth: 1.6 * s)
            var tip = Path(); tip.move(to: CGPoint(x: 24.5 * s, y: 6 * s)); tip.addLine(to: CGPoint(x: 24.5 * s, y: 10 * s))
            ctx.stroke(tip, with: .foreground, style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
            let w = max(0, min(1, fraction)) * 16
            if w > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: 3.5 * s, y: 4.5 * s, width: w * s, height: 7 * s), cornerRadius: 1.5 * s),
                         with: .color(Palette.cyan))
            }
        }
        .frame(width: 20, height: 14)
        .accessibilityHidden(true)
    }
}

/// 鸭子图（闭嘴 / 张嘴）。
struct DuckImage: View {
    var quacking = false
    var body: some View {
        Image(quacking ? "duck_quack" : "duck").resizable().scaledToFit().accessibilityHidden(true)
    }
}

/// 轻提示（底部状态行 / 视频框内提示用各自样式，这个用于全局）。
struct Toast: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text).font(Typo.body(12, weight: .semibold)).multilineTextAlignment(.center)
            .foregroundStyle(warn ? Palette.yellow : Palette.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.bg.opacity(0.78))
            .transition(.opacity)
    }
}
