import SwiftUI

/// 驾驶页（设计稿 PortraitDrive 390×844 / Main 844×390）。
///
/// 手机上按设计稿坐标等比放置；iPad 和 iPhone Duo 展开时沿用横屏结构：两手拇指位（摇杆、模式列、动作列）
/// 贴住左右外缘，视频居中；语音键和启动键放在中线两侧，不压在 Duo 的折痕上。
/// 折叠 / 展开 / 分屏只改变布局，`DriveController` 与连接状态保持，驾驶不中断。
struct DriveScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @State private var ctl: DriveController?
    @State private var voice: VoiceController?

    private var keepAwake: Bool { (ctl?.camOn ?? false) && model.session.media.videoLive }

    var body: some View {
        // 安全区要在 ignoresSafeArea 之外读：内层铺满全屏后，它自己的 safeAreaInsets 恒为 0，
        // 刘海 / 灵动岛 / Home 条就躲不开了。
        GeometryReader { outer in
            Group {
                if let ctl, let voice {
                    DriveCanvas(ctl: ctl, voice: voice, inset: outer.safeAreaInsets)
                } else {
                    Palette.bg
                }
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if ctl == nil {
                let c = DriveController(model: model)
                ctl = c
                voice = VoiceController(model: model) { [weak c] text, warn in c?.say(text, warn: warn) }
            }
            ctl?.startLoop()
            if let ip = model.session.mediaIP, !model.session.media.isOpen { model.session.media.open(ip: ip, session: model.session) }
        }
        .onDisappear { ctl?.stopLoop(); UIApplication.shared.isIdleTimerDisabled = false }
        // 看着画面开车时不熄屏；关了相机或没出帧就交还给系统。
        .onChange(of: keepAwake, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .alert(L("voiceConsentTitle"), isPresented: Binding(get: { voice?.showConsent ?? false }, set: { voice?.showConsent = $0 })) {
            Button(L("agree")) { model.voiceConsent = true }
            Button(L("notNow"), role: .cancel) {}
        } message: { Text(L("voiceConsent")) }
    }
}

private struct DriveCanvas: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    let ctl: DriveController
    let voice: VoiceController
    /// 窗口的安全区（刘海、灵动岛、Home 条），由外层在铺满全屏之前量好传进来。
    let inset: EdgeInsets

    var body: some View {
        GeometryReader { g in
            let size = g.size
            ZStack(alignment: .topLeading) {
                Palette.bg
                if layout == .phonePortrait {
                    portrait(size, inset)
                } else {
                    landscape(size, inset)
                }
                if voice.phase != .idle { voiceOverlay(size, inset) }
            }
        }
    }

    // MARK: 竖屏（设计稿 390×844）

    @ViewBuilder
    private func portrait(_ size: CGSize, _ inset: EdgeInsets) -> some View {
        let s = min(size.width / 390, size.height / 844)
        let W = size.width, H = size.height
        let barY = max(inset.top + 6, 54 * s)
        let camTop = barY + 46 * s
        let micTop = H - 218 * s
        let camH = min(434 * s, micTop - 92 * s - camTop)
        let camW = camH * 9 / 16
        let stick = 128 * s

        topBar(compact: true, s: s)
            .frame(width: W - 32 * s, height: 36).position(x: W / 2, y: barY + 18)
        camera(s: s, gaze: 80, compact: true)
            .frame(width: camW, height: camH).position(x: W / 2, y: camTop + camH / 2)
        modeColumn(s: s, button: CGSize(width: 56, height: 58), gap: 4, fill: Palette.card)
            .position(x: 4 * s + 34 * s, y: camTop + (4 * 62 + 4) * s / 2)
        actionColumn(s: s, button: CGSize(width: 62, height: 62), gap: 6, fill: Palette.card, boxed: false)
            .position(x: W - 4 * s - 31 * s, y: camTop + CGFloat(ctl.actions.count) * 68 * s / 2)
        if ctl.tray {
            emotionTray(s: s, button: CGSize(width: 64, height: 56), fill: Palette.inset)
                .position(x: W / 2, y: camTop + camH + 14 * s + 32 * s)
        }
        micButton(s: s, labeled: false)
            .position(x: W / 2, y: micTop + 28 * s)
        stickPair(s: s, diameter: stick, knob: 50 * s, y: H - 44 * s - stick / 2, leftX: 16 * s + stick / 2, rightX: W - 16 * s - stick / 2,
                  fill: Palette.stick, border: Color.white.opacity(0.18), labelY: H - 20 * s - 8, labelSize: 12, labelColor: Palette.light)
        startButton(s: s).position(x: W / 2, y: H - 50 * s - 47 * s)
    }

    // MARK: 横屏 / iPad / Duo 展开（设计稿 844×390，按窗口放大）

    @ViewBuilder
    private func landscape(_ size: CGSize, _ inset: EdgeInsets) -> some View {
        let W = size.width, H = size.height
        let L = inset.leading, R = inset.trailing
        let wide = layout.isWide
        // 手机横屏按设计稿 844×390 比例；iPad / Duo 展开按窗口放大（最大 1.6 倍），控件仍贴住两侧外缘。
        let s = wide ? max(1, min(H / 520, (W - L - R) / 620, 1.6))
                     : min(max(min(H / 390, (W - L - R) / 844), 0.8), 1.15)
        let top = max(inset.top, 0) + 12 * s
        let bottom = max(inset.bottom, 0)
        let stick = 124 * s
        let stickY = H - bottom - 34 * s - stick / 2
        let stickLX = L + (wide ? 16 + 68 + 20 : 96) * s + stick / 2
        let stickRX = W - R - (wide ? 16 + 68 + 20 : 96) * s - stick / 2
        let camTop = top + 40 * s
        // 手机横屏：视频占满高度，摇杆在两侧（设计稿 Main）。
        // 宽窗口：视频在上、摇杆在下两角，视频底边停在摇杆上方，语音 / 启动键放在两摇杆之间、中线两侧。
        let camLimitH = wide ? (stickY - stick / 2 - 16 * s - camTop) : (H - camTop - 12 * s - bottom)
        let camLimitW = wide ? (W - L - R - 2 * (16 + 68 + 20) * s) : (W - 2 * (L + (96 + 124 + 16) * s))
        let camH = min(camLimitH, camLimitW * 16 / 9)
        let camW = camH * 9 / 16
        let gapMid = (stickLX + stick / 2 + stickRX - stick / 2) / 2
        // 两摇杆之间的空隙四等分：语音键、启动键各占一侧，都不压中线（Duo 折痕）。
        let keyOffset = max((stickRX - stickLX - stick) / 4, 40 * s)

        camera(s: s, gaze: 60, compact: false)
            .frame(width: camW, height: camH).position(x: W / 2, y: camTop + camH / 2)
        topBar(compact: false, s: s)
            .frame(width: W - L - R - 32, height: 36).position(x: W / 2, y: top + 18)
        modeColumn(s: s, button: CGSize(width: 60, height: 54), gap: 2, fill: Palette.bg.opacity(0.78))
            .position(x: L + 16 * s + 34 * s, y: camTop + 8 * s + (4 * 56 + 6) * s / 2)
        actionColumn(s: s, button: CGSize(width: 60, height: 46), gap: 2, fill: Palette.bg.opacity(0.78), boxed: true)
            .position(x: W - R - 16 * s - 34 * s, y: camTop + 8 * s + (CGFloat(ctl.actions.count) * 48 + 6) * s / 2)
        if ctl.tray {
            emotionTray(s: s, button: CGSize(width: 60, height: 52), fill: Palette.bg.opacity(0.75))
                .position(x: W / 2, y: wide ? camTop + camH - 40 * s : H - bottom - 62 * s - 30 * s)
        }
        if wide {
            micButton(s: s, labeled: true).position(x: gapMid - keyOffset, y: stickY)
            startButton(s: s).position(x: gapMid + keyOffset, y: stickY)
        } else {
            micButton(s: s, labeled: true)
                .position(x: stickLX - 18 * s, y: stickY - stick / 2 - 16 * s - 42 * s)
            startButton(s: s).position(x: stickRX + 2 * s, y: stickY - stick / 2 - 16 * s - 46 * s)
        }
        stickPair(s: s, diameter: stick, knob: 48 * s, y: stickY, leftX: stickLX, rightX: stickRX,
                  fill: wide ? Palette.stick : Palette.bg.opacity(0.28), border: Color.white.opacity(wide ? 0.18 : 0.35),
                  labelY: H - bottom - 8 * s - 7, labelSize: wide ? 12 : 11, labelColor: wide ? Palette.light : Palette.text)
        readout(size: 18 * min(s, 1.3))
            .position(x: W / 2, y: camTop + camH - 22 * s - 10)
    }

    // MARK: 顶栏

    private func topBar(compact: Bool, s: CGFloat) -> some View {
        let pillFill = compact ? Palette.card : Palette.bg.opacity(0.78)
        let border = compact ? Palette.hairline : Color.white.opacity(0.12)
        let (label, dot) = ctl.stateLabel
        let session = model.session
        return HStack(spacing: 8) {
            Button {
                session.disconnect()
                model.path.removeAll()
            } label: {
                HStack(spacing: 8) {
                    DuckImage(quacking: ctl.quackDown).frame(width: compact ? 30 : 38, height: 26)
                    Dot(color: session.linkState == .reconnecting ? Palette.yellow : dot, size: 7)
                    Text(session.linkState == .reconnecting ? L("reconnectingBle") : label).font(Typo.body(13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(Palette.text)
                .padding(.leading, 6).padding(.trailing, compact ? 12 : 14).frame(height: 36)
                .background(pillFill).overlay(Rectangle().strokeBorder(border))
            }
            .pressable()
            .accessibilityLabel(L("robot"))
            Spacer(minLength: 4)
            Button { model.path.append(.status) } label: {
                HStack(spacing: 5) {
                    BatteryGlyph(fraction: session.batteryFraction)
                    Text(session.health?.batteryVolts.map { String(format: "%.1fV", $0) } ?? "--V")
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 14).padding(.horizontal, 3)
                    IconView(.chip, size: 15, weight: 2)
                    Text(session.health?.cpuTempC.map { String(format: "%.0f°", $0) } ?? "--°")
                }
                .font(Typo.body(12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Palette.text)
                .fixedSize()
                .padding(.horizontal, compact ? 9 : 12).frame(height: 36)
                .background(pillFill).overlay(Rectangle().strokeBorder(border))
            }
            .pressable()
            .layoutPriority(1)
            .accessibilityLabel(L("status"))
            if compact {
                circle(.brain, L("policy"), fill: pillFill) { model.path.append(.policy) }
            } else {
                Button { model.path.append(.policy) } label: {
                    HStack(spacing: 6) { IconView(.brain, size: 18); Text(L("policy")).font(Typo.body(12, weight: .semibold)) }
                        .foregroundStyle(Palette.text)
                        .padding(.leading, 10).padding(.trailing, 12).frame(height: 36)
                        .background(pillFill).overlay(Rectangle().strokeBorder(border))
                }
                .pressable()
            }
            powerButton(fill: pillFill, border: compact ? Palette.hairline : Color.white.opacity(0.12)).layoutPriority(1)
        }
    }

    private func circle(_ icon: Icon, _ label: String, fill: Color, action: @escaping () -> Void) -> some View {
        CircleIconButton(icon: icon, label: label, fill: fill, action: action)
    }

    /// 电源键：图标 + 文字的方块，长按时底部粉条走进度，文字提示松手后会做什么（2 秒休息、4 秒关机）。
    /// 可视高度 36，触摸区四周各外扩 8pt。
    private func powerButton(fill: Color, border: Color) -> some View {
        @Bindable var c = ctl
        let held = ctl.powerHeld
        let text = held >= 4 ? L("powerHoldOff") : held >= 2 ? L("powerHoldRest") : L("powerBtn")
        return HStack(spacing: 5) {
            IconView(.power, size: 18, weight: 2)
            Text(text).font(Typo.body(12, weight: .bold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(held >= 2 ? Palette.bg : Palette.pink)
        .padding(.leading, 9).padding(.trailing, 11).frame(height: 36)
        .background(alignment: .leading) {
            GeometryReader { g in
                Rectangle().fill(Palette.pink).frame(width: g.size.width * min(held / 4, 1))
            }
        }
        .background(fill)
        .overlay(Rectangle().strokeBorder(held > 0 ? Palette.pink : border))
        .padding(8).contentShape(Rectangle()).padding(-8)
        .onHold($c.powerHeld) { ctl.powerReleased($0) }
        .accessibilityLabel(L("powerAria"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: 视频框

    private func camera(s: CGFloat, gaze: CGFloat, compact: Bool) -> some View {
        let media = model.session.media
        return ZStack {
            Palette.video
            if ctl.camOn {
                media.videoView()
            } else {
                VStack(spacing: 8) {
                    IconView(.camOff, size: 34, weight: 2)
                    Text(L("camIsOff")).font(Typo.body(12, weight: .bold))
                }
                .foregroundStyle(Palette.disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.panel)
            }
            VStack {
                HStack(alignment: .top) {
                    HStack(spacing: 6) {
                        Dot(color: ctl.camOn ? Palette.pink : Palette.disabled, size: 6)
                        Text(ctl.camOn ? "LIVE" : "OFF").font(Typo.body(10, weight: .heavy)).tracking(0.6)
                        if ctl.camOn, let kbps = media.videoKbps {
                            Text(formatBitrate(kbps)).font(Typo.body(10, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.dim)
                        }
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Palette.bg.opacity(0.72))
                    .padding(8)
                    Spacer()
                    Button { ctl.toggleCam() } label: {
                        IconView(ctl.camOn ? .camOn : .camOff, size: 17, weight: 2)
                            .foregroundStyle(Palette.text)
                            .frame(width: 32, height: 32)
                            .background(Palette.bg.opacity(0.72))
                            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18)))
                    }
                    .pressable()
                    .padding(6)
                    .accessibilityLabel(ctl.camOn ? L("camTurnOff") : L("camTurnOn"))
                }
                if let toast = ctl.toast, voice.phase == .idle, compact {
                    Text(toast.text).font(Typo.body(12, weight: .semibold)).multilineTextAlignment(.center)
                        .foregroundStyle(toast.warn ? Palette.yellow : Palette.text)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Palette.bg.opacity(0.78))
                        .frame(maxWidth: 220)
                        .padding(.top, -8)
                }
                Spacer()
                if compact { readout(size: 18).padding(.bottom, 10) }
            }
            Reticle().offset(x: ctl.reticle.x * gaze * s, y: ctl.reticle.y * gaze * 1.85 * s)
            if let toast = ctl.toast, voice.phase == .idle, !compact {
                VStack {
                    Text(toast.text).font(Typo.body(12, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(toast.warn ? Palette.yellow : Palette.text)
                        .padding(.horizontal, 14).frame(minHeight: 30)
                        .background(Palette.bg.opacity(0.7))
                        .fixedSize()
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .clipped()
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("cameraRegion"))
    }

    private func readout(size: CGFloat) -> some View {
        let r = ctl.readout
        return HStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(r.0).font(Typo.body(size, weight: .semibold))
                Text(r.1).font(Typo.body(11)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(r.2).font(Typo.body(size, weight: .semibold))
                Text(r.3).font(Typo.body(11)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .monospacedDigit()
        .foregroundStyle(Palette.text)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .fixedSize()
    }

    // MARK: 模式列 / 动作列 / 情绪托盘

    private func modeColumn(s: CGFloat, button: CGSize, gap: CGFloat, fill: Color) -> some View {
        let modes: [(DriveController.Mode, String, Icon)] = [(.walk, L("mWalk"), .move), (.head, L("mHead"), .head),
                                                            (.look, L("mLook"), .look), (.height, L("mHeight"), .height)]
        return VStack(spacing: gap * s) {
            ForEach(modes, id: \.1) { m, name, icon in
                let on = ctl.mode == m
                Button { ctl.mode = m; ctl.tray = false } label: {
                    VStack(spacing: 3) {
                        IconView(icon, size: 22 * min(s, 1.2))
                        Text(name).font(Typo.body(11, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(on ? Palette.bg : Palette.text)
                    .frame(width: button.width * s, height: button.height * s)
                    .background(on ? Palette.orange : .clear)
                }
                .pressable()
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(4 * s)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(fill == Palette.card ? 0.09 : 0.12)))
        .accessibilityLabel(L("modeAria"))
    }

    private func actionColumn(s: CGFloat, button: CGSize, gap: CGFloat, fill: Color, boxed: Bool) -> some View {
        VStack(spacing: gap * s) {
            ForEach(ctl.actions) { a in
                VStack(spacing: boxed ? 2 : 4) {
                    IconView(a.icon, size: (boxed ? 22 : 24) * min(s, 1.2))
                    Text(a.name).font(Typo.body(11, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(a.on ? Palette.bg : Palette.text)
                .frame(width: button.width * s, height: button.height * s)
                .background(a.on ? Palette.orange : (boxed ? .clear : Palette.card))
                .opacity(ctl.dimmed(a) ? 0.4 : 1)
                .contentShape(Rectangle())
                .onPress(down: a.down, up: a.up)
                .accessibilityElement()
                .accessibilityLabel(a.name)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { a.down(); a.up() }
            }
        }
        .padding(boxed ? 4 * s : 0)
        .background(boxed ? fill : .clear)
        .overlay(Rectangle().strokeBorder(boxed ? Color.white.opacity(0.12) : .clear))
    }

    private func emotionTray(s: CGFloat, button: CGSize, fill: Color) -> some View {
        HStack(spacing: 6 * s) {
            ForEach(ctl.emotions) { e in
                Button(action: e.go) {
                    VStack(spacing: 3) {
                        IconView(e.icon, size: 22, weight: 2).foregroundStyle(e.color)
                        Text(e.name).font(Typo.body(11, weight: .semibold)).foregroundStyle(Palette.text).fixedSize()
                    }
                    .frame(width: button.width * s, height: button.height * s)
                }
                .pressable()
            }
        }
        .padding(4 * s)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14)))
    }

    // MARK: 摇杆 / 启动键 / 语音键

    @ViewBuilder
    private func stickPair(s: CGFloat, diameter: CGFloat, knob: CGFloat, y: CGFloat, leftX: CGFloat, rightX: CGFloat,
                           fill: Color, border: Color, labelY: CGFloat, labelSize: CGFloat, labelColor: Color) -> some View {
        @Bindable var c = ctl
        let (l, r): (String, String) = switch ctl.mode {
        case .walk: (L("sMove"), L("sTurn"))
        case .head: (L("sTurnHead"), L("sTilt"))
        case .look: (L("sDrive"), L("sLook"))
        case .height: (L("sHeight"), L("sLook"))
        }
        Joystick(diameter: diameter, knob: knob, fill: fill, border: border, label: l, value: $c.left).position(x: leftX, y: y)
        Joystick(diameter: diameter, knob: knob, fill: fill, border: border, label: r, value: $c.right).position(x: rightX, y: y)
        Text(l).font(Typo.body(labelSize, weight: .bold)).foregroundStyle(labelColor).shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
            .position(x: leftX, y: labelY).accessibilityHidden(true)
        Text(r).font(Typo.body(labelSize, weight: .bold)).foregroundStyle(labelColor).shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
            .position(x: rightX, y: labelY).accessibilityHidden(true)
    }

    private func startButton(s: CGFloat) -> some View {
        @Bindable var c = ctl
        return VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 3)
                Ring(progress: ctl.startHeld / 1.5, color: Palette.orange)
                Circle().fill(ctl.power == .walking ? Palette.orange : .white).frame(width: 56, height: 56)
                IconView(ctl.startIcon, size: 24, weight: 2.2).foregroundStyle(Palette.bg)
            }
            .frame(width: 68, height: 68)
            .padding(2)
            Text(ctl.startText).font(Typo.body(12, weight: .bold)).foregroundStyle(Palette.text)
        }
        .scaleEffect(min(s, 1.2))
        .contentShape(Rectangle())
        .onHold($c.startHeld) { ctl.startReleased($0) }
        .accessibilityElement()
        .accessibilityLabel(ctl.startText)
        .accessibilityAddTraits(.isButton)
    }

    private func micButton(s: CGFloat, labeled: Bool) -> some View {
        let live = voice.phase != .idle
        let cancelOn = live && voice.zone == .cancel
        let locked = voice.locked
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                IconView(.mic, size: 24, weight: 2.1)
                    .foregroundStyle(locked ? Palette.disabled : live ? Palette.bg : Palette.text)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(locked ? Palette.inset : cancelOn ? Palette.pink : live ? Palette.yellow : (labeled ? Palette.bg.opacity(0.78) : Palette.card)))
                    .overlay(Circle().strokeBorder(live ? Palette.bg : Palette.dashed, lineWidth: 2))
                    .background(Circle().fill(live ? Palette.orange : .clear).offset(x: 3, y: 3))
                if locked {
                    IconView(.key, size: 12, weight: 2.4).foregroundStyle(Palette.bg)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.pink))
                        .overlay(Circle().strokeBorder(Palette.bg, lineWidth: 2))
                        .offset(x: 6, y: 4)
                }
            }
            if labeled {
                Text(L("tabVoice")).font(Typo.body(11, weight: .bold)).foregroundStyle(Palette.text)
                    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
            }
        }
        .scaleEffect(min(s, 1.3))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if voice.phase == .idle && g.translation == .zero { voice.press() }
                    voice.move(dx: g.translation.width / min(s, 1.3), dy: g.translation.height / min(s, 1.3))
                }
                .onEnded { _ in voice.release() }
        )
        .zIndex(6)
        .accessibilityElement()
        .accessibilityLabel(L("voiceAria"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: 语音面板（黄色漫画框、上划目标）

    @ViewBuilder
    private func voiceOverlay(_ size: CGSize, _ inset: EdgeInsets) -> some View {
        let cancelOn = voice.zone == .cancel, sendOn = voice.zone == .send
        let portrait = layout == .phonePortrait
        let s = portrait ? min(size.width / 390, size.height / 844) : min(max(size.height / 390, 0.8), 1.3)
        Palette.bg.opacity(0.6).allowsHitTesting(false)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconView(.mic, size: 18, weight: 2.2)
                Title(voice.phase == .thinking ? L("thinking") : L("listening"), 18, tracking: 0.04)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { i in
                        let h = voice.phase == .listening && !cancelOn
                            ? 4 + CGFloat(abs(sin(Double(voice.level) * 6 + Double(i) * 1.3))) * 14 * CGFloat(max(0.3, voice.level)) + 2
                            : 4
                        Rectangle().fill(Palette.bg).frame(width: 4, height: h)
                    }
                }
                .frame(height: 22)
            }
            (Text(voice.heard.isEmpty && voice.phase != .listening ? "…" : voice.heard) + Text(voice.phase == .listening ? "|" : ""))
                .font(Typo.body(17, weight: .bold))
                .strikethrough(cancelOn)
                .frame(minHeight: 23, alignment: .leading)
            Text(voice.phase == .thinking ? L("hintSent") : cancelOn ? L("hintCancel") : sendOn ? L("hintSend") : L("hintIdle"))
                .font(Typo.body(12, weight: .bold))
        }
        .foregroundStyle(Palette.bg)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .frame(width: portrait ? size.width - 64 * s : 320 * s)
        .background(cancelOn ? Palette.pink : Palette.yellow)
        .overlay(Rectangle().strokeBorder(Palette.bg, lineWidth: 3))
        .hardShadow(cancelOn ? Palette.bg : Palette.orange, offset: 5)
        .rotationEffect(.degrees(-1))
        .position(x: size.width / 2, y: portrait ? 150 * s + 60 : max(inset.top, 0) + 60 * s + 55)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)

        // 上划目标：跟随语音键位置（竖屏在键的左上 / 右上，横屏在面板两侧）。
        let micCenter: CGPoint = portrait
            ? CGPoint(x: size.width / 2, y: size.height - 218 * s + 28 * s)
            : layout.isWide
                ? CGPoint(x: size.width / 2 - 70 * s, y: size.height - max(inset.bottom, 0) - (34 + 62) * s)
                : CGPoint(x: inset.leading + (96 + 62 - 18) * s, y: size.height - max(inset.bottom, 0) - (34 + 124 + 16 + 42) * s)
        let d: CGFloat = portrait ? 68 : 56
        target(L("vCancel"), icon: .x, on: cancelOn, color: Palette.pink, size: d * s)
            .position(x: micCenter.x - 80 * s, y: micCenter.y - (portrait ? 72 : 110) * s)
        target(L("vSend"), icon: .send, on: sendOn, color: Palette.orange, size: d * s)
            .position(x: micCenter.x + 80 * s, y: micCenter.y - (portrait ? 72 : 110) * s)
    }

    private func target(_ text: String, icon: Icon, on: Bool, color: Color, size: CGFloat) -> some View {
        VStack(spacing: 2) {
            IconView(icon, size: 22, weight: 2.4)
            Text(text).font(Typo.body(11, weight: .bold))
        }
        .foregroundStyle(on ? Palette.bg : Palette.text)
        .frame(width: size, height: size)
        .background(Circle().fill(on ? color : Palette.card.opacity(0.92)))
        .overlay(Circle().strokeBorder(on ? Palette.bg : Palette.dashed, lineWidth: 2))
        .background(Circle().fill(on ? Palette.yellow : .clear).offset(x: 3, y: 3))
        .scaleEffect(on ? 1.18 : 1)
        .animation(.easeOut(duration: 0.12), value: on)
        .allowsHitTesting(false)
    }
}

/// 视频码率：1 Mbps 以下按 kbps，以上保留一位小数。
func formatBitrate(_ kbps: Int) -> String {
    kbps < 1000 ? "\(kbps) kbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
}
