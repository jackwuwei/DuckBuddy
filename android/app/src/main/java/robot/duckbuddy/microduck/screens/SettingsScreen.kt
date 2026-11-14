package robot.duckbuddy.microduck.screens

import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.Lang
import robot.duckbuddy.microduck.LocalModel
import robot.duckbuddy.microduck.ScreenFrame
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.drive.DoubaoTester
import robot.duckbuddy.microduck.state.DoubaoKey
import robot.duckbuddy.microduck.state.Route
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.duck_core.DuckCall
import uniffi.duck_core.WifiNetwork
import uniffi.duck_core.decodeNetScan
import uniffi.duck_core.decodeNetStatus

private enum class Tab { Net, Voice, Lang }

/** 设置页（设计稿 PortraitNetwork / Network）：网络 / 语音 / 语言 三个标签。 */
@Composable
fun SettingsScreen() {
    val model = LocalModel.current
    val layout = LocalLayout.current
    var tab by remember { mutableStateOf(Tab.Net) }
    val tabs: @Composable () -> Unit = {
        ChoiceChips(listOf(Triple(Tab.Net, L("tabNet"), Icon.WIFI), Triple(Tab.Voice, L("tabVoice"), Icon.MIC), Triple(Tab.Lang, L("tabLang"), Icon.GLOBE)),
            tab, badge = { it == Tab.Voice && model.doubaoKey == null }) { tab = it }
    }
    ScreenFrame {
        TitleBar(L("settingsTitle"), { model.pop() }) { if (layout != LayoutClass.PhonePortrait) tabs() }
        if (layout == LayoutClass.PhonePortrait) tabs()
        Box(Modifier.weight(1f)) {
            when (tab) {
                Tab.Net -> NetworkTab()
                Tab.Voice -> VoiceTab()
                Tab.Lang -> Box(Modifier.widthIn(max = 560.dp)) { LanguageTab() }
            }
        }
        GamepadEntry(Modifier.then(if (layout == LayoutClass.PhonePortrait) Modifier.fillMaxWidth() else Modifier.widthIn(max = 560.dp).fillMaxWidth()))
    }
}

/** 手柄按键入口（原在驾驶页顶栏）。 */
@Composable
private fun GamepadEntry(modifier: Modifier) {
    val model = LocalModel.current
    Row(modifier.heightIn(min = 60.dp).card().press { model.push(Route.Gamepad) }.padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(36.dp).background(Palette.inset, CircleShape), contentAlignment = Alignment.Center) {
            IconView(Icon.GAMEPAD, 20.dp, Palette.purple)
        }
        Column(Modifier.weight(1f)) {
            T(L("padTitle"), 14f, weight = FontWeight.Bold, maxLines = 1)
            T(L("padEntrySub"), 11f, color = Palette.dim, maxLines = 1)
        }
        IconView(Icon.BACK, 16.dp, Palette.dim, 2.2f, Modifier.rotate(180f))
    }
}

@Composable
private fun NetworkTab() {
    val model = LocalModel.current
    val session = model.session
    val layout = LocalLayout.current
    val scope = rememberCoroutineScope()
    var nets by remember { mutableStateOf<List<WifiNetwork>>(emptyList()) }
    var pick by remember { mutableStateOf<String?>(null) }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var line by remember { mutableStateOf<Pair<String, Color>?>(null) }

    suspend fun scan() {
        runCatching { nets = decodeNetScan(session.call(DuckCall.NetScan, 20_000)) }
        runCatching { session.net = decodeNetStatus(session.call(DuckCall.NetStatus)) }
    }
    /** 换网后由 net.status 拿到新 IP，自动重建视频；控制走蓝牙不受影响。 */
    suspend fun refreshAfterJoin() {
        runCatching { session.net = decodeNetStatus(session.call(DuckCall.NetStatus)) }
        session.mediaIP?.let { session.media.open(it, session) }
    }
    LaunchedEffect(Unit) { scan() }

    val current: @Composable () -> Unit = {
        val net = session.net
        val connected = net?.connected == true
        val sig = net?.signal?.toInt()?.let { if (it >= 66) L("sigStrong") else if (it >= 33) L("sigFair") else L("sigWeak") } ?: ""
        val (text, color) = line ?: if (connected) L("online", net?.ip4 ?: "—", sig) to Palette.cyan else L("offline") to Palette.dim
        Column(Modifier.fillMaxWidth().card().padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(52.dp).background(Palette.inset, CircleShape), contentAlignment = Alignment.Center) { IconView(Icon.WIFI, 26.dp, color) }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(net?.ssid ?: "—", 18f, weight = FontWeight.Bold, maxLines = 1)
                    T(text, 12f, color = color, weight = FontWeight.Bold, maxLines = 1)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconView(Icon.BT, 16.dp, Palette.cyan); T(L("btLine"), 12f, color = Palette.dim, maxLines = 1)
            }
            Row(Modifier.fillMaxWidth().height(44.dp).border(1.5.dp, if (busy) Palette.inset else Palette.dashed)
                .press(!busy && net?.ssid != null) {
                    // 重连当前网络（已保存配置，不需要密码）；期间视频暂停。
                    scope.launch {
                        val ssid = net?.ssid ?: return@launch
                        busy = true; session.media.close(); line = L("reconnecting") to Palette.yellow
                        val ok = runCatching { session.call(DuckCall.NetConnect(ssid, null), 60_000) }.isSuccess
                        refreshAfterJoin()
                        line = if (ok) L("reconnected") to Palette.cyan else null
                        busy = false; delay(2000); line = null
                    }
                }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                IconView(Icon.RESCAN, 18.dp, if (busy) Palette.disabled else Palette.text)
                T(if (busy) L("reconnecting") else L("reconnect"), 14f, color = if (busy) Palette.disabled else Palette.text, weight = FontWeight.Bold)
            }
        }
    }

    val others: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel(L("others"), Modifier.weight(1f))
                Box(Modifier.size(30.dp).border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape).press(!busy, label = L("rescan")) { scope.launch { scan() } },
                    contentAlignment = Alignment.Center) { IconView(Icon.RESCAN, 15.dp, Palette.light) }
            }
            nets.filter { it.ssid != session.net?.ssid }.forEach { n ->
                val on = pick == n.ssid
                Row(Modifier.fillMaxWidth().height(44.dp).selectable(on).background(Palette.card)
                    .press(!busy, Role.RadioButton) { if (!on) password = ""; pick = n.ssid }.padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    IconView(Icon.WIFI, 18.dp, if (n.signal.toInt() < 30) Palette.muted else Palette.text)
                    T(n.ssid, 14f, Modifier.weight(1f), weight = FontWeight.SemiBold, maxLines = 1)
                    if (n.secured) IconView(Icon.LOCK, 16.dp, Palette.muted)
                }
            }
            pick?.let { p ->
                val net = nets.firstOrNull { it.ssid == p }
                val needPw = (net?.secured ?: true) && net?.saved != true
                val can = !busy && (!needPw || password.isNotEmpty())
                Row(Modifier.padding(end = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (needPw) FieldBox(Icon.LOCK, modifier = Modifier.weight(1f)) { SecretInput(password, { password = it }, L("password"), enabled = !busy) }
                    Box(Modifier.height(44.dp).widthIn(min = if (needPw) 0.dp else 120.dp).hardShadow(if (can) Palette.yellow else Color.Transparent)
                        .background(if (can) Palette.orange else Palette.inset).border(2.dp, if (can) Palette.bg else Color.Transparent)
                        .press(can) {
                            scope.launch {
                                busy = true; session.busy = true; session.media.close(); line = L("joining") to Palette.yellow
                                try {
                                    session.call(DuckCall.NetConnect(p, password.ifEmpty { null }), 60_000)
                                    refreshAfterJoin(); line = L("joinedNet", p) to Palette.cyan; pick = null; password = ""; scan()
                                } catch (e: Exception) { line = L("joinFailed", e.message ?: "") to Palette.pink }
                                session.busy = false; busy = false
                            }
                        }.padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
                        Title(if (busy) L("joining") else L("join"), 16f, color = if (can) Palette.bg else Palette.disabled)
                    }
                }
            }
        }
    }

    if (layout == LayoutClass.PhonePortrait) Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        current(); Box(Modifier.verticalScroll(rememberScrollState())) { others() }
    } else TwoPane(0.42f, primary = { Column { current() } }) { Box(Modifier.verticalScroll(rememberScrollState())) { others() } }
}

@Composable
private fun VoiceTab() {
    val model = LocalModel.current
    val layout = LocalLayout.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var apiKey by remember { mutableStateOf(true) }
    var key by remember { mutableStateOf("") }
    var appID by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf(false) }
    var testing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    val saved = model.doubaoKey
    val (chipText, chipColor) = when { saved == null -> L("keyNone") to Palette.muted; model.doubaoInvalid -> L("keyBad") to Palette.pink; else -> L("keyOk") to Palette.cyan }

    /** 测试并保存：实际建一次会话，收到 session.created 才写入安全存储。 */
    fun test() = scope.launch {
        testing = true; error = null
        val cand = DoubaoKey(apiKey, key.trim(), if (apiKey) null else appID.trim())
        val r = if (model.demo) DoubaoTester.Result.Ok else DoubaoTester.test(cand.credential)
        testing = false
        when (r) {
            DoubaoTester.Result.Ok -> { model.saveDoubaoKey(cand); editing = false; key = ""; appID = "" }
            DoubaoTester.Result.BadKey -> error = L("errKey")
            DoubaoTester.Result.NotEnabled -> error = L("errNotEnabled")
            DoubaoTester.Result.Network -> error = L("errNet")
        }
    }

    val keyCard: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().card().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(32.dp).background(Palette.inset, CircleShape), contentAlignment = Alignment.Center) { IconView(Icon.MIC, 16.dp, Palette.yellow) }
                Title(L("doubao"), 18f, Modifier.weight(1f))
                Row(Modifier.height(24.dp).border(1.dp, chipColor).padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)) { Dot(chipColor, 7.dp); T(chipText, 12f, color = chipColor, weight = FontWeight.Bold) }
            }
            if (saved == null || editing) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((v, n, sub) in listOf(Triple(true, L("keyMethodNew"), L("keyMethodNewSub")), Triple(false, L("keyMethodOld"), L("keyMethodOldSub")))) {
                        Column(Modifier.weight(1f).heightIn(min = 40.dp).selectable(apiKey == v).background(Palette.inset)
                            .press(!testing, Role.RadioButton) { apiKey = v; error = null }, horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center) { T(n, 13f, weight = FontWeight.Bold, maxLines = 1); T(sub, 10f, color = Palette.dim, maxLines = 1) }
                    }
                }
                if (!apiKey) FieldBox(Icon.KEY, error != null) { SecretInput(appID, { appID = it }, L("fApp"), mono = true, enabled = !testing) }
                FieldBox(Icon.KEY, error != null) { SecretInput(key, { key = it }, if (apiKey) L("fKey") else L("fTok"), mono = true, enabled = !testing) }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    T(if (testing) L("testing") else error ?: L("keyWhere"), 11f, Modifier.weight(1f),
                        if (error != null) Palette.pink else if (testing) Palette.yellow else Palette.dim, lineHeight = 15f)
                    Row(Modifier.height(30.dp).border(1.dp, Palette.field).press(!testing) {
                        ctx.getSystemService(ClipboardManager::class.java)?.primaryClip?.getItemAt(0)?.text?.let { key = it.toString().trim() }
                    }.padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        IconView(Icon.PASTE, 14.dp, Palette.light); T(L("paste"), 12f, color = Palette.light, weight = FontWeight.SemiBold)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (saved != null) Box(Modifier.height(44.dp).border(1.5.dp, Palette.dashed).press(!testing) { editing = false; key = ""; appID = ""; error = null }
                        .padding(horizontal = 16.dp), contentAlignment = Alignment.Center) { T(L("cancel"), 14f, weight = FontWeight.Bold) }
                    val filled = key.isNotBlank() && (apiKey || appID.isNotBlank())
                    PrimaryButton(if (testing) L("testing") else L("testSave"), Modifier.weight(1f), filled && !testing, 44.dp, 17f) { test() }
                }
            } else {
                Row(Modifier.fillMaxWidth().height(44.dp).background(Palette.bg).border(1.dp, if (model.doubaoInvalid) Palette.pink else Palette.field)
                    .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    IconView(Icon.KEY, 16.dp, Palette.dim)
                    T(if (saved.apiKey) L("keyMethodNew") else L("keyMethodOld"), 12f, color = Palette.dim)
                    T(saved.masked, 15f, weight = FontWeight.Bold, maxLines = 1)
                }
                T(if (model.doubaoInvalid) L("badNote") else L("okNote"), 11f, color = if (model.doubaoInvalid) Palette.pink else Palette.dim, lineHeight = 15f)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.weight(1f).height(44.dp).border(1.5.dp, Palette.dashed).press { editing = true; apiKey = saved.apiKey },
                        contentAlignment = Alignment.Center) { T(L("replace"), 14f, weight = FontWeight.Bold) }
                    Box(Modifier.weight(1f).height(44.dp).background(if (confirmDelete) Palette.pink else Color.Transparent).border(1.5.dp, Palette.pink)
                        .press {
                            if (confirmDelete) { model.saveDoubaoKey(null); confirmDelete = false }
                            else { confirmDelete = true; scope.launch { delay(3000); confirmDelete = false } }
                        }, contentAlignment = Alignment.Center) {
                        T(if (confirmDelete) L("delSure") else L("delKey"), 14f, color = if (confirmDelete) Palette.bg else Palette.pink, weight = FontWeight.Bold)
                    }
                }
            }
        }
    }

    val speakRow: @Composable () -> Unit = {
        val enabled = saved != null
        val on = model.speakReplies && enabled
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).card().padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            IconView(Icon.SPEAKER, 20.dp, if (on) Palette.cyan else Palette.muted)
            Column(Modifier.weight(1f)) { T(L("speak"), 14f, weight = FontWeight.Bold, maxLines = 1); T(if (enabled) L("spkOn") else L("spkNo"), 11f, color = Palette.dim, maxLines = 1) }
            Box(Modifier.size(46.dp, 26.dp).background(if (on) Palette.orange else Palette.inset, RoundedCornerShape(13.dp))
                .press(enabled, Role.Switch) { model.setSpeak(!model.speakReplies) }.semantics { contentDescription = L("speak"); toggleableState = androidx.compose.ui.state.ToggleableState(on) }
                .padding(3.dp), contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart) {
                Box(Modifier.size(20.dp).background(if (!enabled) Palette.disabled else if (on) Palette.bg else Palette.dim, CircleShape))
            }
        }
    }
    val privacy: @Composable () -> Unit = {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { IconView(Icon.SHIELD, 16.dp, Palette.muted); T(L("priv"), 11f, color = Palette.muted, lineHeight = 15.4f) }
    }

    if (layout == LayoutClass.PhonePortrait) Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        keyCard(); speakRow(); privacy()
    } else Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) { keyCard() }
        Column(Modifier.width(270.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { speakRow(); privacy() }
    }
}

@Composable
private fun LanguageTab() {
    val model = LocalModel.current
    Column(Modifier.fillMaxWidth().card().padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconView(Icon.GLOBE, 14.dp, Palette.cyan); SectionLabel(L("langLabel"))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((lang, name) in listOf(Lang.zh to "中文", Lang.en to "English")) {
                val on = model.lang == lang
                Box(Modifier.weight(1f).height(38.dp).selectable(on).background(Palette.inset).press(role = Role.RadioButton) { model.setLanguage(lang) },
                    contentAlignment = Alignment.Center) { T(name, 14f, weight = FontWeight.Bold) }
            }
        }
    }
}
