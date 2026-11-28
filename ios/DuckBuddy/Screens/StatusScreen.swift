import SwiftUI

/// 状态页（设计稿 PortraitStatus / Telemetry）：3D 姿态、站姿、电池 / 舵机 / 主控温度、风扇、15 个舵机偏差。
struct StatusScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @State private var degrees = true
    @State private var sim = DuckViewer.Renderer.LoadState.loading
    @State private var resetToken = 0
    @State private var rebooting = false

    private var session: RobotSession { model.session }

    var body: some View {
        Screen {
            VStack(spacing: 10) {
                TitleBar(title: L("statusTitle"), back: { model.path.removeLast() }) {
                    Button { model.path.append(.settings) } label: {
                        IconView(.gear, size: 18).foregroundStyle(Palette.text)
                            .frame(width: 36, height: 36).card()
                    }
                    .pressable()
                    .accessibilityLabel(L("settings"))
                    SquareAction(icon: .reset, title: L("rebootServos"), enabled: !rebooting) {
                        Task {
                            rebooting = true
                            if let r = await session.intent(.robotRebootMotors(ids: Data())) { model.say(r, warn: true) }
                            else { model.say(L("rebooted")) }
                            rebooting = false
                        }
                    }
                }
                switch layout {
                case .phonePortrait:
                    viewer.frame(height: 420)
                    stats(height: 60)
                    joints
                default:
                    TwoPane(primaryFraction: layout == .phoneLandscape ? 0.47 : 0.5) {
                        viewer
                    } secondary: {
                        VStack(spacing: 8) {
                            stats(height: layout == .phoneLandscape ? 50 : 60)
                            joints
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        }
        .task {
            await session.refreshSystemInfo()
            await session.refreshHealth()
            await session.refreshFan()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await session.refreshHealth()
                await session.refreshFan()
            }
        }
    }

    // MARK: 3D + 站姿

    private var postureInfo: (String, Color, String, String) {
        guard let p = session.state?.posture else { return ("—", Palette.dim, L("noStream"), "") }
        let nums = L("pNums", p.posture == .lying ? "—" : "\(Int((p.heightRatio * 100).rounded()))%", Int(p.tiltDeg.rounded()))
        switch p.posture {
        case .standing: return (L("pStanding"), Palette.cyan, L("nStanding"), nums)
        case .seated: return (L("pSeated"), Palette.purple, L("nSeated"), nums)
        case .lying: return (L("pLying"), Palette.pink, L("nLying"), nums)
        case .unsure: return (L("pUnsure"), Palette.yellow, L("nUnsure"), nums)
        }
    }

    private var viewer: some View {
        let (label, color, note, nums) = postureInfo
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Title(label, 22).foregroundStyle(color).accessibilityLabel(L("posture") + " " + label)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nums).font(Typo.body(11)).monospacedDigit().foregroundStyle(Palette.light).lineLimit(1)
                    Text(note).font(Typo.body(10)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let boot = session.bootedAt {
                    TimelineView(.periodic(from: .now, by: 10)) { ctx in
                        let text = Self.uptimeText(Int(ctx.date.timeIntervalSince(boot)))
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(text).font(Typo.body(13, weight: .bold)).monospacedDigit().foregroundStyle(Palette.light).lineLimit(1)
                            Text(L("uptime")).font(Typo.body(10)).foregroundStyle(Palette.dim).lineLimit(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("uptime") + " " + text)
                    }
                }
                Button { resetToken += 1 } label: {
                    IconView(.resetView, size: 16).foregroundStyle(Palette.light)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                }
                .pressable()
                .accessibilityLabel(L("resetView"))
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
            ZStack {
                DuckViewer(joints: session.state?.joints ?? DemoRobot.home, quat: session.state?.quat,
                           colourway: model.colourway, resetToken: $resetToken) { s in sim = s }
                    .accessibilityLabel(L("simHint"))
                if sim != .ready {
                    Text(sim == .failed ? L("simFail") : L("simLoading"))
                        .font(Typo.body(12, weight: .semibold))
                        .foregroundStyle(sim == .failed ? Palette.pink : Palette.dim)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) { if sim == .ready { colourwayPicker } }
        }
        .background(Palette.panel)
        .overlay(Rectangle().strokeBorder(Palette.hairline))
    }

    /// 官方四种配色（与官网色块一致），选了只改 3D 模型的外壳颜色，按机器人记住。
    private var colourwayPicker: some View {
        HStack(spacing: 2) {
            ForEach(colourwayAll(), id: \.self) { c in
                let on = model.colourway == c
                Button { model.setColourway(c) } label: {
                    Rectangle().fill(Color(hex: colourwaySwatch(colourway: c)))
                        .frame(width: 22, height: 22)
                        .overlay(Rectangle().strokeBorder(Palette.bg, lineWidth: 2))
                        .selectable(on)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("colourway") + " " + L(Self.colourwayName(c)))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.leading, 4).padding(.bottom, 2)
    }

    /// 运行时长，只到分钟：`3 天 4 小时` / `1 小时 28 分` / `28 分钟`。
    static func uptimeText(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 86400 { return L("uptimeD", s / 86400, s / 3600 % 24) }
        if s >= 3600 { return L("uptimeH", s / 3600, s / 60 % 60) }
        return L("uptimeM", s / 60)
    }

    static func colourwayName(_ c: Colourway) -> String {
        switch c {
        case .cream: "cwCream"
        case .graphite: "cwGraphite"
        case .lavender: "cwLavender"
        case .sky: "cwSky"
        }
    }

    // MARK: 电池 / 舵机最高 / 主控 / 风扇

    private func stats(height: CGFloat) -> some View {
        let h = session.health
        let volts = h?.batteryVolts.map { String(format: "%.1f V", $0) } ?? "-- V"
        let battery = stat(icon: nil, value: session.batteryPercentText, unit: " %", label: L("battery") + " · " + volts, height: height)
        let servo = stat(icon: .temp, value: h?.motorMaxC.map { String(format: "%.0f", $0) } ?? "--", unit: " °C", label: L("servoMax"), height: height)
        let board = stat(icon: .chip, value: h?.cpuTempC.map { String(format: "%.0f", $0) } ?? "--", unit: " °C", label: L("board"), height: height)
        // 有风扇时 2×2；没装 fanstat 的鸭子保持原来的一行三格。
        return Group {
            if let fan = session.fan {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { battery; servo }
                    GridRow { board; fanStat(fan, height: height) }
                }
            } else {
                HStack(spacing: 8) { battery; servo; board }
            }
        }
    }

    private func fanStat(_ f: FanTile, height: CGFloat) -> some View {
        let pct = f.pct.map(String.init) ?? "--"
        let label = f.manual ? L("fanManual", pct) : L("fanPct", pct)
        if let rpm = f.rpm {
            return stat(icon: .fan, value: String(rpm), unit: " rpm", label: label, height: height)
        }
        return stat(icon: .fan, value: pct, unit: " %", label: L("fan"), height: height)
    }

    private func stat(icon: Icon?, value: String, unit: String, label: String, height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon { IconView(icon, size: 18, weight: 2) } else { BatteryGlyph(fraction: session.batteryFraction) }
            }
            .foregroundStyle(Palette.text)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Palette.inset))
            VStack(alignment: .leading, spacing: 0) {
                (Text(value).font(Typo.title(22)) + Text(unit).font(Typo.body(12)).foregroundColor(Palette.dim))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(Typo.body(11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: 舵机位置

    private var joints: some View {
        let names = [["jHipYaw", "jHipRoll", "jHipPitch", "jKnee", "jAnkle"],
                     ["jNeckPitch", "jHeadPitch", "jHeadYaw", "jHeadRoll", "jMouth"]]
        let ids = Array(jointIds())
        let groups: [(String, Icon, Int, [String])] = [(L("gLeft"), .foot, 0, names[0]), (L("gHead"), .headSmall, 5, names[1]),
                                                       (L("gRight"), .foot, 10, names[0])]
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Title(L("joints"), 16)
                Text(L("legend")).font(Typo.body(10.5)).foregroundStyle(Palette.dim).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    unitButton("°", on: degrees) { degrees = true }
                    unitButton("rad", on: !degrees) { degrees = false }
                }
                .padding(2).background(Palette.bg).overlay(Rectangle().strokeBorder(Color.white.opacity(0.12)))
            }
            ScrollView {
                let columns = layout == .expanded ? [GridItem(.flexible(), spacing: 16), GridItem(.flexible())] : [GridItem(.flexible())]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.0) { name, icon, base, keys in
                        VStack(spacing: 0) {
                            HStack(spacing: 6) { IconView(icon, size: 14); Text(name) }
                                .font(Typo.body(11, weight: .bold)).foregroundStyle(Palette.dim)
                                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                            ForEach(0..<5, id: \.self) { k in jointRow(index: base + k, id: ids[base + k], name: L(keys[k])) }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .card()
    }

    private func unitButton(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Typo.body(12, weight: .bold))
                .foregroundStyle(on ? Palette.bg : Palette.light)
                .frame(minWidth: 34, minHeight: 26)
                .background(on ? Palette.orange : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func jointRow(index: Int, id: UInt8, name: String) -> some View {
        let state = session.state
        let meas = state?.joints[safe: index]
        let cmd = state?.targets[safe: index]
        let errDeg = (meas != nil && cmd != nil) ? (meas! - cmd!) * 180 / .pi : 0
        let frac = max(-1, min(1, errDeg / 5))
        let level = (meas != nil && cmd != nil) ? deviationLevel(measuredRad: meas!, commandedRad: cmd!) : .fine
        let color: Color = switch level { case .fine: Palette.muted; case .warn: Palette.yellow; case .bad: Palette.pink }
        let fmt = { (r: Double) in degrees ? String(format: "%.1f°", r * 180 / .pi) : String(format: "%.3f", r) }
        return HStack(spacing: 8) {
            Text("\(id)").font(Typo.body(10)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 18, alignment: .leading)
            Text(name).font(Typo.body(12.5)).foregroundStyle(Palette.light).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.inset).frame(height: 4)
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 8).offset(x: 35.5)
                Rectangle().fill(color)
                    .frame(width: max(1.5, abs(frac) * 50) / 100 * 72, height: 4)
                    .offset(x: (frac < 0 ? 50 + frac * 50 : 50) / 100 * 72)
            }
            .frame(width: 72, height: 8)
            Text(meas.map(fmt) ?? "--").font(Typo.body(14, weight: .bold)).monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(meas.map(fmt) ?? "--")")
        .accessibilityHint(cmd.map { "\(L("cmd")) \(fmt($0)) · \(L("err")) \(String(format: "%.1f°", errDeg))" } ?? "")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
