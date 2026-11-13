import SwiftUI

/// 设置页（设计稿 PortraitNetwork / Network）：网络 / 语音 / 语言 三个标签。
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout

    enum Tab: Hashable { case net, voice, lang }
    @State private var tab = Tab.net

    var body: some View {
        Screen {
            VStack(spacing: 14) {
                TitleBar(title: L("settingsTitle"), back: { model.path.removeLast() }) {
                    if layout != .phonePortrait { tabs }
                }
                if layout == .phonePortrait { tabs.frame(maxWidth: .infinity, alignment: .leading) }
                switch tab {
                case .net: NetworkTab()
                case .voice: VoiceTab()
                case .lang: LanguageTab().frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        }
    }

    private var tabs: some View {
        ChoiceChips(options: [(Tab.net, L("tabNet"), Icon.wifi), (.voice, L("tabVoice"), .mic), (.lang, L("tabLang"), .globe)],
                    selection: $tab, badge: { $0 == .voice && model.doubaoKey == nil })
    }
}

// MARK: - 网络

private struct NetworkTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @State private var nets: [WifiNetwork] = []
    @State private var pick: String?
    @State private var password = ""
    @State private var showPw = false
    @State private var busy = false
    @State private var line: (String, Color)?

    private var session: RobotSession { model.session }

    var body: some View {
        Group {
            if layout == .phonePortrait {
                VStack(spacing: 14) {
                    current
                    ScrollView { others }.scrollBounceBehavior(.basedOnSize)
                }
            } else {
                TwoPane(primaryFraction: 0.42) {
                    VStack { current; Spacer(minLength: 0) }
                } secondary: {
                    ScrollView { others }.scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .task { await scan() }
    }

    private var current: some View {
        let net = session.net
        let connected = net?.connected == true
        let sig = net?.signal.map { $0 >= 66 ? L("sigStrong") : $0 >= 33 ? L("sigFair") : L("sigWeak") } ?? ""
        let (text, color): (String, Color) = line ?? (connected ? (L("online", net?.ip4 ?? "—", sig), Palette.cyan) : (L("offline"), Palette.dim))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconView(.wifi, size: 26).foregroundStyle(color)
                    .frame(width: 52, height: 52).background(Circle().fill(Palette.inset))
                VStack(alignment: .leading, spacing: 2) {
                    Text(net?.ssid ?? "—").font(Typo.body(18, weight: .bold)).lineLimit(1)
                    Text(text).font(Typo.body(12, weight: .bold)).monospacedDigit().foregroundStyle(color).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                IconView(.bt, size: 16).foregroundStyle(Palette.cyan)
                Text(L("btLine")).font(Typo.body(12)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Button { Task { await reconnect() } } label: {
                HStack(spacing: 8) { IconView(.rescan, size: 18); Text(busy ? L("reconnecting") : L("reconnect")).font(Typo.body(14, weight: .bold)) }
                    .foregroundStyle(busy ? Palette.disabled : Palette.text)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Rectangle().strokeBorder(busy ? Palette.inset : Palette.dashed, lineWidth: 1.5))
            }
            .pressable().disabled(busy || net?.ssid == nil)
        }
        .foregroundStyle(Palette.text)
        .padding(14)
        .card()
    }

    private var others: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel(text: L("others"))
                Button { Task { await scan() } } label: {
                    IconView(.rescan, size: 15).foregroundStyle(Palette.light)
                        .frame(width: 30, height: 30).overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                }
                .pressable().disabled(busy).accessibilityLabel(L("rescan"))
            }
            ForEach(nets.filter { $0.ssid != session.net?.ssid }, id: \.ssid) { n in
                let on = pick == n.ssid
                Button { if !on { password = "" }; pick = n.ssid } label: {
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
                .pressable().disabled(busy)
            }
            if let pick {
                let secured = nets.first { $0.ssid == pick }?.secured ?? true
                let saved = nets.first { $0.ssid == pick }?.saved ?? false
                let can = !busy && (!secured || saved || !password.isEmpty)
                HStack(spacing: 8) {
                    if secured && !saved {
                        FieldBox(icon: .lock) { SecretField(placeholder: L("password"), text: $password, shown: $showPw) }
                    }
                    Button { Task { await join(pick) } } label: {
                        Title(busy ? L("joining") : L("join"), 16)
                            .foregroundStyle(can ? Palette.bg : Palette.disabled)
                            .padding(.horizontal, 18).frame(minWidth: secured && !saved ? nil : 120, minHeight: 44)
                            .background(can ? Palette.orange : Palette.inset)
                            .overlay(Rectangle().strokeBorder(can ? Palette.bg : .clear, lineWidth: 2))
                            .hardShadow(can ? Palette.yellow : .clear)
                    }
                    .pressable().disabled(!can)
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.bottom, 6)
    }

    private func scan() async {
        if let json = try? await session.call(.netScan, timeout: .seconds(20)), let list = try? decodeNetScan(json: json) { nets = list }
        if let json = try? await session.call(.netStatus) { session.net = try? decodeNetStatus(json: json) }
    }

    /// 重连当前网络（已保存配置，不需要密码）。期间视频暂停，控制走蓝牙不受影响。
    private func reconnect() async {
        guard let ssid = session.net?.ssid else { return }
        busy = true
        session.media.close()
        line = (L("reconnecting"), Palette.yellow)
        let r = try? await session.call(.netConnect(ssid: ssid, password: nil), timeout: .seconds(60))
        await refreshAfterJoin()
        line = r != nil ? (L("reconnected"), Palette.cyan) : nil
        busy = false
        try? await Task.sleep(for: .seconds(2)); line = nil
    }

    private func join(_ ssid: String) async {
        busy = true
        session.busy = true
        session.media.close()
        line = (L("joining"), Palette.yellow)
        do {
            _ = try await session.call(.netConnect(ssid: ssid, password: password.isEmpty ? nil : password), timeout: .seconds(60))
            await refreshAfterJoin()
            line = (L("joinedNet", ssid), Palette.cyan)
            pick = nil; password = ""
            await scan()
        } catch {
            line = (L("joinFailed", error.localizedDescription), Palette.pink)
        }
        session.busy = false
        busy = false
    }

    /// 换网后由 net.status 拿到新 IP，自动重建视频。
    private func refreshAfterJoin() async {
        if let json = try? await session.call(.netStatus) { session.net = try? decodeNetStatus(json: json) }
        if let ip = session.net?.ip4 { session.media.open(ip: ip, session: session) }
    }
}

// MARK: - 语音

private struct VoiceTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout
    @State private var method = DoubaoKey.Method.apiKey
    @State private var key = ""
    @State private var appID = ""
    @State private var shown = false
    @State private var editing = false
    @State private var testing = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        let saved = model.doubaoKey
        let content = VStack(alignment: .leading, spacing: 12) {
            keyCard(saved)
            if layout == .phonePortrait { speakRow; privacy }
        }
        Group {
            if layout == .phonePortrait {
                ScrollView { content }.scrollBounceBehavior(.basedOnSize)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                    VStack(spacing: 12) { speakRow; privacy }.frame(width: 270)
                }
            }
        }
    }

    private var chip: (String, Color) {
        guard model.doubaoKey != nil else { return (L("keyNone"), Palette.muted) }
        return model.doubaoInvalid ? (L("keyBad"), Palette.pink) : (L("keyOk"), Palette.cyan)
    }

    private func keyCard(_ saved: DoubaoKey?) -> some View {
        let isEditing = saved == nil || editing
        let (chipText, chipColor) = chip
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconView(.mic, size: 16).foregroundStyle(Palette.yellow)
                    .frame(width: 32, height: 32).background(Circle().fill(Palette.inset))
                Title(L("doubao"), 18).lineLimit(1)
                Spacer()
                HStack(spacing: 6) { Dot(color: chipColor, size: 7); Text(chipText) }
                    .font(Typo.body(12, weight: .bold)).foregroundStyle(chipColor)
                    .padding(.horizontal, 10).frame(height: 24)
                    .overlay(Rectangle().strokeBorder(chipColor))
            }
            if isEditing {
                HStack(spacing: 8) {
                    methodButton(.apiKey, L("keyMethodNew"), L("keyMethodNewSub"))
                    methodButton(.appToken, L("keyMethodOld"), L("keyMethodOldSub"))
                }
                if method == .appToken {
                    FieldBox(icon: .key, error: error != nil) {
                        SecretField(placeholder: L("fApp"), text: $appID, shown: $shown, mono: true)
                    }
                }
                FieldBox(icon: .key, error: error != nil) {
                    SecretField(placeholder: method == .apiKey ? L("fKey") : L("fTok"), text: $key, shown: $shown, mono: true)
                }
                HStack(spacing: 8) {
                    Text(testing ? L("testing") : error ?? L("keyWhere")).font(Typo.body(11)).lineSpacing(2)
                        .foregroundStyle(error != nil ? Palette.pink : testing ? Palette.yellow : Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        if let s = UIPasteboard.general.string { key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: {
                        HStack(spacing: 6) { IconView(.paste, size: 14); Text(L("paste")) }
                            .font(Typo.body(12, weight: .semibold)).foregroundStyle(Palette.light)
                            .padding(.horizontal, 10).frame(height: 30)
                            .overlay(Rectangle().strokeBorder(Palette.field))
                    }
                    .pressable().disabled(testing)
                }
                HStack(spacing: 8) {
                    if saved != nil {
                        Button { editing = false; key = ""; appID = ""; error = nil } label: {
                            Text(L("cancel")).font(Typo.body(14, weight: .bold)).foregroundStyle(Palette.text)
                                .padding(.horizontal, 16).frame(height: 44)
                                .overlay(Rectangle().strokeBorder(Palette.dashed, lineWidth: 1.5))
                        }
                        .pressable().disabled(testing)
                    }
                    let filled = !key.trimmingCharacters(in: .whitespaces).isEmpty && (method == .apiKey || !appID.isEmpty)
                    PrimaryButton(title: testing ? L("testing") : L("testSave"), enabled: filled && !testing, height: 44, fontSize: 17) {
                        Task { await test() }
                    }
                }
            } else if let saved {
                HStack(spacing: 10) {
                    IconView(.key, size: 16).foregroundStyle(Palette.dim)
                    Text(saved.method == .apiKey ? L("keyMethodNew") : L("keyMethodOld")).font(Typo.body(12)).foregroundStyle(Palette.dim)
                    Text(saved.masked).font(Typo.body(15, weight: .bold)).tracking(0.9).monospacedDigit().lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Palette.bg)
                .overlay(Rectangle().strokeBorder(model.doubaoInvalid ? Palette.pink : Palette.field))
                Text(model.doubaoInvalid ? L("badNote") : L("okNote")).font(Typo.body(11)).lineSpacing(2)
                    .foregroundStyle(model.doubaoInvalid ? Palette.pink : Palette.dim)
                HStack(spacing: 8) {
                    Button { editing = true; method = saved.method } label: {
                        Text(L("replace")).font(Typo.body(14, weight: .bold)).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(Rectangle().strokeBorder(Palette.dashed, lineWidth: 1.5))
                    }
                    .pressable()
                    Button {
                        if confirmDelete { model.saveDoubaoKey(nil); confirmDelete = false }
                        else { confirmDelete = true; Task { try? await Task.sleep(for: .seconds(3)); confirmDelete = false } }
                    } label: {
                        Text(confirmDelete ? L("delSure") : L("delKey")).font(Typo.body(14, weight: .bold))
                            .foregroundStyle(confirmDelete ? Palette.bg : Palette.pink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(confirmDelete ? Palette.pink : .clear)
                            .overlay(Rectangle().strokeBorder(Palette.pink, lineWidth: 1.5))
                    }
                    .pressable()
                }
            }
        }
        .foregroundStyle(Palette.text)
        .padding(14)
        .card()
    }

    private func methodButton(_ m: DoubaoKey.Method, _ name: String, _ sub: String) -> some View {
        let on = method == m
        return Button { method = m; error = nil } label: {
            VStack(spacing: 0) {
                Text(name).font(Typo.body(13, weight: .bold)).lineLimit(1)
                Text(sub).font(Typo.body(10)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Palette.inset)
            .selectable(on)
        }
        .pressable().disabled(testing)
    }

    private var speakRow: some View {
        let enabled = model.doubaoKey != nil
        @Bindable var m = model
        return HStack(spacing: 10) {
            IconView(.speaker, size: 20).foregroundStyle(enabled && model.speakReplies ? Palette.cyan : Palette.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(L("speak")).font(Typo.body(14, weight: .bold)).lineLimit(1)
                Text(enabled ? L("spkOn") : L("spkNo")).font(Typo.body(11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer()
            Button { model.speakReplies.toggle() } label: {
                ZStack(alignment: model.speakReplies && enabled ? .trailing : .leading) {
                    Capsule().fill(model.speakReplies && enabled ? Palette.orange : Palette.inset)
                    Circle().fill(enabled ? (model.speakReplies ? Palette.bg : Palette.dim) : Palette.disabled)
                        .frame(width: 20, height: 20).padding(3)
                }
                .frame(width: 46, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(L("speak"))
            .accessibilityValue(model.speakReplies ? "1" : "0")
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 14).frame(minHeight: 56)
        .card()
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(.shield, size: 16)
            Text(L("priv")).font(Typo.body(11)).lineSpacing(2)
        }
        .foregroundStyle(Palette.muted)
    }

    /// 测试并保存：用待保存的凭证实际建一次会话，收到 session.created 才写入 Keychain。
    private func test() async {
        testing = true
        error = nil
        let candidate = DoubaoKey(method: method, key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                  appID: method == .appToken ? appID.trimmingCharacters(in: .whitespaces) : nil)
        let result = model.session.isDemo ? .ok : await DoubaoTester.test(candidate.credential)
        testing = false
        switch result {
        case .ok:
            model.saveDoubaoKey(candidate)
            editing = false; key = ""; appID = ""
        case .badKey: error = L("errKey")
        case .notEnabled: error = L("errNotEnabled")
        case .network: error = L("errNet")
        }
    }
}

/// 一次性连接豆包验证密钥（超时 10 s）。
enum DoubaoTester {
    enum Result { case ok, badKey, notEnabled, network }

    static func test(_ credential: DoubaoCredential) async -> Result {
        var req = URLRequest(url: URL(string: doubaoUrl())!)
        for h in doubaoHeaders(credential: credential, requestId: UUID().uuidString) { req.setValue(h.value, forHTTPHeaderField: h.name) }
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        let turn = VoiceTurn()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do {
                    try await task.send(.string(turn.sessionCreate(sessionId: UUID().uuidString, duckName: "duck", skills: [])))
                    while true {
                        let msg = try await task.receive()
                        guard case .string(let text) = msg else { continue }
                        if text.contains("\"session.created\"") {
                            try? await task.send(.string(turn.sessionClose()))
                            return .ok
                        }
                        if text.contains("\"error\"") {
                            return text.lowercased().contains("auth") || text.contains("401") || text.contains("403") ? .badKey : .notEnabled
                        }
                    }
                } catch {
                    if let http = task.response as? HTTPURLResponse, [401, 403].contains(http.statusCode) { return .badKey }
                    return .network
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return .network }
            let r = await group.next() ?? .network
            group.cancelAll()
            return r
        }
    }
}

// MARK: - 语言

private struct LanguageTab: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconView(.globe, size: 14).foregroundStyle(Palette.cyan)
                Text(L("langLabel")).font(Typo.body(11, weight: .bold)).tracking(0.44).foregroundStyle(Palette.dim)
            }
            HStack(spacing: 8) {
                ForEach([(Lang.zh, "中文"), (.en, "English")], id: \.0) { lang, name in
                    let on = model.lang == lang
                    Button { model.lang = lang } label: {
                        Text(name).font(Typo.body(14, weight: .bold)).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Palette.inset)
                            .selectable(on)
                    }
                    .pressable()
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
    }
}
