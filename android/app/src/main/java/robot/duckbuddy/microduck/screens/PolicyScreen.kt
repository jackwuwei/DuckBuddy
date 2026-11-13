package robot.duckbuddy.microduck.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.LocalModel
import robot.duckbuddy.microduck.ScreenFrame
import robot.duckbuddy.microduck.Lang
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.state.Route
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.duck_core.*

private sealed class Sel { data class Slot(val id: String) : Sel(); data class Skill(val name: String) : Sel(); object Add : Sel() }
private sealed class Pick { object Official : Pick(); object Off : Pick(); data class Hit(val repo: String) : Pick() }
private data class Tile(val sel: Sel, val name: String, val icon: Icon, val sub: String, val dot: Color,
                        val badge: Pair<String, Color>? = null, val unused: Boolean = false, val add: Boolean = false)

/** 策略页（设计稿 PortraitPolicy / Policy），与 iOS `PolicyScreen.swift` 同一套规则。 */
@Composable
fun PolicyScreen() {
    val model = LocalModel.current
    val session = model.session
    val layout = LocalLayout.current
    val scope = rememberCoroutineScope()
    var sel by remember { mutableStateOf<Sel>(Sel.Slot("walk")) }
    var searching by remember { mutableStateOf(false) }
    var pick by remember { mutableStateOf<Pick?>(null) }
    var job by remember { mutableStateOf<Pair<String, Float>?>(null) }
    var status by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    var query by remember { mutableStateOf("microduck") }
    var hits by remember { mutableStateOf<List<SearchHit>>(emptyList()) }
    var searchBusy by remember { mutableStateOf(false) }
    var updates by remember { mutableStateOf<List<PolicyUpdate>?>(null) }
    var checking by remember { mutableStateOf(false) }
    val policies = session.policies
    val roller = policies?.mode == "roller"
    val busy = job != null || session.busy
    LaunchedEffect(Unit) { session.refreshPolicies() }

    fun say(t: String, warn: Boolean = false) { status = t to warn; scope.launch { delay(3000); if (status?.first == t) status = null } }
    fun slotName(s: String) = when (s) {
        "walk" -> if (roller) L("slotSkate") else L("slotWalk"); "stand" -> L("slotStand"); "sitstand" -> L("slotSitstand")
        "ground_pick" -> if (roller) L("slotCrouch") else L("slotPick"); else -> s
    }
    fun slotIcon(s: String) = when (s) { "walk" -> if (roller) Icon.WHEEL else Icon.MOVE; "stand" -> Icon.STAND; "sitstand" -> Icon.SIT; else -> Icon.PICK }
    fun skillIcon(n: String) = when { n == "kick_left" -> Icon.KICK_L; n == "kick_right" -> Icon.KICK_R; n == "roulade" -> Icon.ROULADE
        n.contains("bow") -> Icon.BOW; n.contains("wave") -> Icon.WAVE; else -> Icon.EXCITED }
    fun skillName(n: String) = mapOf("kick_left" to L("kickL"), "kick_right" to L("kickR"), "roulade" to L("roulade"),
        "ground_pick" to L("pickUp"), "sit_toggle" to L("slotSitstand"))[n] ?: n
    fun originName(o: Origin?) = when (o) { is Origin.Official -> L("official"); is Origin.Community -> L("community"); is Origin.Local -> L("local")
        is Origin.Other -> o.name; null -> "—" }
    fun officialName(id: String) = when (id to roller) { "walk" to false -> "velstand"; "walk" to true -> "roller"; "sitstand" to false, "sitstand" to true -> "alpha_sitstand"
        "ground_pick" to false -> "alpha_ground_pick"; "ground_pick" to true -> "roller_crouch"; else -> L("viaWalk") }

    fun search() = scope.launch {
        searchBusy = true
        runCatching { hits = decodePolicySearch(session.call(DuckCall.PolicySearch(query), 30_000)) }
        searchBusy = false
    }

    suspend fun load(slot: String, target: SlotTarget, label: String, steps: List<String> = emptyList()) {
        val driving = slot == "walk" || (slot == "stand" && !roller)
        val all = steps + (if (driving) listOf(L("sHome")) else emptyList()) + L("sSwap")
        val before = policies?.slots?.firstOrNull { it.slot == slot }?.running ?: "—"
        session.busy = true
        all.forEachIndexed { i, s -> job = s to (i + 1f) / (all.size + 1) }
        val r = session.intent(DuckCall.RobotLoadPolicy(slot, target))
        if (r != null) say(L("loadFailed", r, before), true)
        else { session.refreshPolicies(); say(if (target is SlotTarget.Official) L("fixed", slotName(slot)) else L("loaded", slotName(slot), label)); pick = null }
        session.busy = false; job = null
    }

    suspend fun fetchAndLoad(slot: String, repo: String) {
        job = L("sDownload") to 0.2f
        session.busy = true
        val f = runCatching { decodePolicyFetch(session.call(DuckCall.PolicyFetch(repo, null), 120_000)) }.getOrNull()
        if (f == null) { session.busy = false; job = null; return say(L("loadFailed", repo, policies?.slots?.firstOrNull { it.slot == slot }?.running ?: "—"), true) }
        searching = false
        load(slot, SlotTarget.File(f.path), f.name ?: repo, listOf(L("sCheck")))
    }

    suspend fun addSkill(repo: String) {
        job = L("sDownload") to 0.3f
        session.busy = true
        try {
            val f = runCatching { decodePolicyFetch(session.call(DuckCall.PolicyFetch(repo, null), 120_000)) }.getOrNull() ?: return say(L("noResults"), true)
            if (f.encoding == "phase" || f.encoding == "posture_flag") return say(L("badPhase"), true)
            job = L("sSkill") to 0.8f
            val name = f.name ?: repo.substringAfterLast('/')
            session.intent(DuckCall.RobotAddSkill(name, f.path, f.durationS ?: 3.0))?.let { return say(it, true) }
            session.refreshPolicies()
            sel = Sel.Skill(name); searching = false; say(name)
        } finally { session.busy = false; job = null }
    }

    val slotTiles = listOf("walk", "stand", "sitstand", "ground_pick").map { id ->
        val s = policies?.slots?.firstOrNull { it.slot == id }
        val unused = roller && id == "stand"
        val broken = s?.error != null
        val shared = id == "walk" && policies?.sharedWalkConflict == true
        val upd = updates?.any { u -> s?.path?.contains(u.repo?.substringAfterLast('/') ?: "§") == true } == true
        Tile(Sel.Slot(id), slotName(id), slotIcon(id), if (unused) L("notOnWheels") else s?.running?.removeSuffix(".onnx") ?: L("viaWalk"),
            if (unused) Color.Transparent else if (s?.origin != null) Palette.origin(s.origin) else Palette.disabled,
            if (unused) null else if (broken || shared) "!" to Palette.pink else if (upd) (if (model.lang == Lang.zh) "新" else "NEW") to Palette.yellow else null, unused)
    }
    val skillTiles = session.skills.filter { !it.builtIn }.map { k ->
        Tile(Sel.Skill(k.name), skillName(k.name), skillIcon(k.name), if (k.disabled) L("disabled") else if (k.overridden) L("community") else L("official"),
            if (k.disabled) Palette.disabled else if (k.overridden) Palette.purple else Palette.orange)
    } + Tile(Sel.Add, L("addSkill"), Icon.PLUS, "Hugging Face", Color.Transparent, add = true)

    @Composable
    fun TileView(t: Tile, modifier: Modifier) {
        val on = sel == t.sel
        Box(modifier) {
            Column(Modifier.fillMaxWidth().heightIn(min = 80.dp).selectable(on && !t.unused).background(Palette.card)
                .press(!busy && !t.unused) { sel = t.sel; pick = null; searching = t.sel == Sel.Add; if (searching) { query = "microduck"; search() } }
                .padding(horizontal = 4.dp, vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterVertically)) {
                val a = if (t.unused) 0.4f else 1f
                Box(Modifier.size(34.dp).background(if (on) Palette.orange else if (t.add) Color.Transparent else Palette.inset, CircleShape), contentAlignment = Alignment.Center) {
                    IconView(t.icon, 20.dp, (if (on) Palette.bg else Palette.text).copy(alpha = a))
                }
                T(t.name, 12f, color = Palette.text.copy(alpha = a), weight = FontWeight.Bold, maxLines = 1)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Dot(t.dot, 6.dp); T(t.sub, 10f, color = Palette.dim.copy(alpha = a), maxLines = 1)
                }
            }
            t.badge?.let { (b, c) ->
                Box(Modifier.align(Alignment.TopEnd).offset(7.dp, (-7).dp).heightIn(min = 20.dp).widthIn(min = 20.dp).background(c).border(2.dp, Palette.bg)
                    .padding(horizontal = 4.dp), contentAlignment = Alignment.Center) { T(b, 10f, color = Palette.bg, weight = FontWeight.ExtraBold) }
            }
        }
    }

    val tiles: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SectionLabel(L("slotsLabel"))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { slotTiles.forEach { TileView(it, Modifier.weight(1f)) } }
            SectionLabel(L("skillsLabel"), Modifier.padding(top = 4.dp))
            skillTiles.chunked(4).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { TileView(it, Modifier.weight(1f)) }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }

    val locoToggle: @Composable (Modifier) -> Unit = { m ->
        Row(m.card().padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            for ((label, icon, mode) in listOf(Triple(L("legs"), Icon.LEGS, LocoMode.WALK), Triple(L("wheels"), Icon.WHEEL, LocoMode.ROLLER))) {
                val on = (mode == LocoMode.ROLLER) == roller
                Row(Modifier.weight(1f).height(36.dp).background(if (on) Palette.orange else Color.Transparent)
                    .press(!busy && !on, Role.RadioButton) {
                        scope.launch {
                            job = L("sMode") to 0.5f; session.busy = true
                            val r = session.intent(DuckCall.RobotSetMode(mode)); session.refreshPolicies()
                            session.busy = false; job = null
                            if (r != null) say(r, true) else say(L("modeDone", label))
                        }
                    }.semantics { selected = on }, verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
                    IconView(icon, 18.dp, if (on) Palette.bg else Palette.text); T(label, 13f, color = if (on) Palette.bg else Palette.text, weight = FontWeight.SemiBold)
                }
            }
        }
    }

    @Composable
    fun Header(icon: Icon, title: String, sub: String) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            IconView(icon, 24.dp, Palette.orange)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) { Title(title, 20f); T(sub, 11f, color = Palette.dim, maxLines = 1) }
        }
    }

    @Composable
    fun Banner(text: String, color: Color, button: String?, act: () -> Unit) {
        Row(Modifier.fillMaxWidth().background(color).border(2.dp, Palette.bg).padding(start = 10.dp, end = 8.dp, top = 7.dp, bottom = 7.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            T(text, 11.5f, Modifier.weight(1f), Palette.bg, FontWeight.Bold)
            if (button != null) Box(Modifier.height(28.dp).background(Palette.bg).press(!busy, onClick = act).padding(horizontal = 10.dp),
                contentAlignment = Alignment.Center) { T(button, 12f, weight = FontWeight.Bold) }
        }
    }

    @Composable
    fun Option(p: Pick, name: String, sub: String, icon: Icon, color: Color, running: Boolean) {
        val on = pick == p
        Row(Modifier.fillMaxWidth().heightIn(min = 42.dp).background(if (on) Palette.inset else Palette.card)
            .border(1.5.dp, if (on) Palette.orange else Palette.hairline).press(!busy, Role.RadioButton) { pick = p }.padding(horizontal = 9.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(Modifier.size(26.dp).background(Palette.inset, CircleShape), contentAlignment = Alignment.Center) { IconView(icon, 15.dp, color) }
            Column(Modifier.weight(1f)) { T(name, 12.5f, weight = FontWeight.SemiBold, maxLines = 1); T(sub, 10.5f, color = Palette.dim, maxLines = 1) }
            if (running) Box(Modifier.background(Palette.cyan).padding(horizontal = 5.dp, vertical = 2.dp)) { T(L("running"), 10f, color = Palette.bg, weight = FontWeight.ExtraBold) }
        }
    }

    val detail: @Composable (Modifier) -> Unit = { m ->
        Column(m.card().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val s = sel
            when {
                searching -> {
                    val forSkill = s == Sel.Add
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CircleIconButton(Icon.BACK, L("back"), 32.dp, fill = Palette.inset) { searching = false; if (forSkill) sel = Sel.Slot("walk") }
                        Title(if (forSkill) L("addSkill") else L("findFor", slotName((s as? Sel.Slot)?.id ?: "")), 17f)
                    }
                    FieldBox(Icon.SEARCH, height = 36.dp) { InputText(query, { query = it }, "", size = 13f, label = L("searchAria")) }
                    Row(Modifier.fillMaxWidth().press(role = Role.Checkbox) { model.allowCommunity = !model.allowCommunity },
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.padding(top = 1.dp).size(18.dp).background(if (model.allowCommunity) Palette.orange else Color.Transparent)
                            .border(1.5.dp, if (model.allowCommunity) Palette.orange else Palette.field), contentAlignment = Alignment.Center) {
                            if (model.allowCommunity) IconView(Icon.CHECK, 14.dp, Palette.bg, 2.6f)
                        }
                        Column { T(L("allow"), 12f, weight = FontWeight.Bold); T(L("allowSub"), 10.5f, color = Palette.dim) }
                    }
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        hits.forEach { h ->
                            val blocked = h.origin is Origin.Community && !model.allowCommunity
                            Column(Modifier.fillMaxWidth().background(Palette.result).padding(horizontal = 10.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Dot(Palette.origin(h.origin))
                                    Column(Modifier.weight(1f)) { T(h.repo.substringAfterLast('/'), 12.5f, weight = FontWeight.Bold, maxLines = 1); T(h.repo, 10.5f, color = Palette.dim, maxLines = 1) }
                                    Box(Modifier.height(30.dp).background(if (blocked) Palette.inset else Palette.orange).border(2.dp, if (blocked) Color.Transparent else Palette.bg)
                                        .press(!blocked && !busy) { scope.launch { if (forSkill) addSkill(h.repo) else (s as? Sel.Slot)?.let { fetchAndLoad(it.id, h.repo) } } }
                                        .padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
                                        T(if (blocked) L("needAllow") else if (forSkill) L("getSkill") else L("getLoad"), 11.5f,
                                            color = if (blocked) Palette.disabled else Palette.bg, weight = FontWeight.Bold)
                                    }
                                }
                                h.description?.let { T(it, 11f, color = Palette.light) }
                                if (blocked) T(L("needAllowNote"), 11f, color = Palette.purple, weight = FontWeight.Bold)
                            }
                        }
                        if (hits.isEmpty() && !searchBusy) T(L("noResults"), 12f, Modifier.padding(16.dp), Palette.dim)
                    }
                    if (forSkill) T(L("skillRule"), 10.5f, color = Palette.dim)
                }
                s is Sel.Slot -> {
                    val id = s.id
                    val slot = policies?.slots?.firstOrNull { it.slot == id }
                    val running = slot?.running?.removeSuffix(".onnx") ?: L("viaWalk")
                    Header(slotIcon(id), slotName(id), L("runningLine", running, originName(slot?.origin)))
                    when {
                        slot?.error != null -> Banner(L("bannerBroken", running) + " " + slot.error, Palette.pink, L("resetOfficial")) { scope.launch { load(id, SlotTarget.Official, L("official")) } }
                        id == "walk" && policies?.sharedWalkConflict == true -> Banner(L("sharedOverride", running), Palette.yellow, L("resetOfficial")) { scope.launch { load(id, SlotTarget.Official, L("official")) } }
                        id == "sitstand" && roller -> Banner(L("rollerSit"), Palette.yellow, null) {}
                    }
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Option(Pick.Official, officialName(id), L("official"), Icon.OFFICIAL, Palette.orange, slot?.overridden == false && slot.path != null)
                        hits.filter { model.allowCommunity || it.origin is Origin.Official }.forEach { h ->
                            val leaf = h.repo.substringAfterLast('/')
                            Option(Pick.Hit(h.repo), leaf, originName(h.origin) + " · " + h.repo, if (h.origin is Origin.Community) Icon.PEOPLE else Icon.FILE,
                                Palette.origin(h.origin), slot?.path?.contains(leaf) == true)
                        }
                        if (id != "walk" && id != "stand") Option(Pick.Off, L("slotOff"), L("slotOffSub"), Icon.BAN, Palette.dim, slot?.path == null)
                        Row(Modifier.fillMaxWidth().heightIn(min = 38.dp).dashedBorder().press(!busy) { searching = true; search() }.padding(horizontal = 10.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            IconView(Icon.SEARCH, 16.dp, Palette.light); T(L("findMore"), 12f, color = Palette.light, weight = FontWeight.SemiBold)
                        }
                    }
                    val driving = id == "walk" || (id == "stand" && !roller)
                    T(if (driving) L("impactHome") else L("impactLive"), 11f, color = Palette.dim)
                    // 请求本来就成立时不做事：主按钮显示"正在运行"并置灰；唯一例外是开机加载失败的槽位。
                    val (label, can) = when (pick) {
                        null -> L("current") to false
                        Pick.Official -> (slot?.overridden == false && slot.error == null).let { if (it) L("current") to false else L("resetOfficial") to true }
                        Pick.Off -> L("turnOff") to (slot?.path != null)
                        is Pick.Hit -> L("load") to true
                    }
                    PrimaryButton(job?.first ?: label, enabled = can && !busy, height = 46.dp, fontSize = 16f, progress = job?.second) {
                        when (val p = pick) {
                            Pick.Official -> scope.launch { load(id, SlotTarget.Official, L("official")) }
                            Pick.Off -> scope.launch { load(id, SlotTarget.Off, L("slotOff")) }
                            is Pick.Hit -> scope.launch { fetchAndLoad(id, p.repo) }
                            null -> {}
                        }
                    }
                }
                s is Sel.Skill -> {
                    val k = session.skills.firstOrNull { it.name == s.name }
                    Header(skillIcon(s.name), skillName(s.name), s.name)
                    for ((key, v) in listOf(L("source") to (if (k?.overridden == true) L("community") else L("official") + " · " + L("builtIn")),
                        L("kind") to L("oneShot"), L("duration") to (k?.duration?.let { "%.1f s".format(it) } ?: "—"),
                        L("state") to (if (k?.disabled == true) L("disabled") else L("enabled")))) {
                        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp)) { T(key, 12f, Modifier.weight(1f), Palette.dim); T(v, 12f, weight = FontWeight.SemiBold) }
                        Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
                    }
                    Spacer(Modifier.weight(1f))
                    Row(Modifier.press { model.push(Route.Gamepad) }, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconView(Icon.GAMEPAD, 18.dp, Palette.light); T(L("bindPad"), 12f, color = Palette.light, weight = FontWeight.SemiBold)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val disabled = k?.disabled == true
                        val c = if (disabled) Palette.cyan else Palette.pink
                        Box(Modifier.weight(1f).height(46.dp).border(1.5.dp, c).press(!busy) {
                            scope.launch {
                                job = L("sSkill") to 0.5f
                                when {
                                    k?.overridden == true -> session.intent(DuckCall.RobotRemoveSkill(s.name))
                                    disabled -> session.intent(DuckCall.RobotAddSkill(s.name, k?.path ?: "", k?.duration ?: 2.0))
                                    else -> session.intent(DuckCall.RobotDisableSkill(s.name))
                                }
                                session.refreshPolicies(); job = null
                            }
                        }, contentAlignment = Alignment.Center) {
                            T(if (k?.overridden == true) L("removeSkill") else if (disabled) L("enableSkill") else L("disableSkill"), 13f, color = c, weight = FontWeight.Bold)
                        }
                        PrimaryButton(L("tryIt"), Modifier.weight(1f), enabled = !busy && k?.disabled != true, height = 46.dp, fontSize = 16f) {
                            scope.launch { status = L("trying", skillName(s.name)) to false; session.intent(DuckCall.RobotDo(s.name))?.let { status = it to true } }
                        }
                    }
                }
            }
        }
    }

    val statusLine: @Composable () -> Unit = {
        val walk = policies?.slots?.firstOrNull { it.slot == "walk" }?.running?.removeSuffix(".onnx") ?: "—"
        val (text, color) = job?.let { it.first to Palette.yellow } ?: status?.let { it.first to (if (it.second) Palette.pink else Palette.cyan) }
            ?: (L("robotState", walk) to Palette.dim)
        Row(Modifier.fillMaxWidth().heightIn(min = 22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Dot(if (job != null) Palette.yellow else if (status?.second == true) Palette.pink else Palette.cyan)
            T(text, 12f, color = color, weight = FontWeight.SemiBold, maxLines = 1)
        }
    }

    val checkLabel = when { checking -> L("checking"); updates == null -> L("check"); updates!!.isEmpty() -> L("upToDate"); else -> L("updates", updates!!.size) }
    val hasUpd = updates?.isNotEmpty() == true
    ScreenFrame {
        TitleBar(L("policyTitle"), { model.pop() }) {
            if (layout != LayoutClass.PhonePortrait) locoToggle(Modifier.width(240.dp))
            SquareAction(Icon.RESCAN, checkLabel, if (hasUpd) Palette.bg else Palette.text, if (hasUpd) Palette.yellow else Palette.card, !busy && !checking) {
                scope.launch {
                    checking = true
                    runCatching { updates = decodePolicyCheck(session.call(DuckCall.PolicyCheck, 30_000)) }
                    checking = false
                    if (updates?.isEmpty() == true) say(L("checkDone0"))
                }
            }
        }
        if (layout == LayoutClass.PhonePortrait) {
            locoToggle(Modifier.fillMaxWidth())
            tiles()
            detail(Modifier.weight(1f).fillMaxWidth())
            statusLine()
        } else {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.weight(1f).verticalScroll(rememberScrollState())) { tiles() }
                    statusLine()
                }
                detail(if (layout == LayoutClass.PhoneLandscape) Modifier.width(320.dp).fillMaxHeight() else Modifier.weight(1f).fillMaxHeight())
            }
        }
    }
}
