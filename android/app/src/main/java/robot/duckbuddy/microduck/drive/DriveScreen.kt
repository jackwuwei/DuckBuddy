package robot.duckbuddy.microduck.drive

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.LocalModel
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.state.LinkState
import robot.duckbuddy.microduck.state.Power
import robot.duckbuddy.microduck.state.Route
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * 驾驶页（设计稿 PortraitDrive 390×844 / Main 844×390），与 iOS `DriveScreen.swift` 相同的放置规则：
 * 手机按设计稿坐标等比放置；平板和折叠屏展开时视频在上、摇杆贴住两侧外缘，语音键 / 启动键在中线两侧，
 * 不压在竖直铰链上；**桌面姿态**（水平铰链半开）时视频只占上半屏，所有控件在下半屏。
 */
@Composable
fun DriveScreen() {
    val model = LocalModel.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val ctl = remember { DriveController(model, scope) }
    val voice = remember { VoiceController(ctx.applicationContext, model, scope) { t, w -> ctl.say(t, w) } }
    DisposableEffect(Unit) {
        ctl.startLoop()
        val s = model.session
        if (!s.media.isOpen) s.mediaIP?.let { s.media.open(it, s) }
        onDispose { ctl.stopLoop(); voice.close() }
    }
    val askMic = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
    if (voice.showConsent) AlertDialog(
        onDismissRequest = { voice.showConsent = false },
        title = { T(L("voiceConsentTitle"), 18f, weight = FontWeight.Bold) },
        text = { T(L("voiceConsent"), 14f, color = Palette.light) },
        confirmButton = { TextButton({ model.consent(); voice.showConsent = false; askMic.launch(android.Manifest.permission.RECORD_AUDIO) }) { T(L("agree"), 14f, color = Palette.orange, weight = FontWeight.Bold) } },
        dismissButton = { TextButton({ voice.showConsent = false }) { T(L("notNow"), 14f, color = Palette.dim) } },
        containerColor = Palette.card,
    )
    Box(Modifier.fillMaxSize().background(Palette.bg)) {
        DriveCanvas(ctl, voice)
    }
}

private fun Modifier.at(x: Dp, y: Dp, w: Dp, h: Dp) = this.offset(x, y).size(w, h)

@Composable
private fun DriveCanvas(ctl: DriveController, voice: VoiceController) {
    val layout = LocalLayout.current
    val hinge = LocalHinge.current
    val insets = WindowInsets.safeDrawing.asPaddingValues()
    val dir = androidx.compose.ui.platform.LocalLayoutDirection.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val W = maxWidth; val H = maxHeight
        val top = insets.calculateTopPadding(); val bottom = insets.calculateBottomPadding()
        val L0 = insets.calculateLeftPadding(dir); val R0 = insets.calculateRightPadding(dir)
        val tabletop = hinge?.tabletop == true
        if (layout == LayoutClass.PhonePortrait) {
            // ── 竖屏：设计稿 390×844 ──
            val s = min(W.value / 390f, H.value / 844f)
            // 设计稿底部按 iPhone 34pt 主页条留白；Android 手势条 / 三键导航更高时，底部控件整体上移差值。
            val Hb = H.value - max(0f, bottom.value - 34 * s)
            val barY = max(top.value + 6, 54 * s)
            val camTop = barY + 46 * s
            val micTop = Hb - 218 * s
            var camH = min(434 * s, micTop - 92 * s - camTop)
            if (tabletop) camH = min(camH, hinge!!.top.value - 12 - camTop)
            val camW = camH * 9 / 16
            val stick = 128 * s
            TopBar(ctl, compact = true, Modifier.at(16.dp * s, barY.dp, W - 32.dp * s, 36.dp))
            Camera(ctl, voice, s, 80f, compact = true, Modifier.at(((W.value - camW) / 2).dp, camTop.dp, camW.dp, camH.dp))
            ModeColumn(ctl, s, DpSize(56.dp, 58.dp), 4.dp, Palette.card, Modifier.offset((4 * s).dp, camTop.dp))
            ActionColumn(ctl, s, DpSize(62.dp, 62.dp), 6.dp, Palette.card, boxed = false,
                Modifier.align(Alignment.TopEnd).offset((-4 * s).dp, camTop.dp))
            if (ctl.tray) Box(Modifier.fillMaxWidth().offset(y = (camTop + camH + 14 * s).dp), contentAlignment = Alignment.TopCenter) {
                EmotionTray(ctl, s, DpSize(64.dp, 56.dp), Palette.inset)
            }
            MicButton(voice, s, labeled = false, Modifier.offset(((W.value - 56 * s) / 2).dp, micTop.dp))
            Sticks(ctl, s, stick, 50 * s, Hb - 44 * s - stick / 2, 16 * s + stick / 2, W.value - 16 * s - stick / 2,
                Palette.stick, Color.White.copy(alpha = 0.18f), Hb - 20 * s - 10, 12f, Palette.light)
            StartButton(ctl, s, Modifier.offset(((W.value - 72 * min(s, 1.2f)) / 2).dp, (Hb - 50 * s - 94 * min(s, 1.2f)).dp))
            if (voice.phase != VoiceController.Phase.Idle) VoiceOverlay(voice, W.value, H.value, s, portrait = true,
                micCenter = Offset(W.value / 2, micTop + 28 * s))
        } else {
            // ── 横屏 / 平板 / 折叠屏展开 ──
            val wide = layout.isWide
            val s = if (wide) (min(min(H.value / 520f, (W - L0 - R0).value / 620f), 1.6f)).coerceAtLeast(1f)
                    else min(max(min(H.value / 390f, (W - L0 - R0).value / 844f), 0.8f), 1.15f)
            val topY = top.value + 12 * s
            val stick = 124 * s
            val stickY = H.value - bottom.value - 34 * s - stick / 2
            val side = if (wide) 16 + 68 + 20 else 96
            val stickLX = L0.value + side * s + stick / 2
            val stickRX = W.value - R0.value - side * s - stick / 2
            val camTop = topY + 40 * s
            var limitH = if (wide) stickY - stick / 2 - 16 * s - camTop else H.value - camTop - 12 * s - bottom.value
            if (tabletop) limitH = min(limitH, hinge!!.top.value - 12 - camTop)
            val limitW = if (wide) W.value - L0.value - R0.value - 2 * side * s else W.value - 2 * (L0.value + (96 + 124 + 16) * s)
            val camH = min(limitH, limitW * 16 / 9)
            val camW = camH * 9 / 16
            Camera(ctl, voice, s, 60f, compact = false, Modifier.at(((W.value - camW) / 2).dp, camTop.dp, camW.dp, camH.dp))
            TopBar(ctl, compact = false, Modifier.at(L0 + 16.dp, topY.dp, W - L0 - R0 - 32.dp, 36.dp))
            ModeColumn(ctl, s, DpSize(60.dp, 54.dp), 2.dp, Palette.bg.copy(alpha = 0.78f), Modifier.offset(L0 + (16 * s).dp, (camTop + 8 * s).dp))
            ActionColumn(ctl, s, DpSize(60.dp, 46.dp), 2.dp, Palette.bg.copy(alpha = 0.78f), boxed = true,
                Modifier.align(Alignment.TopEnd).offset(-R0 - (16 * s).dp, (camTop + 8 * s).dp))
            if (ctl.tray) Box(Modifier.fillMaxWidth().offset(y = (if (wide) camTop + camH - 70 * s else H.value - bottom.value - 122 * s).dp),
                contentAlignment = Alignment.TopCenter) { EmotionTray(ctl, s, DpSize(60.dp, 52.dp), Palette.bg.copy(alpha = 0.75f)) }
            val k = min(s, 1.2f)
            val micCenter: Offset
            if (wide) {
                // 两摇杆之间四等分：语音键、启动键各占一侧，都不压中线（竖直铰链）。
                val mid = (stickLX + stickRX) / 2
                val off = max((stickRX - stickLX - stick) / 4, 40 * s)
                micCenter = Offset(mid - off, stickY)
                MicButton(voice, s, labeled = true, Modifier.offset((mid - off - 44 * k).dp, (stickY - 42 * k).dp))
                StartButton(ctl, s, Modifier.offset((mid + off - 36 * k).dp, (stickY - 47 * k).dp))
            } else {
                micCenter = Offset(stickLX - 18 * s, stickY - stick / 2 - 58 * s)
                MicButton(voice, s, labeled = true, Modifier.offset((stickLX - 18 * s - 44 * k).dp, (stickY - stick / 2 - 16 * s - 84 * k).dp))
                StartButton(ctl, s, Modifier.offset((stickRX - 36 * k).dp, (stickY - stick / 2 - 16 * s - 94 * k).dp))
            }
            Sticks(ctl, s, stick, 48 * s, stickY, stickLX, stickRX, if (wide) Palette.stick else Palette.bg.copy(alpha = 0.28f),
                Color.White.copy(alpha = if (wide) 0.18f else 0.35f), H.value - bottom.value - 8 * s - 9, if (wide) 12f else 11f,
                if (wide) Palette.light else Palette.text)
            Box(Modifier.fillMaxWidth().offset(y = (camTop + camH - 22 * s - 22).dp), contentAlignment = Alignment.TopCenter) {
                Readout(ctl, 18f * min(s, 1.3f))
            }
            if (voice.phase != VoiceController.Phase.Idle) VoiceOverlay(voice, W.value, H.value, if (wide) min(s, 1.3f) else s, portrait = false, micCenter = micCenter)
        }
    }
}

// ── 顶栏 ──

@Composable
private fun TopBar(ctl: DriveController, compact: Boolean, modifier: Modifier) {
    val model = LocalModel.current
    val session = model.session
    val fill = if (compact) Palette.card else Palette.bg.copy(alpha = 0.78f)
    val border = if (compact) Palette.hairline else Color.White.copy(alpha = 0.12f)
    val (label, dot) = ctl.stateLabel
    val reconnecting = session.linkState == LinkState.Reconnecting
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.height(36.dp).background(fill).border(1.dp, border)
            .press(label = L("robot")) { session.disconnect(); model.path.clear() }
            .padding(start = 6.dp, end = if (compact) 12.dp else 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            DuckImage(Modifier.size(38.dp, 26.dp), quacking = ctl.quackDown)
            Dot(if (reconnecting) Palette.yellow else dot, 7.dp)
            T(if (reconnecting) L("reconnectingBle") else label, 13f, weight = FontWeight.SemiBold, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        Row(Modifier.height(36.dp).background(fill).border(1.dp, border).press(label = L("status")) { model.push(Route.Status) }
            .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            BatteryGlyph(session.batteryFraction)
            T(session.health?.batteryVolts?.let { "%.1fV".format(it) } ?: "--V", 12f, weight = FontWeight.SemiBold)
            Box(Modifier.padding(horizontal = 3.dp).size(1.dp, 14.dp).background(Color.White.copy(alpha = 0.2f)))
            IconView(Icon.CHIP, 15.dp, weight = 2f)
            T(session.health?.cpuTempC?.let { "%.0f°".format(it) } ?: "--°", 12f, weight = FontWeight.SemiBold)
        }
        if (compact) CircleIconButton(Icon.BRAIN, L("policy"), fill = fill) { model.push(Route.Policy) }
        else {
            Row(Modifier.height(36.dp).background(fill).border(1.dp, border).press { model.push(Route.Policy) }.padding(start = 10.dp, end = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                IconView(Icon.BRAIN, 18.dp); T(L("policy"), 12f, weight = FontWeight.SemiBold)
            }
            CircleIconButton(Icon.GAMEPAD, L("gamepad"), fill = fill) { model.push(Route.Gamepad) }
        }
        Box(Modifier.size(36.dp).background(fill, CircleShape).border(1.dp, if (compact) Color.Transparent else border, CircleShape)
            .holdGesture({ ctl.powerHeld = it }) { ctl.powerReleased(it) }
            .semantics { contentDescription = L("powerAria"); role = Role.Button }, contentAlignment = Alignment.Center) {
            Ring(ctl.powerHeld / 4f, if (ctl.powerHeld >= 2f) Palette.pink else Color.White, 2.dp, Modifier.fillMaxSize().padding(1.dp))
            IconView(Icon.POWER, 18.dp, Palette.pink, 2f)
        }
    }
}

// ── 视频框 ──

@Composable
private fun Camera(ctl: DriveController, voice: VoiceController, s: Float, gaze: Float, compact: Boolean, modifier: Modifier) {
    val media = LocalModel.current.session.media
    Box(modifier.background(Palette.video).border(1.dp, Color.White.copy(alpha = 0.14f)).clipToBounds()
        .semantics { contentDescription = L("cameraRegion") }) {
        if (ctl.camOn) media.VideoView(Modifier.fillMaxSize())
        else Column(Modifier.fillMaxSize().background(Palette.panel), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally) {
            IconView(Icon.CAM_OFF, 34.dp, Palette.disabled, 2f); T(L("camIsOff"), 12f, color = Palette.disabled, weight = FontWeight.Bold)
        }
        Row(Modifier.padding(8.dp).height(20.dp).background(Palette.bg.copy(alpha = 0.72f)).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Dot(if (ctl.camOn) Palette.pink else Palette.disabled, 6.dp)
            T(if (ctl.camOn) "LIVE" else "OFF", 10f, weight = FontWeight.ExtraBold)
            T("9:16", 10f, color = Palette.dim, weight = FontWeight.SemiBold)
        }
        Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(32.dp).background(Palette.bg.copy(alpha = 0.72f))
            .border(1.dp, Color.White.copy(alpha = 0.18f)).press(label = if (ctl.camOn) L("camTurnOff") else L("camTurnOn")) { ctl.toggleCam() },
            contentAlignment = Alignment.Center) { IconView(if (ctl.camOn) Icon.CAM_ON else Icon.CAM_OFF, 17.dp, weight = 2f) }
        Reticle(Modifier.align(Alignment.Center).offset((ctl.reticle.x * gaze * s).dp, (ctl.reticle.y * gaze * 1.85f * s).dp))
        val t = ctl.toast
        if (t != null && voice.phase == VoiceController.Phase.Idle) {
            Box(Modifier.align(Alignment.TopCenter).padding(top = if (compact) 36.dp else 8.dp).widthIn(max = 220.dp)
                .background(Palette.bg.copy(alpha = 0.78f)).padding(horizontal = 10.dp, vertical = 6.dp)) {
                T(t.first, 12f, color = if (t.second) Palette.yellow else Palette.text, weight = FontWeight.SemiBold)
            }
        }
        if (compact) Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 10.dp)) { Readout(ctl, 18f) }
    }
}

@Composable
private fun Readout(ctl: DriveController, size: Float) {
    val r = ctl.readout
    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
        for (i in 0..1) Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            T(r[i * 2], size, weight = FontWeight.SemiBold)
            T(r[i * 2 + 1], 11f, Modifier.padding(bottom = 2.dp), color = Color.White.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun Reticle(modifier: Modifier) {
    Canvas(modifier.size(28.dp)) {
        val c = Color.White.copy(alpha = 0.8f); val w = 2.dp.toPx(); val l = 8.dp.toPx(); val m = size.width / 2
        drawLine(c, Offset(m, 0f), Offset(m, l), w, StrokeCap.Round)
        drawLine(c, Offset(m, size.height - l), Offset(m, size.height), w, StrokeCap.Round)
        drawLine(c, Offset(0f, m), Offset(l, m), w, StrokeCap.Round)
        drawLine(c, Offset(size.width - l, m), Offset(size.width, m), w, StrokeCap.Round)
    }
}

// ── 模式列 / 动作列 / 情绪托盘 ──

@Composable
private fun ModeColumn(ctl: DriveController, s: Float, button: DpSize, gap: Dp, fill: Color, modifier: Modifier) {
    val modes = listOf(Triple(DriveController.Mode.Walk, L("mWalk"), Icon.MOVE), Triple(DriveController.Mode.Head, L("mHead"), Icon.HEAD),
        Triple(DriveController.Mode.Look, L("mLook"), Icon.LOOK), Triple(DriveController.Mode.Height, L("mHeight"), Icon.HEIGHT))
    Column(modifier.background(fill).border(1.dp, if (fill == Palette.card) Palette.hairline else Color.White.copy(alpha = 0.12f)).padding((4 * s).dp)
        .semantics { contentDescription = L("modeAria") }, verticalArrangement = Arrangement.spacedBy(gap * s)) {
        modes.forEach { (m, name, icon) ->
            val on = ctl.mode == m
            Column(Modifier.size(button.width * s, button.height * s).background(if (on) Palette.orange else Color.Transparent)
                .press(role = Role.RadioButton) { ctl.mode = m; ctl.tray = false }.semantics { selected = on },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
                IconView(icon, (22 * min(s, 1.2f)).dp, if (on) Palette.bg else Palette.text)
                T(name, 11f, color = if (on) Palette.bg else Palette.text, weight = FontWeight.SemiBold, maxLines = 1)
            }
        }
    }
}

@Composable
private fun ActionColumn(ctl: DriveController, s: Float, button: DpSize, gap: Dp, fill: Color, boxed: Boolean, modifier: Modifier) {
    Column(modifier.then(if (boxed) Modifier.background(fill).border(1.dp, Color.White.copy(alpha = 0.12f)).padding((4 * s).dp) else Modifier),
        verticalArrangement = Arrangement.spacedBy(gap * s)) {
        ctl.actions.forEach { a ->
            Column(Modifier.size(button.width * s, button.height * s).background(if (a.on) Palette.orange else if (boxed) Color.Transparent else Palette.card)
                .pressGesture(a.down, a.up).semantics { contentDescription = a.name; role = Role.Button },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(if (boxed) 2.dp else 4.dp, Alignment.CenterVertically)) {
                val c = (if (a.on) Palette.bg else Palette.text).copy(alpha = if (ctl.dimmed(a)) 0.4f else 1f)
                IconView(a.icon, ((if (boxed) 22 else 24) * min(s, 1.2f)).dp, c)
                T(a.name, 11f, color = c, weight = FontWeight.SemiBold, maxLines = 1)
            }
        }
    }
}

@Composable
private fun EmotionTray(ctl: DriveController, s: Float, button: DpSize, fill: Color) {
    Row(Modifier.background(fill).border(1.dp, Color.White.copy(alpha = 0.14f)).padding((4 * s).dp), horizontalArrangement = Arrangement.spacedBy((6 * s).dp)) {
        ctl.emotions.forEach { e ->
            Column(Modifier.size(button.width * s, button.height * s).press(label = e.name, onClick = e.go),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
                IconView(e.icon, 22.dp, e.color, 2f); T(e.name, 11f, weight = FontWeight.SemiBold)
            }
        }
    }
}

// ── 摇杆 / 启动键 / 语音键 ──

@Composable
private fun Sticks(ctl: DriveController, s: Float, d: Float, knob: Float, y: Float, lx: Float, rx: Float, fill: Color, border: Color,
                   labelY: Float, labelSize: Float, labelColor: Color) {
    val (l, r) = when (ctl.mode) {
        DriveController.Mode.Walk -> L("sMove") to L("sTurn")
        DriveController.Mode.Head -> L("sTurnHead") to L("sTilt")
        DriveController.Mode.Look -> L("sDrive") to L("sLook")
        DriveController.Mode.Height -> L("sHeight") to L("sLook")
    }
    Joystick(d.dp, knob.dp, fill, border, l, ctl.left, { ctl.left = it }, Modifier.offset((lx - d / 2).dp, (y - d / 2).dp))
    Joystick(d.dp, knob.dp, fill, border, r, ctl.right, { ctl.right = it }, Modifier.offset((rx - d / 2).dp, (y - d / 2).dp))
    for ((text, x) in listOf(l to lx, r to rx)) Box(Modifier.offset((x - 64 * s).dp, labelY.dp).width((128 * s).dp), contentAlignment = Alignment.Center) {
        T(text, labelSize, color = labelColor, weight = FontWeight.Bold)
    }
}

/** 虚拟摇杆：归一化到 [-1, 1]（x 向右、y 向下），死区由 duck-core 处理。 */
@Composable
fun Joystick(diameter: Dp, knob: Dp, fill: Color, border: Color, label: String, value: Offset, onChange: (Offset) -> Unit, modifier: Modifier) {
    var active by remember { mutableStateOf(false) }
    val density = LocalDensity.current
    val r = with(density) { diameter.toPx() / 2 }
    val travel = (diameter - knob) / 2
    Box(modifier.size(diameter).background(fill, CircleShape).border(1.5.dp, border, CircleShape)
        .pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                active = true
                fun emit(p: Offset) {
                    var x = (p.x - r) / r; var y = (p.y - r) / r
                    val m = hypot(x, y)
                    if (m > 1) { x /= m; y /= m }
                    onChange(Offset(x, y))
                }
                emit(down.position)
                while (true) {
                    val ev = awaitPointerEvent()
                    val c = ev.changes.firstOrNull { it.id == down.id } ?: break
                    if (!c.pressed) break
                    emit(c.position); c.consume()
                }
                active = false
                onChange(Offset.Zero)
            }
        }
        .semantics { contentDescription = label; stateDescription = "x %.2f, y %.2f".format(value.x, value.y) },
        contentAlignment = Alignment.Center) {
        Box(Modifier.offset(travel * value.x, travel * value.y).size(knob).background(Color.White.copy(alpha = if (active) 0.95f else 0.75f), CircleShape))
    }
}

@Composable
private fun StartButton(ctl: DriveController, s: Float, modifier: Modifier) {
    val k = min(s, 1.2f)
    Column(modifier.width((72 * k).dp).holdGesture({ ctl.startHeld = it }) { ctl.startReleased(it) }
        .semantics { contentDescription = ctl.startText; role = Role.Button },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size((72 * k).dp), contentAlignment = Alignment.Center) {
            Box(Modifier.fillMaxSize().padding(2.dp).border(3.dp, Color.White.copy(alpha = 0.9f), CircleShape))
            Ring(ctl.startHeld / 1.5f, Palette.orange, 3.dp, Modifier.fillMaxSize().padding(2.dp))
            Box(Modifier.size((56 * k).dp).background(if (ctl.power == Power.Walking) Palette.orange else Color.White, CircleShape), contentAlignment = Alignment.Center) {
                IconView(ctl.startIcon, (24 * k).dp, Palette.bg, 2.2f)
            }
        }
        T(ctl.startText, 12f, weight = FontWeight.Bold)
    }
}

@Composable
private fun MicButton(voice: VoiceController, s: Float, labeled: Boolean, modifier: Modifier) {
    val k = min(s, 1.2f)
    val live = voice.phase != VoiceController.Phase.Idle
    val cancelOn = live && voice.zone == VoiceController.Zone.Cancel
    val locked = voice.locked
    val density = LocalDensity.current
    Column(modifier.width(((if (labeled) 88 else 56) * k).dp).zIndex(6f)
        .pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                voice.press()
                var cancelled = false
                while (true) {
                    val ev = awaitPointerEvent()
                    val c = ev.changes.firstOrNull { it.id == down.id }
                    if (c == null) { cancelled = true; break }
                    if (!c.pressed) break
                    val d = with(density) { (c.position - down.position).let { Offset(it.x.toDp().value, it.y.toDp().value) } }
                    voice.move(d.x / k, d.y / k)
                    c.consume()
                }
                // 系统中断触摸（如来电）视为取消。
                voice.release(interrupted = cancelled)
            }
        }
        .semantics { contentDescription = L("voiceAria"); role = Role.Button },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size((56 * k).dp)) {
            Box(Modifier.fillMaxSize().hardShadow(if (live) Palette.orange else Color.Transparent, 3.dp, CircleShape)
                .background(if (locked) Palette.inset else if (cancelOn) Palette.pink else if (live) Palette.yellow else if (labeled) Palette.bg.copy(alpha = 0.78f) else Palette.card, CircleShape)
                .border(2.dp, if (live) Palette.bg else Palette.dashed, CircleShape), contentAlignment = Alignment.Center) {
                IconView(Icon.MIC, (24 * k).dp, if (locked) Palette.disabled else if (live) Palette.bg else Palette.text, 2.1f)
            }
            if (locked) Box(Modifier.align(Alignment.BottomEnd).offset(6.dp, 4.dp).size(22.dp).background(Palette.pink, CircleShape)
                .border(2.dp, Palette.bg, CircleShape), contentAlignment = Alignment.Center) { IconView(Icon.KEY, 12.dp, Palette.bg, 2.4f) }
        }
        if (labeled) T(L("tabVoice"), 11f, weight = FontWeight.Bold)
    }
}

/** 语音面板：黄色漫画框（取消时粉色、删除线），上划目标。 */
@Composable
private fun VoiceOverlay(voice: VoiceController, W: Float, H: Float, s: Float, portrait: Boolean, micCenter: Offset) {
    val cancelOn = voice.zone == VoiceController.Zone.Cancel
    val sendOn = voice.zone == VoiceController.Zone.Send
    Box(Modifier.fillMaxSize().background(Palette.bg.copy(alpha = 0.6f)).zIndex(5f))
    val panelW = if (portrait) W - 64 * s else 320 * s
    Column(Modifier.zIndex(5f).offset(((W - panelW) / 2).dp, if (portrait) (150 * s).dp else (60 * s + 20).dp).width(panelW.dp).rotate(-1f)
        .hardShadow(if (cancelOn) Palette.bg else Palette.orange, 5.dp).background(if (cancelOn) Palette.pink else Palette.yellow)
        .border(3.dp, Palette.bg).padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 12.dp)
        .semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            IconView(Icon.MIC, 18.dp, Palette.bg, 2.2f)
            Title(if (voice.phase == VoiceController.Phase.Thinking) L("thinking") else L("listening"), 18f, Modifier.weight(1f), Palette.bg, 0.04f)
            Row(Modifier.height(22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                for (i in 0 until 7) {
                    val h = if (voice.phase == VoiceController.Phase.Listening && !cancelOn)
                        4 + abs(sin(voice.level * 6 + i * 1.3f)) * 14 * max(0.3f, voice.level) + 2 else 4f
                    Box(Modifier.size(4.dp, h.dp).background(Palette.bg))
                }
            }
        }
        T((voice.heard.ifEmpty { if (voice.phase == VoiceController.Phase.Listening) "" else "…" }) +
            (if (voice.phase == VoiceController.Phase.Listening) "|" else ""), 17f, Modifier.heightIn(min = 23.dp), Palette.bg, FontWeight.Bold, strike = cancelOn)
        T(when { voice.phase == VoiceController.Phase.Thinking -> L("hintSent"); cancelOn -> L("hintCancel"); sendOn -> L("hintSend"); else -> L("hintIdle") },
            12f, color = Palette.bg, weight = FontWeight.Bold)
    }
    val d = (if (portrait) 68 else 56) * s
    val dy = (if (portrait) 72 else 110) * s
    Target(L("vCancel"), Icon.X, cancelOn, Palette.pink, d, Modifier.zIndex(6f).offset((micCenter.x - 80 * s - d / 2).dp, (micCenter.y - dy - d / 2).dp))
    Target(L("vSend"), Icon.SEND, sendOn, Palette.orange, d, Modifier.zIndex(6f).offset((micCenter.x + 80 * s - d / 2).dp, (micCenter.y - dy - d / 2).dp))
}

@Composable
private fun Target(text: String, icon: Icon, on: Boolean, color: Color, size: Float, modifier: Modifier) {
    Column(modifier.size(size.dp).scale(if (on) 1.18f else 1f).hardShadow(if (on) Palette.yellow else Color.Transparent, 3.dp, CircleShape)
        .background(if (on) color else Palette.card.copy(alpha = 0.92f), CircleShape).border(2.dp, if (on) Palette.bg else Palette.dashed, CircleShape),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)) {
        IconView(icon, 22.dp, if (on) Palette.bg else Palette.text, 2.4f)
        T(text, 11f, color = if (on) Palette.bg else Palette.text, weight = FontWeight.Bold)
    }
}

// ── 手势 / 环 ──

/** 按下 / 抬起（设计稿 pointerdown / pointerup 语义）。 */
fun Modifier.pressGesture(down: () -> Unit, up: () -> Unit): Modifier = pointerInput(down, up) {
    awaitEachGesture {
        awaitFirstDown()
        down()
        do { val ev = awaitPointerEvent() } while (ev.changes.any { it.pressed })
        up()
    }
}

/** 长按：按住期间回报秒数（环形进度），松手回调持续时间。 */
@Composable
fun Modifier.holdGesture(onHeld: (Float) -> Unit, onRelease: (Float) -> Unit): Modifier {
    val scope = rememberCoroutineScope()
    return pointerInput(Unit) {
        awaitEachGesture {
            awaitFirstDown()
            val t0 = System.currentTimeMillis()
            val job = scope.launch { while (isActive) { onHeld((System.currentTimeMillis() - t0) / 1000f); delay(40) } }
            do { val ev = awaitPointerEvent() } while (ev.changes.any { it.pressed })
            job.cancel()
            onHeld(0f)
            onRelease((System.currentTimeMillis() - t0) / 1000f)
        }
    }
}

@Composable
fun Ring(progress: Float, color: Color, width: Dp, modifier: Modifier) {
    Canvas(modifier) {
        val w = width.toPx()
        drawArc(color, -90f, 360f * progress.coerceIn(0f, 1f), false, topLeft = Offset(w / 2, w / 2),
            size = androidx.compose.ui.geometry.Size(size.width - w, size.height - w), style = Stroke(w, cap = StrokeCap.Round))
    }
}
