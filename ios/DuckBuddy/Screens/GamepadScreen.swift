import SwiftUI

/// 手柄按键（设计稿 PortraitButtons / Mapping）：A B X Y LB RB 六个可绑定键，"—"为不绑定。
struct GamepadScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @State private var sel = "x"

    private let keys = ["a", "b", "x", "y", "lb", "rb"]
    private let colors: [String: Color] = ["a": Palette.cyan, "b": Palette.pink, "x": Palette.purple, "y": Palette.orange,
                                           "lb": .white, "rb": .white]
    private var session: RobotSession { model.session }

    var body: some View {
        Screen {
            VStack(spacing: layout == .phonePortrait ? 20 : 24) {
                TitleBar(title: L("padTitle"), back: { model.path.removeLast() }) {
                    SquareAction(icon: .reset, title: L("padReset")) {
                        Task {
                            for k in keys { await session.intent(.padBind(button: k, target: .default)) }
                            await reload()
                        }
                    }
                }
                Text(L("padHint")).font(Typo.body(13)).lineSpacing(3).foregroundStyle(Palette.dim)
                    .multilineTextAlignment(layout == .phonePortrait ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: layout == .phonePortrait ? .leading : .center)
                    .padding(.bottom, layout == .phonePortrait ? 0 : -12)
                if session.isRoller {
                    Text(L("padRollerNote")).font(Typo.body(12, weight: .bold)).foregroundStyle(Palette.yellow)
                }
                if layout == .phonePortrait {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(keys, id: \.self) { keyButton($0, height: 120, circle: 46) }
                    }
                } else {
                    HStack(spacing: 14) { ForEach(keys, id: \.self) { keyButton($0, height: 124, circle: 44).frame(maxWidth: 104 * (layout.isWide ? 1.4 : 1)) } }
                }
                ScrollView {
                    FlowLayout(spacing: 8, centered: layout != .phonePortrait) {
                        ForEach(choices, id: \.0) { value, label in
                            let on = binding(sel) == value
                            Button {
                                Task {
                                    await session.intent(.padBind(button: sel, target: value.isEmpty ? .off : .skill(name: value)))
                                    await reload()
                                }
                            } label: {
                                Text(label).font(Typo.body(layout == .phonePortrait ? 14 : 13, weight: .semibold))
                                    .foregroundStyle(on ? Palette.bg : Palette.light)
                                    .padding(.horizontal, layout == .phonePortrait ? 16 : 14)
                                    .frame(height: layout == .phonePortrait ? 40 : 36)
                                    .background(on ? Palette.orange : Palette.card)
                            }
                            .pressable()
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, layout == .phonePortrait ? 16 : 40).padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: 1000)
        }
        .task { await reload() }
    }

    private func reload() async {
        if let json = try? await session.call(.padBindings) { session.bindings = (try? decodePadBindings(json: json)) ?? session.bindings }
    }

    private func binding(_ key: String) -> String { session.bindings.first { $0.button == key }?.skill ?? "" }

    private func skillLabel(_ name: String) -> String {
        ["sit_toggle": L("slotSitstand"), "ground_pick": L("pickUp"), "kick_left": L("kickL"), "kick_right": L("kickR"),
         "roulade": L("roulade")][name] ?? name
    }

    /// 可选技能：机器人上的全部技能（含内置），"—"为不绑定。
    private var choices: [(String, String)] {
        [("", "—")] + session.skills.filter { !$0.disabled }.map { ($0.name, skillLabel($0.name)) }
    }

    private func keyButton(_ k: String, height: CGFloat, circle: CGFloat) -> some View {
        let on = sel == k
        let skill = binding(k)
        let dead = session.isRoller && (k == "a" || k == "x")
        return Button { sel = k } label: {
            VStack(spacing: 12) {
                Text(k.uppercased()).font(Typo.body(15, weight: .bold))
                    .foregroundStyle(colors[k] ?? .white)
                    .frame(width: circle, height: circle)
                    .overlay(Circle().strokeBorder(colors[k] ?? .white, lineWidth: 2))
                Text(skill.isEmpty ? "—" : skillLabel(skill)).font(Typo.body(13, weight: .semibold))
                    .foregroundStyle(skill.isEmpty ? Palette.disabled : Palette.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Palette.card)
            .overlay(Rectangle().strokeBorder(on ? Palette.orange : .clear, lineWidth: 2))
            .opacity(dead ? 0.45 : 1)
        }
        .pressable()
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// 换行排列（设计稿 flex-wrap）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = centered ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + s.width > width { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
