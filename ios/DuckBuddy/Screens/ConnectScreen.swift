import SwiftUI

/// 连接页（设计稿 PortraitConnect / Connect）。
struct ConnectScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @State private var connecting = false

    var body: some View {
        Screen {
            switch layout {
            case .phonePortrait: portrait
            default: landscape
            }
        }
        .onAppear { model.session.startScan() }
    }

    // MARK: 竖屏：logo + 列表 + 底部主按钮

    private var portrait: some View {
        VStack(spacing: 16) {
            HStack { Spacer(); rescan }
            VStack(spacing: 10) {
                DuckImage().frame(width: 180, height: 107)
                Title(L("appName"), 34).foregroundStyle(Palette.text)
            }
            .padding(.top, 16).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.robots) { r in rowCard(r) }
                    addRow
                }
                .padding(.trailing, 4).padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            connectButton(height: 56, font: 22)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
    }

    // MARK: 横屏 / 宽屏：卡片横排居中

    private var landscape: some View {
        let wide = layout.isWide
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 22) {
                if wide {
                    VStack(spacing: 10) {
                        DuckImage().frame(width: 180, height: 107)
                        Title(L("appName"), 34)
                    }
                }
                // 放得下就居中（设计稿），放不下再横向滚动。
                let row = HStack(spacing: 16) {
                    ForEach(model.robots) { r in tallCard(r) }
                    addCard
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                ViewThatFits(in: .horizontal) {
                    row.padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) { row.padding(.horizontal, 20) }
                        .scrollBounceBehavior(.basedOnSize)
                }
                connectButton(height: 52, font: 20).fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            rescan.padding(.trailing, 16).padding(.top, 12)
        }
    }

    private var rescan: some View {
        CircleIconButton(icon: .rescan, label: L("rescan")) {
            model.session.stopScan()
            model.session.startScan()
            model.say(L("rescan"))
        }
    }

    // MARK: 卡片

    private func info(_ r: KnownRobot) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                IconView(.signal, size: 14, weight: 2.2)
                Text(r.lastIPv4 != nil ? L("linkWifi") : L("linkBle"))
            }
            HStack(spacing: 4) {
                BatteryGlyph(fraction: r.lastVolts.map { batteryFraction(volts: $0) } ?? 0)
                Text(r.lastVolts.map { "\(Int((batteryFraction(volts: $0) * 100).rounded()))%" } ?? "--")
            }
        }
        .font(Typo.body(12)).monospacedDigit()
        .foregroundStyle(Palette.light)
    }

    private func toggle(_ id: String) {
        model.selectedID = model.selectedID == id ? nil : id
    }

    private func rowCard(_ r: KnownRobot) -> some View {
        Button { toggle(r.id) } label: {
            HStack(spacing: 14) {
                DuckImage().frame(width: 56, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.displayName).font(Typo.body(16, weight: .bold)).lineLimit(1)
                    info(r)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.text)
            .padding(16)
            .background(Palette.card)
            .selectable(model.selectedID == r.id)
        }
        .pressable()
        .accessibilityAddTraits(.isButton)
    }

    private func tallCard(_ r: KnownRobot) -> some View {
        Button { toggle(r.id) } label: {
            VStack(spacing: 12) {
                DuckImage().frame(width: 110, height: 72)
                Title(r.displayName, 20).lineLimit(1)
                info(r)
            }
            .foregroundStyle(Palette.text)
            .padding(.vertical, 20).padding(.horizontal, 14)
            .frame(width: 200)
            .background(Palette.card)
            .selectable(model.selectedID == r.id)
        }
        .pressable()
    }

    private var addRow: some View {
        Button { model.path.append(.setup) } label: {
            HStack(spacing: 14) {
                IconView(.plus, size: 24).frame(width: 56, height: 40)
                Text(L("setupDuck")).font(Typo.body(15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Palette.light)
            .padding(16)
            .overlay(Rectangle().strokeBorder(Palette.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .pressable()
    }

    private var addCard: some View {
        Button { model.path.append(.setup) } label: {
            VStack(spacing: 12) {
                IconView(.plus, size: 28)
                    .foregroundStyle(Palette.text)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Palette.card))
                    .overlay(Circle().strokeBorder(Palette.hairline))
                Text(L("setupDuck")).font(Typo.body(15, weight: .semibold)).foregroundStyle(Palette.dim)
            }
            .padding(20)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .overlay(Rectangle().strokeBorder(Palette.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .pressable()
    }

    private func connectButton(height: CGFloat, font: CGFloat) -> some View {
        let can = model.selectedID != nil && !connecting
        return Button {
            connecting = true
            Task { await model.connectSelected(); connecting = false }
        } label: {
            Title(connecting ? L("connecting") : L("connect"), font, tracking: 0.04)
                .foregroundStyle(can ? Palette.bg : Palette.disabled)
                .padding(.horizontal, 44)
                .frame(maxWidth: layout == .phonePortrait ? .infinity : nil)
                .frame(height: height)
                .background(can ? Palette.orange : Palette.inset)
                .overlay(Rectangle().strokeBorder(Palette.bg, lineWidth: 2))
                .hardShadow(Palette.yellow)
        }
        .pressable()
        .disabled(!can)
    }
}
