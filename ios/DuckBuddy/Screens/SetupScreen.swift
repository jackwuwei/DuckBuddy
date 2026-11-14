import SwiftUI
import VisionKit

/// 添加新鸭子（设计稿 PortraitSetup / Setup）：找鸭子 → 验证 → 连 Wi-Fi → 起名字。
struct SetupScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout

    enum Verify: Equatable { case idle, busy, ok, bad(String) }
    enum Join: Equatable { case idle, busy, ok(String), failed(String) }

    @State private var step = 0
    @State private var picked: String?
    @State private var quacking: String?
    @State private var code = ""
    @State private var verify = Verify.idle
    @State private var scanning = false
    @State private var nets: [WifiNetwork] = []
    @State private var wifiPick: String?
    @State private var password = ""
    @State private var showPw = false
    @State private var join = Join.idle
    @State private var skippedWifi = false
    @State private var name = ""
    @State private var finished = false
    @State private var tick = 0.0

    private let titles = ["stepFind", "stepVerify", "stepWifi", "stepName"]
    private var duckName: String { picked ?? model.session.nearby.first?.id ?? "duck" }
    /// 认证前让机器人叫一声：官方待办（mobile-app.md §7），可用前只在演示模式显示。
    private var identifyAvailable: Bool { model.session.isDemo }

    var body: some View {
        Screen {
            VStack(spacing: layout == .phonePortrait ? 14 : 12) {
                TitleBar(title: L(titles[step]), back: back) {
                    if layout != .phonePortrait { stepper }
                }
                if layout == .phonePortrait {
                    stepper
                    graphic.frame(height: 270)
                    ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                    footer
                } else {
                    TwoPane(primaryFraction: 0.42) {
                        graphic.frame(maxHeight: .infinity)
                    } secondary: {
                        VStack(spacing: 10) {
                            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                            footer
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: layout == .expanded ? 1100 : .infinity)
        }
        .task {
            model.session.startScan()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                tick += 1
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                code = text
                Task { await pair() }
            }
            .ignoresSafeArea()
        }
    }

    private func back() {
        if step > 0 && !finished && verify != .busy { step = step == 3 && skippedWifi ? 1 : step - 1 }
        else { model.session.stopScan(); model.path.removeLast() }
    }

    // MARK: 步骤条（30pt 圆 + 16pt 连线）

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                let done = i < step || finished, cur = i == step && !finished
                let icon: Icon = done ? .check : [.bt, .qr, .wifi, .pen][i]
                IconView(icon, size: 16, weight: 2.2)
                    .foregroundStyle(cur || done ? Palette.bg : Palette.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(cur ? Palette.orange : done ? Palette.cyan : .clear))
                    .overlay(Circle().strokeBorder(cur ? Palette.bg : done ? Palette.cyan : Palette.field, lineWidth: 2))
                    .accessibilityLabel(L(titles[i]))
                if i < 3 { Rectangle().fill(i < step ? Palette.cyan : Color.white.opacity(0.18)).frame(width: 16, height: 2) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("stepsAria"))
    }

    // MARK: 大图形

    private var graphic: some View {
        ZStack {
            Palette.panel
            switch step {
            case 0: radar
            case 1: finder
            case 2:
                let c: Color = { if case .ok = join { return Palette.cyan }; return join == .busy ? Palette.yellow : Palette.orange }()
                IconView({ if case .ok = join { return Icon.check }; return Icon.wifi }(), size: 96, weight: 1.6).foregroundStyle(c)
            default:
                VStack(spacing: 12) {
                    DuckImage(quacking: finished).frame(width: 150, height: 100)
                    Title(name.trimmingCharacters(in: .whitespaces).isEmpty ? duckName : name, 26).lineLimit(1)
                        .frame(maxWidth: 240)
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Palette.hairline))
    }

    private var radar: some View {
        ZStack {
            Circle().strokeBorder(Palette.cyan.opacity(0.18), lineWidth: 1.5).frame(width: 200, height: 200)
            Circle().strokeBorder(Palette.cyan.opacity(0.32), lineWidth: 1.5).frame(width: 146, height: 146)
            Circle().strokeBorder(Palette.cyan.opacity(0.55), lineWidth: 1.5).frame(width: 92, height: 92)
                .scaleEffect(1 + 0.12 * sin(tick / 3))
            DuckImage().frame(width: 84, height: 56)
        }
        .accessibilityHidden(true)
    }

    private var finderColor: Color {
        switch verify {
        case .ok: Palette.cyan
        case .bad: Palette.pink
        default: Palette.orange
        }
    }

    private var finder: some View {
        Button { scanning = true } label: {
            ZStack {
                Color(hex: 0x16161F)
                ForEach(0..<4, id: \.self) { corner in
                    CornerMark(color: finderColor)
                        .rotationEffect(.degrees(Double(corner) * 90))
                }
                Rectangle().fill(finderColor).opacity(0.8).frame(height: 2).padding(.horizontal, 14)
                    .offset(y: verify == .busy ? CGFloat((12 + (Int(tick) * 7) % 76) - 50) / 100 * 190 : 0)
                IconView(verify == .ok ? .check : { if case .bad = verify { return Icon.x }; return Icon.qr }(), size: 56, weight: 1.6)
                    .foregroundStyle(finderColor)
            }
            .frame(width: 190, height: 190)
        }
        .buttonStyle(.plain)
        .disabled(verify == .busy || verify == .ok)
        .accessibilityLabel(L("scanAria"))
    }

    // MARK: 右侧 / 下方内容

    @ViewBuilder private var content: some View {
        switch step {
        case 0: findList
        case 1: verifyForm
        case 2: wifiForm
        default: nameForm
        }
    }

    private var findList: some View {
        VStack(spacing: 8) {
            ForEach(model.session.nearby) { d in
                let on = picked == d.id
                HStack(spacing: 8) {
                    Button { picked = on ? nil : d.id } label: {
                        HStack(spacing: 12) {
                            DuckImage().frame(width: 40, height: 28)
                            Text(d.id).font(Typo.body(15, weight: .bold)).monospacedDigit().lineLimit(1)
                            Spacer(minLength: 0)
                            if d.advert.ipv4 != nil {
                                IconView(.wifi, size: 16, weight: 2).foregroundStyle(Palette.cyan).accessibilityLabel(L("onlineAria"))
                            }
                            SignalBars(level: min(3, d.bars))
                        }
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 12).frame(height: 56)
                        .background(Palette.card)
                        .selectable(on)
                    }
                    .pressable()
                    if identifyAvailable {
                        let q = quacking == d.id
                        Button {
                            quacking = d.id
                            Task { try? await Task.sleep(for: .seconds(1)); if quacking == d.id { quacking = nil } }
                        } label: {
                            VStack(spacing: 2) {
                                IconView(.quackSmall, size: 20)
                                Text(q ? L("quacked") : L("quackShort")).font(Typo.body(10, weight: .bold))
                            }
                            .foregroundStyle(q ? Palette.bg : Palette.text)
                            .frame(width: 56, height: 56)
                            .background(q ? Palette.yellow : Palette.card)
                            .overlay(Rectangle().strokeBorder(q ? Palette.bg : Color.white.opacity(0.12), lineWidth: 2))
                        }
                        .pressable()
                        .accessibilityLabel(L("quackAria", d.id))
                    }
                }
            }
        }
    }

    private var verifyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DuckImage().frame(width: 40, height: 28)
                Text(duckName).font(Typo.body(15, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 56).card()
            FieldBox(icon: .key, error: { if case .bad = verify { return true }; return false }(), height: 48) {
                TextField("", text: $code, prompt: Text("md1:…").foregroundStyle(Palette.disabled))
                    .font(Typo.mono(13))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .foregroundStyle(Palette.text)
                    .onChange(of: code) { if case .bad = verify { verify = .idle } }
                    .accessibilityLabel(L("codeAria"))
                let can = verify != .busy && verify != .ok
                Button { Task { await pair() } } label: {
                    Text(L("verifyBtn")).font(Typo.body(12, weight: .bold))
                        .foregroundStyle(can ? Palette.bg : Palette.disabled)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(can ? Palette.orange : Palette.inset)
                }
                .pressable().disabled(!can)
            }
            Text(verifyMessage.0).font(Typo.body(13, weight: .bold)).foregroundStyle(verifyMessage.1)
                .frame(minHeight: 18, alignment: .leading)
        }
    }

    private var verifyMessage: (String, Color) {
        switch verify {
        case .busy: (L("pairing"), Palette.yellow)
        case .ok: (L("verified"), Palette.cyan)
        case .bad(let m): (m, Palette.pink)
        case .idle: (code.isEmpty ? L("noCodeHint") : "", Palette.muted)
        }
    }

    private var wifiForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 6) {
                ForEach(nets, id: \.ssid) { n in
                    let on = wifiPick == n.ssid
                    Button { if !on { password = "" }; wifiPick = n.ssid; join = .idle } label: {
                        HStack(spacing: 10) {
                            IconView(.wifi, size: 18).foregroundStyle(n.signal < 30 ? Palette.muted : Palette.text)
                            Text(n.ssid).font(Typo.body(14, weight: .semibold)).lineLimit(1)
                            Spacer()
                            if n.secured { IconView(.lock, size: 16).foregroundStyle(Palette.muted) }
                        }
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(Palette.card)
                        .selectable(on)
                    }
                    .pressable()
                    .disabled(join == .busy || isJoined)
                }
            }
            if let pick = wifiPick, !isJoined, nets.first(where: { $0.ssid == pick })?.secured ?? true {
                FieldBox(icon: .lock) {
                    SecretField(placeholder: L("password"), text: $password, shown: $showPw)
                }
                .disabled(join == .busy)
            }
            Text(joinMessage.0).font(Typo.body(13, weight: .bold)).monospacedDigit().foregroundStyle(joinMessage.1)
                .frame(minHeight: 18, alignment: .leading)
        }
        .task { await scanWifi() }
    }

    private var isJoined: Bool { if case .ok = join { return true }; return false }

    private var joinMessage: (String, Color) {
        switch join {
        case .busy: (L("joining"), Palette.yellow)
        case .ok(let ip): (L("joined", ip), Palette.cyan)
        case .failed(let m): (L("joinFailed", m), Palette.pink)
        case .idle: ("", Palette.yellow)
        }
    }

    private var nameForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldBox(icon: .pen, height: 52) {
                TextField("", text: $name)
                    .font(Typo.body(17, weight: .bold)).foregroundStyle(Palette.text)
                    .onChange(of: name) { if name.count > 24 { name = String(name.prefix(24)) } }
                    .disabled(finished)
                    .accessibilityLabel(L("nameAria"))
            }
            Text(L("idLine", duckName)).font(Typo.body(11.5)).monospacedDigit().foregroundStyle(Palette.muted)
            Text(finished ? L("ready") : "").font(Typo.body(13, weight: .bold)).foregroundStyle(Palette.cyan)
                .frame(minHeight: 18)
        }
    }

    // MARK: 主按钮

    @ViewBuilder private var footer: some View {
        if finished {
            PrimaryButton(title: L("drive")) {
                model.path = [.drive]
            }
        } else if step == 1 {
            EmptyView()
        } else {
            let (label, can, act) = primary
            PrimaryButton(title: label, enabled: can, action: act)
        }
    }

    private var primary: (String, Bool, () -> Void) {
        switch step {
        case 0:
            return (L("next"), picked != nil, { model.session.stopScan(); step = 1; verify = .idle; code = "" })
        case 2:
            if isJoined { return (L("next"), true, { name = model.session.robotName.isEmpty ? duckName : model.session.robotName; step = 3 }) }
            let secured = nets.first { $0.ssid == wifiPick }?.secured ?? true
            let can = wifiPick != nil && (!secured || !password.isEmpty) && join != .busy
            return (join == .busy ? L("joining") : L("connect"), can, { Task { await joinWifi() } })
        default:
            return (L("done"), true, { Task { await finish() } })
        }
    }

    // MARK: 动作

    private func pair() async {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // 留空：没有设置码的机器人（0.17.x 的 btd 不支持安全模式），走出厂 PIN 模式。
        var setup: SetupCode?
        if !text.isEmpty {
            guard let parsed = try? parseSetupCode(text: text), setupCodeMatches(code: parsed, advertisedName: duckName) else {
                verify = .bad(L("badCode")); return
            }
            setup = parsed
        }
        verify = .busy
        do {
            try await model.session.connect(robotID: duckName, credential: setup)
            if setup != nil { SecureStore.set(text, for: SecureStore.setupCodeKey(duckName)) }
            else { SecureStore.remove(SecureStore.setupCodeKey(duckName)) }
            verify = .ok
            let online = model.session.nearby.first { $0.id == duckName }?.advert.ipv4 != nil || model.session.net?.connected == true
            try? await Task.sleep(for: .milliseconds(600))
            if online {
                // 已联网的机器人跳过配网步骤，步骤条自动打勾。
                skippedWifi = true
                name = model.session.robotName.isEmpty ? duckName : model.session.robotName
                step = 3
            } else {
                step = 2
            }
        } catch {
            verify = .bad(error.localizedDescription)
        }
    }

    private func scanWifi() async {
        if let json = try? await model.session.call(.netScan), let list = try? decodeNetScan(json: json) { nets = list }
    }

    private func joinWifi() async {
        guard let ssid = wifiPick else { return }
        join = .busy
        model.session.busy = true
        defer { model.session.busy = false }
        do {
            let json = try await model.session.call(.netConnect(ssid: ssid, password: password.isEmpty ? nil : password),
                                                    timeout: .seconds(60))
            var status = try? decodeNetStatus(json: json)
            if status == nil, let again = try? await model.session.call(.netStatus) { status = try? decodeNetStatus(json: again) }
            model.session.net = status
            join = .ok(status?.ip4 ?? "—")
        } catch {
            join = .failed(error.localizedDescription)
        }
    }

    private func finish() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var display = duckName
        if !trimmed.isEmpty, trimmed != model.session.robotName,
           let json = try? await model.session.call(.systemSetName(name: trimmed)), let stored = try? decodeSetName(json: json) {
            display = stored
            model.session.robotName = stored
        } else if !trimmed.isEmpty {
            display = trimmed
        }
        model.remember(KnownRobot(id: duckName, displayName: display, lastIPv4: model.session.net?.ip4,
                                  lastVolts: model.session.health?.batteryVolts, lastUsed: Date()))
        model.selectedID = duckName
        withAnimation { finished = true }
    }
}

/// 取景框四角（34pt、4pt 粗），以左上角为基准旋转到四个角。
private struct CornerMark: View {
    let color: Color
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 2, y: 34)); p.addLine(to: CGPoint(x: 2, y: 2)); p.addLine(to: CGPoint(x: 34, y: 2))
            }
            .stroke(color, lineWidth: 4)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }
}

/// VisionKit 扫码（iOS 16+，设备不支持时退回粘贴设置码）。
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let vc = UIHostingController(rootView: VideoPlaceholder(text: L("cameraDenied")))
            return vc
        }
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                if let s = b.payloadStringValue, s.lowercased().hasPrefix("md1:"), !done {
                    done = true
                    scanner.stopScanning()
                    onCode(s)
                }
            }
        }
    }
}
