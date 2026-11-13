import SwiftUI

/// 策略页（设计稿 PortraitPolicy / Policy）。槽位 = 平时由哪个策略驱动；技能 = 按一下才运行。
struct PolicyScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutClass) private var layout

    enum Selection: Hashable { case slot(String), skill(String), add }
    enum Pick: Hashable { case official, off, hit(String) }

    @State private var sel: Selection = .slot("walk")
    @State private var searching = false
    @State private var pick: Pick?
    @State private var job: (label: String, pct: Double)?
    @State private var status: (String, Bool)?
    @State private var query = "microduck"
    @State private var hits: [SearchHit] = []
    @State private var searchBusy = false
    @State private var updates: [PolicyUpdate]?
    @State private var checking = false

    private var session: RobotSession { model.session }
    private var policies: Policies? { session.policies }
    private var roller: Bool { policies?.mode == "roller" }
    private var busy: Bool { job != nil || session.busy }

    var body: some View {
        Screen {
            VStack(spacing: 10) {
                TitleBar(title: L("policyTitle"), back: { model.path.removeLast() }) {
                    if layout != .phonePortrait { locoToggle.frame(width: 240) }
                    SquareAction(icon: .rescan, title: checkLabel, tint: (updates?.isEmpty == false) ? Palette.bg : Palette.text,
                                 fill: (updates?.isEmpty == false) ? Palette.yellow : Palette.card, enabled: !busy && !checking) {
                        Task { await check() }
                    }
                }
                if layout == .phonePortrait {
                    locoToggle
                    tiles
                    detail.frame(maxHeight: .infinity)
                    statusLine
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 6) {
                            ScrollView { tiles }.scrollBounceBehavior(.basedOnSize)
                            statusLine
                        }
                        detail.frame(width: layout == .phoneLandscape ? 320 : nil)
                            .frame(maxWidth: layout.isWide ? .infinity : nil, maxHeight: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        }
        .task { await session.refreshPolicies() }
    }

    private var checkLabel: String {
        if checking { return L("checking") }
        guard let u = updates else { return L("check") }
        return u.isEmpty ? L("upToDate") : L("updates", u.count)
    }

    // MARK: 双腿 / 轮子

    private var locoToggle: some View {
        HStack(spacing: 2) {
            loco(L("legs"), icon: .legs, on: !roller) { Task { await setMode(.walk) } }
            loco(L("wheels"), icon: .wheel, on: roller) { Task { await setMode(.roller) } }
        }
        .padding(3)
        .card()
    }

    private func loco(_ text: String, icon: Icon, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { IconView(icon, size: 18); Text(text).font(Typo.body(13, weight: .semibold)) }
                .foregroundStyle(on ? Palette.bg : Palette.text)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? Palette.orange : .clear)
        }
        .pressable()
        .disabled(busy || on)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: 格子

    private struct Tile: Identifiable {
        let id: Selection
        let name: String
        let icon: Icon
        let sub: String
        let dot: Color
        var badge: (String, Color)?
        var unused = false
        var addTile = false
    }

    private func slotName(_ slot: String) -> String {
        switch slot {
        case "walk": roller ? L("slotSkate") : L("slotWalk")
        case "stand": L("slotStand")
        case "sitstand": L("slotSitstand")
        case "ground_pick": roller ? L("slotCrouch") : L("slotPick")
        default: slot
        }
    }

    private func slotIcon(_ slot: String) -> Icon {
        switch slot {
        case "walk": roller ? .wheel : .move
        case "stand": .stand
        case "sitstand": .sit
        default: .pick
        }
    }

    private func skillIcon(_ name: String) -> Icon {
        switch name {
        case "kick_left": .kickL
        case "kick_right": .kickR
        case "roulade": .roulade
        case let n where n.contains("bow"): .bow
        case let n where n.contains("wave"): .wave
        default: .excited
        }
    }

    private func skillName(_ name: String) -> String {
        ["kick_left": L("kickL"), "kick_right": L("kickR"), "roulade": L("roulade"), "ground_pick": L("pickUp"),
         "sit_toggle": L("slotSitstand")][name] ?? name
    }

    private func originName(_ o: Origin?) -> String {
        switch o {
        case .official: L("official")
        case .community: L("community")
        case .local: L("local")
        case .other(let n): n
        case nil: "—"
        }
    }

    private var slotTiles: [Tile] {
        let order = ["walk", "stand", "sitstand", "ground_pick"]
        return order.map { id in
            let s = policies?.slots.first { $0.slot == id }
            let unused = roller && id == "stand"
            let broken = s?.error != nil
            let shared = id == "walk" && (policies?.sharedWalkConflict ?? false)
            let upd = updates?.contains { u in s?.path.map { $0.contains(u.repo?.split(separator: "/").last.map(String.init) ?? "§") } ?? false } ?? false
            let sub: String = unused ? L("notOnWheels") : (s?.running.map { $0.replacingOccurrences(of: ".onnx", with: "") } ?? L("viaWalk"))
            var t = Tile(id: .slot(id), name: slotName(id), icon: slotIcon(id), sub: sub,
                         dot: unused ? .clear : (s?.origin != nil ? Palette.origin(s?.origin) : Palette.disabled), unused: unused)
            if !unused && (broken || shared) { t.badge = ("!", Palette.pink) }
            else if !unused && upd { t.badge = (model.lang == .zh ? "新" : "NEW", Palette.yellow) }
            return t
        }
    }

    private var skillTiles: [Tile] {
        var list = session.skills.filter { !$0.builtIn }.map { k in
            Tile(id: .skill(k.name), name: skillName(k.name), icon: skillIcon(k.name),
                 sub: k.disabled ? L("disabled") : (k.overridden ? L("community") : L("official")),
                 dot: k.disabled ? Palette.disabled : (k.overridden ? Palette.purple : Palette.orange))
        }
        list.append(Tile(id: .add, name: L("addSkill"), icon: .plus, sub: "Hugging Face", dot: .clear, addTile: true))
        return list
    }

    private var tiles: some View {
        let cols = layout.isWide ? 4 : 4
        let grid = Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: L("slotsLabel"))
            LazyVGrid(columns: grid, spacing: 8) { ForEach(slotTiles) { tile($0) } }
            SectionLabel(text: L("skillsLabel")).padding(.top, layout == .phonePortrait ? 4 : 6)
            LazyVGrid(columns: grid, spacing: 8) { ForEach(skillTiles) { tile($0) } }
        }
    }

    private func tile(_ t: Tile) -> some View {
        let on = sel == t.id
        return Button {
            sel = t.id
            pick = nil
            searching = t.id == .add
            if searching { query = "microduck"; Task { await search() } }
        } label: {
            VStack(spacing: 5) {
                IconView(t.icon, size: 20)
                    .foregroundStyle(on ? Palette.bg : Palette.text)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? Palette.orange : (t.addTile ? .clear : Palette.inset)))
                Text(t.name).font(Typo.body(12, weight: .bold)).lineLimit(1)
                HStack(spacing: 4) {
                    Dot(color: t.dot, size: 6)
                    Text(t.sub).font(Typo.body(10)).foregroundStyle(Palette.dim).lineLimit(1)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Palette.card)
            .selectable(on && !t.unused)
            .overlay(alignment: .topTrailing) {
                if let b = t.badge {
                    Text(b.0).font(Typo.body(10, weight: .heavy)).foregroundStyle(Palette.bg)
                        .padding(.horizontal, 4).frame(minWidth: 20, minHeight: 20)
                        .background(b.1).overlay(Rectangle().strokeBorder(Palette.bg, lineWidth: 2))
                        .offset(x: 7, y: -7)
                }
            }
            .opacity(t.unused ? 0.4 : 1)
        }
        .pressable()
        .disabled(busy || t.unused)
    }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searching { searchPanel }
            else if case .slot(let id) = sel { slotPanel(id) }
            else if case .skill(let name) = sel { skillPanel(name) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func header(_ icon: Icon, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 10) {
            IconView(icon, size: 24).foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Title(title, 20).lineLimit(1)
                Text(sub).font(Typo.body(11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
        }
    }

    private func banner(_ text: String, color: Color, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(Typo.body(11.5, weight: .bold)).foregroundStyle(Palette.bg).frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                Button(action: action) {
                    Text(button).font(Typo.body(12, weight: .bold)).foregroundStyle(Palette.text)
                        .padding(.horizontal, 10).frame(height: 28).background(Palette.bg)
                }
                .pressable().disabled(busy)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 7)
        .background(color)
        .overlay(Rectangle().strokeBorder(Palette.bg, lineWidth: 2))
    }

    @ViewBuilder private func slotPanel(_ id: String) -> some View {
        let slot = policies?.slots.first { $0.slot == id }
        let runningName = slot?.running?.replacingOccurrences(of: ".onnx", with: "") ?? L("viaWalk")
        header(slotIcon(id), slotName(id), L("runningLine", runningName, originName(slot?.origin)))
        if let err = slot?.error {
            banner(L("bannerBroken", runningName) + " " + err, color: Palette.pink, button: L("resetOfficial")) {
                Task { await load(slot: id, target: .official, label: L("official")) }
            }
        } else if id == "walk", policies?.sharedWalkConflict == true {
            banner(L("sharedOverride", runningName), color: Palette.yellow, button: L("resetOfficial")) {
                Task { await load(slot: id, target: .official, label: L("official")) }
            }
        } else if id == "sitstand", roller {
            banner(L("rollerSit"), color: Palette.yellow, button: nil) {}
        }
        ScrollView {
            VStack(spacing: 5) {
                option(.official, name: officialName(id), sub: L("official"), icon: .official, color: Palette.orange,
                       running: slot?.overridden == false && slot?.path != nil)
                ForEach(hits.filter { model.allowCommunity || $0.origin == .official }, id: \.repo) { h in
                    option(.hit(h.repo), name: h.repo.split(separator: "/").last.map(String.init) ?? h.repo,
                           sub: originName(h.origin) + " · " + h.repo, icon: h.origin == .community ? .people : .file,
                           color: Palette.origin(h.origin), running: slot?.path?.contains(h.repo.split(separator: "/").last.map(String.init) ?? "§") == true)
                }
                if id != "walk" && id != "stand" {
                    option(.off, name: L("slotOff"), sub: L("slotOffSub"), icon: .ban, color: Palette.dim, running: slot?.path == nil)
                }
                Button { searching = true; Task { await search() } } label: {
                    HStack(spacing: 8) { IconView(.search, size: 16); Text(L("findMore")).font(Typo.body(12, weight: .semibold)) }
                        .foregroundStyle(Palette.light)
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .overlay(Rectangle().strokeBorder(Palette.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                }
                .pressable().disabled(busy)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        let driving = id == "walk" || (id == "stand" && !roller)
        Text(driving ? L("impactHome") : L("impactLive")).font(Typo.body(11)).foregroundStyle(Palette.dim)
        let (label, can) = applyState(id, slot)
        PrimaryButton(title: job?.label ?? label, enabled: can && !busy, height: 46, fontSize: 16, progress: job?.pct) {
            guard let pick else { return }
            Task {
                switch pick {
                case .official: await load(slot: id, target: .official, label: L("official"))
                case .off: await load(slot: id, target: .off, label: L("slotOff"))
                case .hit(let repo): await fetchAndLoad(slot: id, repo: repo)
                }
            }
        }
    }

    private func officialName(_ id: String) -> String {
        switch (id, roller) {
        case ("walk", false): "velstand"
        case ("walk", true): "roller"
        case ("sitstand", _): "alpha_sitstand"
        case ("ground_pick", false): "alpha_ground_pick"
        case ("ground_pick", true): "roller_crouch"
        default: L("viaWalk")
        }
    }

    /// 请求本来就成立时不做事：主按钮显示"正在运行"并置灰；唯一例外是开机加载失败的槽位。
    private func applyState(_ id: String, _ slot: PolicySlot?) -> (String, Bool) {
        switch pick {
        case nil: return (L("current"), false)
        case .official:
            let already = slot?.overridden == false && slot?.error == nil
            return (already ? L("current") : L("resetOfficial"), !already)
        case .off: return (L("turnOff"), slot?.path != nil)
        case .hit: return (L("load"), true)
        }
    }

    private func option(_ p: Pick, name: String, sub: String, icon: Icon, color: Color, running: Bool) -> some View {
        let on = pick == p
        return Button { pick = p } label: {
            HStack(spacing: 9) {
                IconView(icon, size: 15).foregroundStyle(color)
                    .frame(width: 26, height: 26).background(Circle().fill(Palette.inset))
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(Typo.body(12.5, weight: .semibold)).lineLimit(1)
                    Text(sub).font(Typo.body(10.5)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if running {
                    Text(L("running")).font(Typo.body(10, weight: .heavy)).foregroundStyle(Palette.bg)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Palette.cyan)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 9).frame(minHeight: 42)
            .background(on ? Palette.inset : Palette.card)
            .overlay(Rectangle().strokeBorder(on ? Palette.orange : Palette.hairline, lineWidth: 1.5))
        }
        .pressable()
        .disabled(busy)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder private func skillPanel(_ name: String) -> some View {
        let k = session.skills.first { $0.name == name }
        header(skillIcon(name), skillName(name), name)
        VStack(spacing: 0) {
            row(L("source"), k?.overridden == true ? L("community") : L("official") + " · " + L("builtIn"))
            row(L("kind"), L("oneShot"))
            row(L("duration"), k?.duration.map { String(format: "%.1f s", $0) } ?? "—")
            row(L("state"), k?.disabled == true ? L("disabled") : L("enabled"))
        }
        Spacer()
        Button { model.path.append(.gamepad) } label: {
            HStack(spacing: 8) { IconView(.gamepad, size: 18); Text(L("bindPad")).font(Typo.body(12, weight: .semibold)).underline() }
                .foregroundStyle(Palette.light)
        }
        .buttonStyle(.plain)
        HStack(spacing: 8) {
            let disabled = k?.disabled == true
            let toggleColor = disabled ? Palette.cyan : Palette.pink
            Button {
                Task {
                    job = (L("sSkill"), 0.5)
                    if k?.overridden == true { _ = await session.intent(.robotRemoveSkill(name: name)) }
                    else if disabled { _ = await session.intent(.robotAddSkill(name: name, path: k?.path ?? "", duration: k?.duration ?? 2)) }
                    else { _ = await session.intent(.robotDisableSkill(name: name)) }
                    await session.refreshPolicies()
                    job = nil
                }
            } label: {
                Text(k?.overridden == true ? L("removeSkill") : disabled ? L("enableSkill") : L("disableSkill"))
                    .font(Typo.body(13, weight: .bold)).foregroundStyle(toggleColor)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .overlay(Rectangle().strokeBorder(toggleColor, lineWidth: 1.5))
            }
            .pressable().disabled(busy)
            PrimaryButton(title: L("tryIt"), enabled: !busy && k?.disabled != true, height: 46, fontSize: 16) {
                Task {
                    status = (L("trying", skillName(name)), false)
                    if let r = await session.intent(.robotDo(skill: name)) { status = (r, true) }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Palette.dim)
            Spacer()
            Text(v).font(Typo.body(12, weight: .semibold)).lineLimit(1)
        }
        .font(Typo.body(12))
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    // MARK: 搜索

    @ViewBuilder private var searchPanel: some View {
        let forSkill = sel == .add
        HStack(spacing: 8) {
            Button { searching = false; if forSkill { sel = .slot("walk") } } label: {
                IconView(.back, size: 16, weight: 2.2).foregroundStyle(Palette.text)
                    .frame(width: 32, height: 32).background(Circle().fill(Palette.inset))
            }
            .pressable().accessibilityLabel(L("back"))
            Title(forSkill ? L("addSkill") : { if case .slot(let id) = sel { return L("findFor", slotName(id)) }; return "" }(), 17)
                .lineLimit(1)
        }
        FieldBox(icon: .search, height: 36) {
            TextField("", text: $query).font(Typo.body(13)).foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await search() } }
                .accessibilityLabel(L("searchAria"))
        }
        @Bindable var m = model
        Toggle(isOn: $m.allowCommunity) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("allow")).font(Typo.body(12, weight: .bold))
                Text(L("allowSub")).font(Typo.body(10.5)).foregroundStyle(Palette.dim)
            }
        }
        .toggleStyle(CheckStyle())
        ScrollView {
            VStack(spacing: 6) {
                ForEach(hits, id: \.repo) { h in result(h, forSkill: forSkill) }
                if hits.isEmpty && !searchBusy {
                    Text(L("noResults")).font(Typo.body(12)).foregroundStyle(Palette.dim).padding(16)
                }
                if searchBusy { ProgressView().tint(Palette.orange).padding(16) }
            }
        }
        if forSkill { Text(L("skillRule")).font(Typo.body(10.5)).foregroundStyle(Palette.dim) }
    }

    private func result(_ h: SearchHit, forSkill: Bool) -> some View {
        let community = h.origin == .community
        let blocked = community && !model.allowCommunity
        let label = blocked ? L("needAllow") : forSkill ? L("getSkill") : L("getLoad")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Dot(color: Palette.origin(h.origin))
                VStack(alignment: .leading, spacing: 0) {
                    Text(h.repo.split(separator: "/").last.map(String.init) ?? h.repo).font(Typo.body(12.5, weight: .bold)).lineLimit(1)
                    Text(h.repo).font(Typo.body(10.5)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    Task {
                        if forSkill { await addSkill(repo: h.repo) }
                        else if case .slot(let id) = sel { await fetchAndLoad(slot: id, repo: h.repo) }
                    }
                } label: {
                    Text(label).font(Typo.body(11.5, weight: .bold))
                        .foregroundStyle(blocked ? Palette.disabled : Palette.bg)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(blocked ? Palette.inset : Palette.orange)
                        .overlay(Rectangle().strokeBorder(blocked ? .clear : Palette.bg, lineWidth: 2))
                }
                .pressable().disabled(blocked || busy)
            }
            if let d = h.description { Text(d).font(Typo.body(11)).foregroundStyle(Palette.light) }
            if blocked { Text(L("needAllowNote")).font(Typo.body(11, weight: .bold)).foregroundStyle(Palette.purple) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.result)
    }

    // MARK: 底部状态

    private var statusLine: some View {
        let walk = policies?.slots.first { $0.slot == "walk" }?.running?.replacingOccurrences(of: ".onnx", with: "") ?? "—"
        let (text, color): (String, Color) = if let job { (job.label, Palette.yellow) }
            else if let status { (status.0, status.1 ? Palette.pink : Palette.cyan) }
            else { (L("robotState", walk), Palette.dim) }
        return HStack(spacing: 8) {
            Dot(color: job != nil ? Palette.yellow : status?.1 == true ? Palette.pink : Palette.cyan)
            Text(text).lineLimit(1)
        }
        .font(Typo.body(12, weight: .semibold))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: 动作

    private func say(_ text: String, warn: Bool = false) {
        status = (text, warn)
        Task { try? await Task.sleep(for: .seconds(3)); if status?.0 == text { status = nil } }
    }

    private func check() async {
        checking = true
        if let json = try? await session.call(.policyCheck, timeout: .seconds(30)) { updates = (try? decodePolicyCheck(json: json)) ?? [] }
        checking = false
        if updates?.isEmpty == true { say(L("checkDone0")) }
    }

    private func setMode(_ mode: LocoMode) async {
        job = (L("sMode"), 0.5)
        session.busy = true
        let r = await session.intent(.robotSetMode(mode: mode))
        await session.refreshPolicies()
        session.busy = false
        job = nil
        if let r { say(r, warn: true) } else { say(L("modeDone", mode == .roller ? L("wheels") : L("legs"))) }
    }

    private func search() async {
        searchBusy = true
        if let json = try? await session.call(.policySearch(query: query), timeout: .seconds(30)) {
            hits = (try? decodePolicySearch(json: json)) ?? []
        }
        searchBusy = false
    }

    /// 加载：失败保留原策略（机器人保证），界面展示原因、不改变"正在运行"。
    private func load(slot: String, target: SlotTarget, label: String, steps: [String] = []) async {
        let driving = slot == "walk" || (slot == "stand" && !roller)
        let all = steps + (driving ? [L("sHome")] : []) + [L("sSwap")]
        let before = policies?.slots.first { $0.slot == slot }?.running ?? "—"
        session.busy = true
        defer { session.busy = false; job = nil }
        for (i, s) in all.dropLast().enumerated() { job = (s, Double(i + 1) / Double(all.count + 1)) }
        job = (all.last!, Double(all.count) / Double(all.count + 1))
        if let r = await session.intent(.robotLoadPolicy(slot: slot, target: target)) {
            say(L("loadFailed", r, before), warn: true)
        } else {
            await session.refreshPolicies()
            say(target == .official ? L("fixed", slotName(slot)) : L("loaded", slotName(slot), label))
            pick = nil
        }
    }

    private func fetchAndLoad(slot: String, repo: String) async {
        job = (L("sDownload"), 0.2)
        session.busy = true
        guard let json = try? await session.call(.policyFetch(repo: repo, revision: nil), timeout: .seconds(120)),
              let fetched = try? decodePolicyFetch(json: json) else {
            session.busy = false; job = nil
            return say(L("loadFailed", repo, policies?.slots.first { $0.slot == slot }?.running ?? "—"), warn: true)
        }
        searching = false
        await load(slot: slot, target: .file(path: fetched.path), label: fetched.name ?? repo, steps: [L("sCheck")])
    }

    private func addSkill(repo: String) async {
        job = (L("sDownload"), 0.3)
        session.busy = true
        defer { session.busy = false; job = nil }
        guard let json = try? await session.call(.policyFetch(repo: repo, revision: nil), timeout: .seconds(120)),
              let f = try? decodePolicyFetch(json: json) else { return say(L("noResults"), warn: true) }
        if let enc = f.encoding, enc == "phase" || enc == "posture_flag" { return say(L("badPhase"), warn: true) }
        job = (L("sSkill"), 0.8)
        let name = f.name ?? repo.split(separator: "/").last.map(String.init) ?? repo
        if let r = await session.intent(.robotAddSkill(name: name, path: f.path, duration: f.durationS ?? 3)) { return say(r, warn: true) }
        await session.refreshPolicies()
        sel = .skill(name)
        searching = false
        say(name)
    }
}

/// 复选框（18pt，橙色）。
struct CheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                IconView(.check, size: 14, weight: 2.6)
                    .foregroundStyle(configuration.isOn ? Palette.bg : .clear)
                    .frame(width: 18, height: 18)
                    .background(configuration.isOn ? Palette.orange : .clear)
                    .overlay(Rectangle().strokeBorder(configuration.isOn ? Palette.orange : Palette.field, lineWidth: 1.5))
                    .padding(.top, 1)
                configuration.label.foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
