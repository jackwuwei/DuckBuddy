package robot.duckbuddy.microduck.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.LocalModel
import robot.duckbuddy.microduck.ScreenFrame
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.state.KnownRobot
import robot.duckbuddy.microduck.state.LinkState
import robot.duckbuddy.microduck.state.NeedsSetupCode
import robot.duckbuddy.microduck.state.Route
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.duck_core.*
import kotlin.math.sin

private sealed class Verify { object Idle : Verify(); object Busy : Verify(); object Ok : Verify(); data class Bad(val m: String) : Verify() }
private sealed class Join { object Idle : Join(); object Busy : Join(); data class Ok(val ip: String) : Join(); data class Failed(val m: String) : Join() }

/** 添加新鸭子（设计稿 PortraitSetup / Setup）：找鸭子 → 验证 → 连 Wi-Fi → 起名字。 */
@Composable
fun SetupScreen() {
    val model = LocalModel.current
    val session = model.session
    val layout = LocalLayout.current
    val scope = rememberCoroutineScope()
    var step by remember { mutableIntStateOf(0) }
    var picked by remember { mutableStateOf<String?>(null) }
    var quacking by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf("") }
    var verify by remember { mutableStateOf<Verify>(Verify.Idle) }
    // 选好鸭子就直接连接：静默认证通过就跳过验证页；鸭子要 PIN 才显示 PIN 框，不理明文（安全模式）才显示设置码框。
    var needsCode by remember { mutableStateOf(false) }
    var pinAsked by remember { mutableStateOf(false) }
    var pinText by remember { mutableStateOf("") }
    var skippedVerify by remember { mutableStateOf(false) }
    var scanning by remember { mutableStateOf(false) }
    var nets by remember { mutableStateOf<List<WifiNetwork>>(emptyList()) }
    var wifiPick by remember { mutableStateOf<String?>(null) }
    var password by remember { mutableStateOf("") }
    var join by remember { mutableStateOf<Join>(Join.Idle) }
    var skippedWifi by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var finished by remember { mutableStateOf(false) }
    var tick by remember { mutableFloatStateOf(0f) }
    val titles = listOf("stepFind", "stepVerify", "stepWifi", "stepName")
    val duckName = picked ?: session.nearby.firstOrNull()?.id ?: "duck"
    // 认证前让机器人叫一声：官方待办（mobile-app.md §7），可用前只在演示模式显示。
    val identifyAvailable = session.isDemo

    LaunchedEffect(Unit) { session.startScan(); while (true) { delay(100); tick += 1 } }
    LaunchedEffect(step) { if (step == 2) runCatching { nets = decodeNetScan(session.call(DuckCall.NetScan)) } }

    val pinPrompt = session.linkState as? LinkState.NeedsPin
    LaunchedEffect(pinPrompt) {
        if (pinPrompt != null) { pinAsked = true; if (pinPrompt.wrong) pinText = "" }
    }

    fun resetVerify() { verify = Verify.Idle; code = ""; pinText = ""; needsCode = false; pinAsked = false; skippedVerify = false }

    fun back() {
        if (step == 0 || finished) { session.stopScan(); model.pop(); return }
        var target = if (step == 3 && skippedWifi) 1 else step - 1
        if (target == 1 && skippedVerify) target = 0
        if (target == 0) {
            // 回到找鸭子：放下这只鸭子（也取消还在等 PIN 的连接）。
            session.disconnect(); session.startScan(); resetVerify()
        }
        step = target
    }

    fun pair() = scope.launch {
        val text = code.trim()
        // 自动尝试时用之前存的设置码；用户在设置码框里填了就用填的，留空则退回 PIN 模式。
        var setup: SetupCode? = if (needsCode) null else model.setupCode(duckName)
        if (needsCode && text.isNotEmpty()) {
            val parsed = runCatching { parseSetupCode(text) }.getOrNull()
            if (parsed == null || !setupCodeMatches(parsed, duckName)) { verify = Verify.Bad(L("badCode")); return@launch }
            setup = parsed
        }
        val id = duckName
        verify = Verify.Busy
        try {
            session.connect(id, setup, model.savedPin(id), askPin = true)
            if (step != 1 || picked != id) return@launch
            if (setup != null) { if (needsCode) model.saveSetupCode(id, text) }
            else { model.clearSetupCode(id); model.savePin(id, session.pin) }
            verify = Verify.Ok
            // 什么都不用输就通过了：跳过验证页。
            skippedVerify = !pinAsked && !needsCode
            val online = session.nearby.firstOrNull { it.id == id }?.advert?.ipv4 != null || session.net?.connected == true
            if (!skippedVerify) delay(600)
            if (online) {
                // 已联网的机器人跳过配网步骤，步骤条自动打勾。
                skippedWifi = true
                name = session.robotName.ifEmpty { duckName }
                step = 3
            } else step = 2
        } catch (e: NeedsSetupCode) {
            if (step == 1 && picked == id) { needsCode = true; verify = Verify.Idle }
        } catch (e: Exception) {
            if (step == 1 && picked == id) verify = Verify.Bad(e.message ?: L("linkLost"))
        }
    }

    fun joinWifi() = scope.launch {
        val ssid = wifiPick ?: return@launch
        join = Join.Busy
        session.busy = true
        try {
            val json = session.call(DuckCall.NetConnect(ssid, password.ifEmpty { null }), 60_000)
            val st = runCatching { decodeNetStatus(json) }.getOrNull() ?: runCatching { decodeNetStatus(session.call(DuckCall.NetStatus)) }.getOrNull()
            session.net = st
            join = Join.Ok(st?.ip4 ?: "—")
        } catch (e: Exception) {
            join = Join.Failed(e.message ?: "")
        }
        session.busy = false
    }

    fun finish() = scope.launch {
        val trimmed = name.trim()
        var display = trimmed.ifEmpty { duckName }
        if (trimmed.isNotEmpty() && trimmed != session.robotName) {
            runCatching { decodeSetName(session.call(DuckCall.SystemSetName(trimmed))) }.getOrNull()?.let { display = it; session.robotName = it }
        }
        model.remember(KnownRobot(duckName, display, session.net?.ip4, session.health?.batteryVolts))
        model.selectedID = duckName
        finished = true
    }

    val stepper: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (i in 0..3) {
                val done = i < step || finished
                val cur = i == step && !finished
                val icon = if (done) Icon.CHECK else listOf(Icon.BT, Icon.QR, Icon.WIFI, Icon.PEN)[i]
                Box(Modifier.size(30.dp).background(if (cur) Palette.orange else if (done) Palette.cyan else Color.Transparent, CircleShape)
                    .border(2.dp, if (cur) Palette.bg else if (done) Palette.cyan else Palette.field, CircleShape)
                    .semantics { contentDescription = L(titles[i]) }, contentAlignment = Alignment.Center) {
                    IconView(icon, 16.dp, if (cur || done) Palette.bg else Palette.muted, 2.2f)
                }
                if (i < 3) Box(Modifier.size(16.dp, 2.dp).background(if (i < step) Palette.cyan else Color.White.copy(alpha = 0.18f)))
            }
        }
    }

    val finderColor = when (verify) { Verify.Ok -> Palette.cyan; is Verify.Bad -> Palette.pink; else -> Palette.orange }

    val graphic: @Composable (Modifier) -> Unit = { m ->
        Box(m.background(Palette.panel).border(1.dp, Palette.hairline), contentAlignment = Alignment.Center) {
            when (step) {
                0 -> Box(contentAlignment = Alignment.Center) {
                    Box(Modifier.size(200.dp).border(1.5.dp, Palette.cyan.copy(alpha = 0.18f), CircleShape))
                    Box(Modifier.size(146.dp).border(1.5.dp, Palette.cyan.copy(alpha = 0.32f), CircleShape))
                    Box(Modifier.size(92.dp).scale(1 + 0.12f * sin(tick / 3)).border(1.5.dp, Palette.cyan.copy(alpha = 0.55f), CircleShape))
                    DuckImage(Modifier.size(84.dp, 56.dp))
                }
                1 -> Box(Modifier.size(190.dp).background(Color(0xFF16161F))
                    .press(needsCode && verify != Verify.Busy && verify != Verify.Ok, label = L("scanAria")) { scanning = true }, contentAlignment = Alignment.Center) {
                    for (c in 0..3) Canvas(Modifier.fillMaxSize().rotate(c * 90f)) {
                        val w = 4.dp.toPx(); val l = 34.dp.toPx(); val o = w / 2
                        drawLine(finderColor, Offset(o, l), Offset(o, o), w)
                        drawLine(finderColor, Offset(o, o), Offset(l, o), w)
                    }
                    val y = if (verify == Verify.Busy) ((12 + (tick.toInt() * 7) % 76) - 50) / 100f * 190 else 0f
                    Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp).offset(y = y.dp).height(2.dp).background(finderColor.copy(alpha = 0.8f)))
                    IconView(if (verify == Verify.Ok) Icon.CHECK else if (verify is Verify.Bad) Icon.X else if (pinAsked) Icon.KEY else Icon.QR, 56.dp, finderColor, 1.6f)
                }
                2 -> IconView(if (join is Join.Ok) Icon.CHECK else Icon.WIFI, 96.dp,
                    if (join is Join.Ok) Palette.cyan else if (join == Join.Busy) Palette.yellow else Palette.orange, 1.6f)
                else -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    DuckImage(Modifier.size(150.dp, 100.dp), quacking = finished)
                    Title(name.trim().ifEmpty { duckName }, 26f, Modifier.widthIn(max = 240.dp))
                }
            }
        }
    }

    val content: @Composable () -> Unit = {
        when (step) {
            0 -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                session.nearby.forEach { d ->
                    val on = picked == d.id
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(Modifier.weight(1f).height(56.dp).selectable(on).background(Palette.card)
                            .press(role = Role.RadioButton) { picked = if (on) null else d.id }.padding(horizontal = 12.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            DuckImage(Modifier.size(40.dp, 28.dp))
                            T(d.id, 15f, Modifier.weight(1f), weight = FontWeight.Bold, maxLines = 1)
                            if (d.advert.ipv4 != null) IconView(Icon.WIFI, 16.dp, Palette.cyan, 2f)
                            SignalBars(d.bars)
                        }
                        if (identifyAvailable) {
                            val q = quacking == d.id
                            Column(Modifier.size(56.dp).background(if (q) Palette.yellow else Palette.card)
                                .border(2.dp, if (q) Palette.bg else Color.White.copy(alpha = 0.12f))
                                .press(label = L("quackAria", d.id)) { quacking = d.id; scope.launch { delay(1000); if (quacking == d.id) quacking = null } },
                                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)) {
                                IconView(Icon.QUACK_SMALL, 20.dp, if (q) Palette.bg else Palette.text)
                                T(if (q) L("quacked") else L("quackShort"), 10f, color = if (q) Palette.bg else Palette.text, weight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
            1 -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth().height(56.dp).card().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    DuckImage(Modifier.size(40.dp, 28.dp)); T(duckName, 15f, weight = FontWeight.Bold)
                }
                if (pinAsked) FieldBox(Icon.KEY, error = pinPrompt?.wrong == true, height = 48.dp) {
                    InputText(pinText, { v -> pinText = v.filter { it in '0'..'9' }.take(6) }, "000000", mono = true, size = 17f,
                        label = L("pinAria"), numeric = true)
                    val can = pinPrompt != null && isValidPin(pinText)
                    Box(Modifier.height(34.dp).background(if (can) Palette.orange else Palette.inset)
                        .press(can) { runCatching { session.submitPin(pinText) } }.padding(horizontal = 12.dp),
                        contentAlignment = Alignment.Center) { T(L("verifyBtn"), 12f, color = if (can) Palette.bg else Palette.disabled, weight = FontWeight.Bold) }
                }
                else if (needsCode) FieldBox(Icon.KEY, error = verify is Verify.Bad, height = 48.dp) {
                    InputText(code, { code = it; if (verify is Verify.Bad) verify = Verify.Idle }, "md1:…", mono = true, size = 13f, label = L("codeAria"))
                    val can = verify != Verify.Busy && verify != Verify.Ok
                    Box(Modifier.height(34.dp).background(if (can) Palette.orange else Palette.inset).press(can) { pair() }.padding(horizontal = 12.dp),
                        contentAlignment = Alignment.Center) { T(L("verifyBtn"), 12f, color = if (can) Palette.bg else Palette.disabled, weight = FontWeight.Bold) }
                }
                val v = verify
                val (msg, c) = when {
                    v == Verify.Busy && pinAsked && pinPrompt != null ->
                        if (pinPrompt.wrong) L("pinWrong", pinPrompt.attemptsLeft) to Palette.pink else L("needsPin") to Palette.muted
                    v == Verify.Busy && pinAsked -> L("verifying") to Palette.yellow
                    v == Verify.Busy -> L("pairing") to Palette.yellow
                    v == Verify.Ok -> L("verified") to Palette.cyan
                    v is Verify.Bad -> v.m to Palette.pink
                    else -> (if (needsCode && code.isEmpty()) L("needsCode") else "") to Palette.muted
                }
                T(msg, 13f, Modifier.heightIn(min = 18.dp), color = c, weight = FontWeight.Bold)
            }
            2 -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val joined = join is Join.Ok
                nets.forEach { n ->
                    val on = wifiPick == n.ssid
                    Row(Modifier.fillMaxWidth().height(44.dp).selectable(on).background(Palette.card)
                        .press(join != Join.Busy && !joined, Role.RadioButton) { if (!on) password = ""; wifiPick = n.ssid; join = Join.Idle }
                        .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        IconView(Icon.WIFI, 18.dp, if (n.signal < 30u) Palette.muted else Palette.text)
                        T(n.ssid, 14f, Modifier.weight(1f), weight = FontWeight.SemiBold, maxLines = 1)
                        if (n.secured) IconView(Icon.LOCK, 16.dp, Palette.muted)
                    }
                }
                if (wifiPick != null && !joined && (nets.firstOrNull { it.ssid == wifiPick }?.secured ?: true)) {
                    FieldBox(Icon.LOCK) { SecretInput(password, { password = it }, L("password"), enabled = join != Join.Busy) }
                }
                val (msg, c) = when (val j = join) {
                    Join.Busy -> L("joining") to Palette.yellow
                    is Join.Ok -> L("joined", j.ip) to Palette.cyan
                    is Join.Failed -> L("joinFailed", j.m) to Palette.pink
                    Join.Idle -> "" to Palette.yellow
                }
                T(msg, 13f, Modifier.heightIn(min = 18.dp), color = c, weight = FontWeight.Bold)
            }
            else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FieldBox(Icon.PEN, height = 52.dp) {
                    InputText(name, { if (it.length <= 24) name = it }, "", size = 17f, weight = FontWeight.Bold, enabled = !finished, label = L("nameAria"))
                }
                T(L("idLine", duckName), 11.5f, color = Palette.muted)
                T(if (finished) L("ready") else "", 13f, Modifier.heightIn(min = 18.dp), color = Palette.cyan, weight = FontWeight.Bold)
            }
        }
    }

    val footer: @Composable () -> Unit = {
        when {
            finished -> PrimaryButton(L("drive")) { model.path.clear(); model.push(Route.Drive) }
            step == 1 -> if (verify is Verify.Bad && !needsCode) PrimaryButton(L("retry")) { pinAsked = false; pinText = ""; pair() }
            step == 0 -> PrimaryButton(L("next"), enabled = picked != null) { session.stopScan(); resetVerify(); step = 1; pair() }
            step == 2 -> if (join is Join.Ok) PrimaryButton(L("next")) { name = session.robotName.ifEmpty { duckName }; step = 3 } else {
                val secured = nets.firstOrNull { it.ssid == wifiPick }?.secured ?: true
                PrimaryButton(if (join == Join.Busy) L("joining") else L("connect"),
                    enabled = wifiPick != null && (!secured || password.isNotEmpty()) && join != Join.Busy) { joinWifi() }
            }
            else -> PrimaryButton(L("done")) { finish() }
        }
    }

    ScreenFrame {
        TitleBar(L(titles[step]), ::back) { if (layout != LayoutClass.PhonePortrait) stepper() }
        if (layout == LayoutClass.PhonePortrait) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { stepper() }
            graphic(Modifier.fillMaxWidth().height(270.dp))
            Box(Modifier.weight(1f).verticalScroll(rememberScrollState())) { content() }
            footer()
        } else {
            TwoPane(0.42f, Modifier.weight(1f), primary = { graphic(Modifier.fillMaxSize()) }) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.weight(1f).verticalScroll(rememberScrollState())) { content() }
                    footer()
                }
            }
        }
    }

    if (scanning) QrScannerDialog(onDismiss = { scanning = false }) { text -> scanning = false; code = text; pair() }
}

/** CameraX + ML Kit 扫码（只接受 `md1:` 开头）；没有相机权限时提示可粘贴设置码。 */
@Composable
fun QrScannerDialog(onDismiss: () -> Unit, onCode: (String) -> Unit) {
    val ctx = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.CAMERA) }
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Palette.bg)) {
            if (granted) {
                var done by remember { mutableStateOf(false) }
                AndroidView({ c ->
                    PreviewView(c).also { view ->
                        val future = ProcessCameraProvider.getInstance(c)
                        future.addListener({
                            val provider = future.get()
                            val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                            val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
                            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                            analysis.setAnalyzer(ContextCompat.getMainExecutor(c)) { proxy ->
                                @androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
                                val img = proxy.image
                                if (img == null) { proxy.close(); return@setAnalyzer }
                                scanner.process(InputImage.fromMediaImage(img, proxy.imageInfo.rotationDegrees))
                                    .addOnSuccessListener { codes ->
                                        val hit = codes.firstNotNullOfOrNull { it.rawValue?.takeIf { v -> v.lowercase().startsWith("md1:") } }
                                        if (hit != null && !done) { done = true; provider.unbindAll(); onCode(hit) }
                                    }
                                    .addOnCompleteListener { proxy.close() }
                            }
                            provider.unbindAll()
                            provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                        }, ContextCompat.getMainExecutor(c))
                    }
                }, Modifier.fillMaxSize())
            } else {
                VideoPlaceholderText(L("cameraDenied"))
            }
            Box(Modifier.align(Alignment.TopStart).safeDrawingPadding().padding(16.dp)) { CircleIconButton(Icon.X, L("cancel"), onClick = onDismiss) }
        }
    }
}

@Composable
private fun VideoPlaceholderText(text: String) =
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) { T(text, 13f, color = Palette.dim, weight = FontWeight.Bold) }
