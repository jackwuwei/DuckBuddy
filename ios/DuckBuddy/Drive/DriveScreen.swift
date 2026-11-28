import SwiftUI

/// 驾驶页（设计稿 PortraitDrive 390×844 / Main 844×390）。
///
/// 手机上按设计稿坐标等比放置；iPad 和 iPhone Duo 展开时沿用横屏结构：两手拇指位（摇杆、模式列、动作列）
/// 贴住左右外缘，视频居中；语音键和启动键放在中线两侧，不压在 Duo 的折痕上。
/// 折叠 / 展开 / 分屏只改变布局，`DriveController` 与连接状态保持，驾驶不中断。
struct DriveScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @Environment(\.scenePhase) private var scenePhase
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
        .onDisappear { ctl?.stopRecording(); ctl?.stopLoop(); UIApplication.shared.isIdleTimerDisabled = false }
        // 退到后台写不了视频：先停下把已录的存好。
        .onChange(of: scenePhase) { _, p in if p == .background { ctl?.stopRecording() } }
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

    /// 手机竖屏：画面按真实比例尽量放大、完整显示（不裁切），所有控件浮在画面上。
    /// 模式列收成一个按钮，动作列可以收起；双击画面或用按钮可以切换成铺满整屏（会裁掉多出的部分）。
    @ViewBuilder
    private func portrait(_ size: CGSize, _ inset: EdgeInsets) -> some View {
        let s = min(size.width / 390, size.height / 844)
        let W = size.width, H = size.height
        let barY = max(inset.top + 6, 54 * s)
        let rowY = barY + 46
        let railTop = rowY + 42
        let micTop = H - 218 * s
        let stick = 128 * s
        let fill = ctl.videoFill[true] ?? false
        let scrim = Palette.bg

        videoLayer(s: s, gaze: 80, portrait: true, fill: fill)
            .frame(width: W, height: H).position(x: W / 2, y: H / 2)
        // 上下两道渐变压暗，浮在画面上的字和按钮才看得清。
        LinearGradient(colors: [scrim.opacity(0.75), scrim.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(width: W, height: railTop + 24).position(x: W / 2, y: (railTop + 24) / 2).allowsHitTesting(false)
        LinearGradient(colors: [scrim.opacity(0), scrim.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            .frame(width: W, height: H - micTop + 80 * s).position(x: W / 2, y: H - (H - micTop + 80 * s) / 2).allowsHitTesting(false)

        topBar(compact: true, s: s)
            .frame(width: W - 32 * s, height: 36).position(x: W / 2, y: barY + 18)
        HStack {
            liveBadge(model.session.media)
            Spacer(minLength: 8)
            captureButtons(fillToggle: (portrait: true, fill: fill))
        }
        .frame(width: W - 32 * s).position(x: W / 2, y: rowY + 16)
        modeColumn(s: s, button: CGSize(width: 56, height: 54), gap: 2, fill: Palette.bg.opacity(0.6), collapsible: true)
            .padding(.leading, 12 * s).padding(.top, railTop)
            .frame(width: W, height: H, alignment: .topLeading)
        actionColumn(s: s, button: CGSize(width: 60, height: 52), gap: 2, fill: Palette.bg.opacity(0.6), boxed: true, collapsible: true)
            .padding(.trailing, 12 * s).padding(.top, railTop)
            .frame(width: W, height: H, alignment: .topTrailing)
        toastView(maxWidth: W - 2 * (12 + 72) * s)
            .position(x: W / 2, y: railTop + 18)
        if !ctl.tray { readout(size: 18).position(x: W / 2, y: micTop - 24 * s) }
        micButton(s: s, labeled: false)
            .position(x: W / 2, y: micTop + 28 * s)
        stickPair(s: s, diameter: stick, knob: 50 * s, y: H - 44 * s - stick / 2, leftX: 16 * s + stick / 2, rightX: W - 16 * s - stick / 2,
                  fill: Palette.bg.opacity(0.28), border: Color.white.opacity(0.35), labelY: H - 20 * s - 8, labelSize: 12, labelColor: Palette.text)
        startButton(s: s).position(x: W / 2, y: H - 50 * s - 47 * s)
        if ctl.tray {
            // 点托盘外面任何地方收起（这一层吃掉这次点击，不会误触摇杆和按钮）。
            Color.clear.contentShape(Rectangle()).onTapGesture { ctl.tray = false }
                .frame(width: W, height: H).position(x: W / 2, y: H / 2)
            trayBesideActions(s: s, W: W, H: H, trailing: 12 * s, top: railTop, button: CGSize(width: 60, height: 52))
        }
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
        let railTop = top + 48 * s
        // 宽窗口：视频在上、摇杆在下两角，视频底边停在摇杆上方，语音 / 启动键放在两摇杆之间、中线两侧。
        // 手机横屏：画面按真实比例在整个窗口里尽量放大、完整显示（顶栏和两侧控件浮在上面）；可以切换成铺满整屏。
        let aspect = model.session.media.videoAspect
        let camTop = wide ? top + 40 * s : 0
        let camLimitH = wide ? (stickY - stick / 2 - 16 * s - camTop) : H
        let camLimitW = wide ? (W - L - R - 2 * (16 + 68 + 20) * s) : W
        let camH = min(camLimitH, camLimitW / aspect)
        let camW = camH * aspect
        let fill = !wide && (ctl.videoFill[false] ?? false)
        let gapMid = (stickLX + stick / 2 + stickRX - stick / 2) / 2
        // 两摇杆之间的空隙四等分：语音键、启动键各占一侧，都不压中线（Duo 折痕）。
        let keyOffset = max((stickRX - stickLX - stick) / 4, 40 * s)

        if wide {
            camera(s: s, gaze: 60)
                .frame(width: camW, height: camH).position(x: W / 2, y: camTop + camH / 2)
        } else {
            videoLayer(s: s, gaze: 60, portrait: false, fill: fill)
                .frame(width: W, height: H).position(x: W / 2, y: H / 2)
            if fill {
                // 铺满时整体压暗一些，浮在画面上的字和按钮才看得清。
                LinearGradient(colors: [Palette.bg.opacity(0.7), Palette.bg.opacity(0.3), Palette.bg.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    .frame(width: W, height: H).position(x: W / 2, y: H / 2).allowsHitTesting(false)
            }
            liveBadge(model.session.media)
                .padding(.leading, max(W / 2 - camW / 2 + 8, L + (16 + 68 + 8) * s)).padding(.top, railTop)
                .frame(width: W, height: H, alignment: .topLeading)
            // 按钮竖排在视频右边、和模式列顶边对齐（启动键左边的空白里）。
            captureButtons(fillToggle: (portrait: false, fill: fill), vertical: true)
                .padding(.leading, min(W / 2 + camW / 2 + 8 * s, W - R - (16 + 68 + 8) * s - 32)).padding(.top, railTop)
                .frame(width: W, height: H, alignment: .topLeading)
            toastView(maxWidth: camW - 16).position(x: W / 2, y: railTop + 44)
        }
        topBar(compact: false, s: s)
            .frame(width: W - L - R - 32, height: 36).position(x: W / 2, y: top + 18)
        // 手机横屏和竖屏一样：模式列收成一个按钮，动作列可以收起，让出画面；宽窗口一直展开。
        modeColumn(s: s, button: CGSize(width: 60, height: 54), gap: 2, fill: Palette.bg.opacity(0.78), collapsible: !wide)
            .padding(.leading, L + 16 * s).padding(.top, railTop)
            .frame(width: W, height: H, alignment: .topLeading)
        actionColumn(s: s, button: CGSize(width: 60, height: 46), gap: 2, fill: Palette.bg.opacity(0.78), boxed: true, collapsible: !wide)
            .padding(.trailing, R + 16 * s).padding(.top, railTop)
            .frame(width: W, height: H, alignment: .topTrailing)
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
            .position(x: W / 2, y: wide ? camTop + camH - 22 * s - 10 : H - bottom - 34 * s - 10)
        if ctl.tray {
            // 点托盘外面任何地方收起（这一层吃掉这次点击，不会误触摇杆和按钮）。
            Color.clear.contentShape(Rectangle()).onTapGesture { ctl.tray = false }
                .frame(width: W, height: H).position(x: W / 2, y: H / 2)
            // 宽窗口：视频右边到动作列之间放得下一列以上就排成网格，不盖视频；否则退回一行。
            let camRight = W / 2 + camW / 2, actLeft = W - R - (16 + 68) * s
            let ps = min(s, 1.2)
            let cols = Int((actLeft - camRight - 12 * s - 2 * ps) / (66 * ps))
            if wide, cols >= 1 {
                let c = min(cols, 4), rows = CGFloat((ctl.trayItems.count + c - 1) / c)
                let h = min(rows * 52 * ps + (rows - 1) * 6 * ps, camH - 16 * s) + 8 * ps
                emotionPanel(s: ps, button: CGSize(width: 60, height: 52), fill: Palette.bg, columns: c, maxHeight: camH - 8 * s)
                    .position(x: (camRight + actLeft) / 2, y: camTop + 8 * s + h / 2)
            } else if wide {
                emotionTray(s: s, button: CGSize(width: 60, height: 52), fill: Palette.bg, maxWidth: W - L - R - 2 * (16 + 68 + 20) * s)
                    .position(x: W / 2, y: camTop + camH - 40 * s)
            } else {
                trayBesideActions(s: s, W: W, H: H, trailing: R + 16 * s, top: railTop, button: CGSize(width: 60, height: 46))
            }
        }
    }

    // MARK: 顶栏

    private func topBar(compact: Bool, s: CGFloat) -> some View {
        // 两种都浮在画面上：竖屏画面铺满，底色更透一些。
        let pillFill = Palette.bg.opacity(compact ? 0.6 : 0.78)
        let border = Color.white.opacity(0.12)
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
                    Text(session.batteryPercentText + "%")
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
            powerButton(fill: pillFill, border: border).layoutPriority(1)
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

    /// 宽窗口的视频框：画面、LIVE 标签、拍照 / 录像 / 画面开关、提示、准星都在框里。
    private func camera(s: CGFloat, gaze: CGFloat) -> some View {
        ZStack {
            videoLayer(s: s, gaze: gaze, portrait: nil, fill: true)
            VStack {
                HStack(alignment: .top) {
                    liveBadge(model.session.media).padding(8)
                    Spacer(minLength: 0)
                    captureButtons().padding(6)
                }
                Spacer()
            }
            VStack { toastView(maxWidth: 320).padding(.top, 8); Spacer() }
        }
        .clipped()
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("cameraRegion"))
    }

    /// 画面本身（或"画面已关闭"）加准星，按画面真实比例。`fill`：等比铺满、裁掉多出的部分；否则完整显示、留黑边。
    /// `portrait` 不为空时（手机），双击画面切换铺满 / 完整显示。
    private func videoLayer(s: CGFloat, gaze: CGFloat, portrait: Bool?, fill: Bool) -> some View {
        ZStack {
            Palette.video
            if ctl.camOn {
                model.session.media.videoView()
                    .aspectRatio(model.session.media.videoAspect, contentMode: fill ? .fill : .fit)
            } else {
                VStack(spacing: 8) {
                    IconView(.camOff, size: 34, weight: 2)
                    Text(L("camIsOff")).font(Typo.body(12, weight: .bold))
                }
                .foregroundStyle(Palette.disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.panel)
            }
            if let portrait {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { ctl.videoFill[portrait] = !fill }
            }
            Reticle().offset(x: ctl.reticle.x * gaze * s, y: ctl.reticle.y * gaze * 1.85 * s)
                .allowsHitTesting(false)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("cameraRegion"))
    }

    /// 提示条（动作结果、警告）；语音面板打开时不显示。
    @ViewBuilder
    private func toastView(maxWidth: CGFloat) -> some View {
        if let toast = ctl.toast, voice.phase == .idle {
            Text(toast.text).font(Typo.body(12, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3)
                .foregroundStyle(toast.warn ? Palette.yellow : Palette.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.bg.opacity(0.78))
                .frame(maxWidth: maxWidth)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
        }
    }

    /// 拍照、录像、开关画面三个按钮（一行）。竖屏和宽窗口放在视频右上角；手机横屏视频框太窄（约 180 pt），
    /// 放在视频右边的空白里，不压住 LIVE 标签和画面。
    /// `fillToggle`：手机上多一个铺满 / 完整显示的切换键（键：是否竖屏；当前是否铺满）。
    private func captureButtons(fillToggle: (portrait: Bool, fill: Bool)? = nil, vertical: Bool = false) -> some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return stack {
            if let t = fillToggle, ctl.camOn {
                overlayButton(t.fill ? .shrink : .expand, label: t.fill ? L("videoFit") : L("videoFill")) {
                    ctl.videoFill[t.portrait] = !t.fill
                }
            }
            if ctl.camOn {
                overlayButton(.shutter, label: L("takePhoto")) { ctl.takePhoto() }
                overlayButton(ctl.recording ? .stop : .record, label: ctl.recording ? L("recStop") : L("recStart"),
                              on: ctl.recording) { ctl.toggleRecord() }
            }
            overlayButton(ctl.camOn ? .camOn : .camOff, label: ctl.camOn ? L("camTurnOff") : L("camTurnOn")) { ctl.toggleCam() }
        }
    }

    /// 左上角的 LIVE / OFF 标签；录像时换成 REC 和已录时长。
    private func liveBadge(_ media: MediaLink) -> some View {
        HStack(spacing: 6) {
            if let since = ctl.recordingSince {
                Dot(color: Palette.pink, size: 6)
                Text("REC").font(Typo.body(10, weight: .heavy)).tracking(0.6)
                TimelineView(.periodic(from: since, by: 1)) { t in
                    Text(formatDuration(t.date.timeIntervalSince(since))).font(Typo.body(10, weight: .semibold)).monospacedDigit()
                }
            } else {
                Dot(color: ctl.camOn ? Palette.pink : Palette.disabled, size: 6)
                Text(ctl.camOn ? "LIVE" : "OFF").font(Typo.body(10, weight: .heavy)).tracking(0.6)
                if ctl.camOn, let kbps = media.videoKbps {
                    Text(formatBitrate(kbps)).font(Typo.body(10, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.dim)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 6).frame(height: 20)
        .background(Palette.bg.opacity(0.72))
        .fixedSize()
    }

    /// 视频右上角的方形小按钮（拍照、录像、开关画面）；`on` 时粉底（正在录像）。
    private func overlayButton(_ icon: Icon, label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon, size: 17, weight: 2)
                .foregroundStyle(on ? Palette.bg : Palette.text)
                .frame(width: 32, height: 32)
                .background(on ? Palette.pink : Palette.bg.opacity(0.72))
                .overlay(Rectangle().strokeBorder(on ? Palette.pink : Color.white.opacity(0.18)))
        }
        .pressable()
        .accessibilityLabel(label)
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

    /// 摇杆模式（行走 / 头部）。`collapsible`（手机）：只放一个按钮显示当前模式，点一下切到另一个；宽窗口两个都列出来。
    private func modeColumn(s: CGFloat, button: CGSize, gap: CGFloat, fill: Color, collapsible: Bool = false) -> some View {
        let all: [(DriveController.Mode, String, Icon)] = [(.walk, L("mWalk"), .move), (.head, L("mHead"), .head)]
        let modes = collapsible ? all.filter { $0.0 == ctl.mode } : all
        return VStack(spacing: gap * s) {
            ForEach(modes, id: \.1) { m, name, icon in
                let on = ctl.mode == m
                let other = all.first { $0.0 != m }!
                Button {
                    ctl.mode = collapsible ? other.0 : m
                    ctl.tray = false
                } label: {
                    VStack(spacing: 3) {
                        IconView(icon, size: 22 * min(s, 1.2))
                        Text(name).font(Typo.body(11, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(on ? Palette.bg : Palette.text)
                    .frame(width: button.width * s, height: button.height * s)
                    .background(on ? Palette.orange : .clear)
                    .overlay(alignment: .topTrailing) {
                        if collapsible { IconView(.swap, size: 11, weight: 2.6).foregroundStyle(Palette.bg).padding(3) }
                    }
                }
                .pressable()
                .accessibilityLabel(collapsible ? "\(name)，\(L("modeSwitchTo")) \(other.1)" : name)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(4 * s)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12)))
        .accessibilityLabel(L("modeAria"))
    }

    /// `collapsible`（手机竖屏）：顶上一个收起 / 展开键，收起后只剩这个键。
    private func actionColumn(s: CGFloat, button: CGSize, gap: CGFloat, fill: Color, boxed: Bool, collapsible: Bool = false) -> some View {
        let open = !collapsible || ctl.actionsOpen
        return VStack(spacing: gap * s) {
            if collapsible {
                Button { ctl.actionsOpen.toggle(); ctl.tray = false } label: {
                    IconView(.chevron, size: 16, weight: 2.4)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(Palette.text)
                        .frame(width: button.width * s, height: 24 * s)
                }
                .pressable()
                .accessibilityLabel(open ? L("actionsHide") : L("actionsShow"))
            }
            ForEach(open ? ctl.actions : []) { a in
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
        .animation(.easeOut(duration: 0.15), value: ctl.actionsOpen)
    }

    private func trayButton(_ e: DriveController.Emotion, s: CGFloat, button: CGSize) -> some View {
        Button(action: e.go) {
            VStack(spacing: 3) {
                IconView(e.icon, size: 22, weight: 2).foregroundStyle(e.on ? Palette.bg : e.color)
                Text(e.name).font(Typo.body(11, weight: .semibold)).foregroundStyle(e.on ? Palette.bg : Palette.text).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: button.width * s, height: button.height * s)
            .background(e.on ? Palette.orange : .clear)
        }
        .pressable()
        .accessibilityAddTraits(e.on ? [.isSelected] : [])
    }

    /// 手机上的托盘：从"更多"旁边弹出——贴在动作列左边、底边和动作列（"更多"在最下面）对齐，排成三列往上长，
    /// 右手拇指顺手就点到。最高到动作列顶，放不下时露出半行。`button`：动作列按钮的尺寸，用来算动作列的高度。
    private func trayBesideActions(s: CGFloat, W: CGFloat, H: CGFloat, trailing: CGFloat, top: CGFloat, button: CGSize) -> some View {
        let n = CGFloat(ctl.actions.count)
        let colH = 8 * s + (24 + 2) * s + n * button.height * s + max(n - 1, 0) * 2 * s
        let colW = button.width * s + 8 * s
        let ps = min(s, 1.2)
        return emotionPanel(s: ps, button: CGSize(width: 60, height: 52), fill: Palette.bg, columns: 3, maxHeight: colH)
            .padding(.trailing, trailing + colW + 6 * s).padding(.bottom, H - top - colH)
            .frame(width: W, height: H, alignment: .bottomTrailing)
    }

    /// 托盘（一行）：玩法开关在前，然后是叫声和情绪；放不下时横向滑动。用在手机竖屏（视频下方）和手机横屏。
    private func emotionTray(s: CGFloat, button: CGSize, fill: Color, maxWidth: CGFloat) -> some View {
        let items = ctl.trayItems
        let content = CGFloat(items.count) * button.width * s + CGFloat(max(items.count - 1, 0)) * 6 * s
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6 * s) { ForEach(items) { trayButton($0, s: s, button: button) } }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(width: peek(content: content, limit: maxWidth - 8 * s, item: button.width * s, gap: 6 * s), height: button.height * s)
        .padding(4 * s)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14)))
    }

    /// 宽窗口的托盘：放在视频和右侧动作列之间的空白里，排成网格，不盖住视频。
    private func emotionPanel(s: CGFloat, button: CGSize, fill: Color, columns: Int, maxHeight: CGFloat) -> some View {
        let items = ctl.trayItems
        let rows = (items.count + columns - 1) / columns
        let content = CGFloat(rows) * button.height * s + CGFloat(max(rows - 1, 0)) * 6 * s
        let height = peek(content: content, limit: maxHeight - 8 * s, item: button.height * s, gap: 6 * s)
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(button.width * s), spacing: 6 * s), count: columns), spacing: 6 * s) {
                ForEach(items) { trayButton($0, s: s, button: button) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: CGFloat(columns) * button.width * s + CGFloat(columns - 1) * 6 * s, height: height)
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

/// 托盘放不下时的可见长度：停在某个按钮的一半，让后面的按钮露出半截图标和文字，一看就知道还能滑。
/// 放得下时就是内容本身的长度。
func peek(content: CGFloat, limit: CGFloat, item: CGFloat, gap: CGFloat) -> CGFloat {
    guard content > limit else { return content }
    let whole = max(0, floor((limit - item / 2) / (item + gap)))
    return whole * (item + gap) + item / 2
}

/// 录像时长：m:ss，一小时以上 h:mm:ss。
func formatDuration(_ seconds: TimeInterval) -> String {
    let t = max(0, Int(seconds))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

/// 视频码率：1 Mbps 以下按 kbps，以上保留一位小数。
func formatBitrate(_ kbps: Int) -> String {
    kbps < 1000 ? "\(kbps) kbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
}
