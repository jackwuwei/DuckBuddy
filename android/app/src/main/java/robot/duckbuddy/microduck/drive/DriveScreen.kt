package robot.duckbuddy.microduck.drive

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
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
import robot.duckbuddy.microduck.state.Gallery
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
        onDispose { ctl.stopRecording(); ctl.stopLoop(); voice.close() }
    }
    // 退到后台：先停下把已录的存好。
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e -> if (e == androidx.lifecycle.Lifecycle.Event.ON_STOP) ctl.stopRecording() }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs) }
    }
    // 拍照 / 录像前要的权限；系统对话框关掉后（给不给都）继续。
    var afterAsk by remember { mutableStateOf<(() -> Unit)?>(null) }
    val askCapture = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()) { afterAsk?.invoke(); afterAsk = null }
    val capturePermissions: (Boolean, () -> Unit) -> Unit = { record, go ->
        val need = buildList {
            if (Gallery.needsPermission(ctx)) add(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
            if (record && androidx.core.content.ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.RECORD_AUDIO)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) add(android.Manifest.permission.RECORD_AUDIO)
        }
        if (need.isEmpty()) go() else { afterAsk = go; askCapture.launch(need.toTypedArray()) }
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
    CompositionLocalProvider(LocalCapturePermissions provides capturePermissions) {
        Box(Modifier.fillMaxSize().background(Palette.bg)) {
            DriveCanvas(ctl, voice)
        }
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
            // ── 竖屏：画面铺满整屏（竖装相机 9:16 和竖屏比例接近，裁掉的很少），所有控件浮在画面上；
            //    模式列收成一个按钮，动作列可以收起；双击画面或按钮切换完整显示。──
            val s = min(W.value / 390f, H.value / 844f)
            // 设计稿底部按 iPhone 34pt 主页条留白；Android 手势条 / 三键导航更高时，底部控件整体上移差值。
            val Hb = H.value - max(0f, bottom.value - 34 * s)
            val barY = max(top.value + 6, 54 * s)
            val rowY = barY + 46
            val railTop = rowY + 42
            val micTop = Hb - 218 * s
            val stick = 128 * s
            // 画面按真实比例尽量放大、完整显示（不裁切）；双击或按钮可以切换成铺满整屏。
            val fill = ctl.videoFill[true] ?: false
            // 桌面姿态：画面只占铰链上方。
            val vidH = if (tabletop) hinge!!.top.value else H.value
            VideoLayer(ctl, s, 80f, portrait = true, fill = fill, Modifier.at(0.dp, 0.dp, W, vidH.dp))
            // 上下两道渐变压暗，浮在画面上的字和按钮才看得清。
            Box(Modifier.at(0.dp, 0.dp, W, (railTop + 24).dp)
                .background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Palette.bg.copy(alpha = 0.75f), Color.Transparent))))
            Box(Modifier.at(0.dp, (micTop - 80 * s).dp, W, (H.value - micTop + 80 * s).dp)
                .background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color.Transparent, Palette.bg.copy(alpha = 0.8f)))))
            TopBar(ctl, compact = true, Modifier.at(16.dp * s, barY.dp, W - 32.dp * s, 36.dp))
            Row(Modifier.at(16.dp * s, rowY.dp, W - 32.dp * s, 32.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween) {
                LiveBadge(ctl, Modifier)
                CaptureButtons(ctl, Modifier, fillToggle = true to fill)
            }
            ModeColumn(ctl, s, DpSize(56.dp, 54.dp), 2.dp, Palette.bg.copy(alpha = 0.6f), Modifier.offset((12 * s).dp, railTop.dp), collapsible = true)
            ActionColumn(ctl, s, DpSize(60.dp, 52.dp), 2.dp, Palette.bg.copy(alpha = 0.6f), boxed = true,
                Modifier.align(Alignment.TopEnd).offset((-12 * s).dp, railTop.dp), collapsible = true)
            Box(Modifier.fillMaxWidth().offset(y = railTop.dp), contentAlignment = Alignment.TopCenter) {
                Toast(ctl, voice, W.value - 2 * (12 + 72) * s)
            }
            if (!ctl.tray) Box(Modifier.fillMaxWidth().offset(y = (micTop - 24 * s - 14).dp), contentAlignment = Alignment.TopCenter) { Readout(ctl, 18f) }
            MicButton(voice, s, labeled = false, Modifier.offset(((W.value - 56 * s) / 2).dp, micTop.dp))
            Sticks(ctl, s, stick, 50 * s, Hb - 44 * s - stick / 2, 16 * s + stick / 2, W.value - 16 * s - stick / 2,
                Palette.bg.copy(alpha = 0.28f), Color.White.copy(alpha = 0.35f), Hb - 20 * s - 10, 12f, Palette.text)
            StartButton(ctl, s, Modifier.offset(((W.value - 72 * min(s, 1.2f)) / 2).dp, (Hb - 50 * s - 94 * min(s, 1.2f)).dp))
            // 点托盘外面任何地方收起（这一层吃掉这次点击，不会误触摇杆和按钮）。
            if (ctl.tray) Box(Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, indication = null) { ctl.tray = false })
            if (ctl.tray) TrayBesideActions(ctl, s, H.value, 12 * s, railTop, DpSize(60.dp, 52.dp))
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
            val railTop = topY + 48 * s
            // 手机横屏：画面按真实比例在整个窗口里尽量放大、完整显示（顶栏和两侧控件浮在上面）；可以切换成铺满整屏。
            val aspect = LocalModel.current.session.media.videoAspect
            val camTop = if (wide) topY + 40 * s else 0f
            var limitH = if (wide) stickY - stick / 2 - 16 * s - camTop else H.value
            if (tabletop) limitH = min(limitH, hinge!!.top.value - if (wide) 12 + camTop else 0f)
            val limitW = if (wide) W.value - L0.value - R0.value - 2 * side * s else W.value
            val camH = min(limitH, limitW / aspect)
            val camW = camH * aspect
            val fill = !wide && !tabletop && (ctl.videoFill[false] ?: false)
            if (wide) Camera(ctl, voice, s, 60f, Modifier.at(((W.value - camW) / 2).dp, camTop.dp, camW.dp, camH.dp))
            else {
                VideoLayer(ctl, s, 60f, portrait = false, fill = fill,
                    Modifier.at(0.dp, 0.dp, W, limitH.dp))
                // 铺满时整体压暗一些，浮在画面上的字和按钮才看得清。
                if (fill) Box(Modifier.at(0.dp, 0.dp, W, H)
                    .background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Palette.bg.copy(alpha = 0.7f), Palette.bg.copy(alpha = 0.3f), Palette.bg.copy(alpha = 0.45f)))))
                LiveBadge(ctl, Modifier.offset(max(W.value / 2 - camW / 2 + 8, L0.value + (16 + 68 + 8) * s).dp, (railTop + 6).dp))
                // 按钮竖排在视频右边、和模式列顶边对齐（启动键左边的空白里）。
                CaptureButtons(ctl, Modifier.offset(min(W.value / 2 + camW / 2 + 8 * s, W.value - R0.value - (16 + 68 + 8) * s - 32).dp, railTop.dp),
                    fillToggle = false to fill, vertical = true)
                Box(Modifier.fillMaxWidth().offset(y = (railTop + 32).dp), contentAlignment = Alignment.TopCenter) { Toast(ctl, voice, camW - 16) }
            }
            TopBar(ctl, compact = false, Modifier.at(L0 + 16.dp, topY.dp, W - L0 - R0 - 32.dp, 36.dp))
            // 手机横屏和竖屏一样：模式列收成一个按钮，动作列可以收起，让出画面；宽窗口一直展开。
            ModeColumn(ctl, s, DpSize(60.dp, 54.dp), 2.dp, Palette.bg.copy(alpha = 0.78f), Modifier.offset(L0 + (16 * s).dp, railTop.dp), collapsible = !wide)
            ActionColumn(ctl, s, DpSize(60.dp, 46.dp), 2.dp, Palette.bg.copy(alpha = 0.78f), boxed = true,
                Modifier.align(Alignment.TopEnd).offset(-R0 - (16 * s).dp, railTop.dp), collapsible = !wide)
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
            Box(Modifier.fillMaxWidth().offset(y = (if (wide) camTop + camH - 22 * s - 22 else H.value - bottom.value - 34 * s - 22).dp), contentAlignment = Alignment.TopCenter) {
                Readout(ctl, 18f * min(s, 1.3f))
            }
            // 点托盘外面任何地方收起（这一层吃掉这次点击，不会误触摇杆和按钮）。
            if (ctl.tray) Box(Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, indication = null) { ctl.tray = false })
            // 宽窗口：视频右边到动作列之间放得下一列以上就排成网格，不盖视频；否则退回一行。
            val camRight = W.value / 2 + camW / 2
            val actLeft = W.value - R0.value - (16 + 68) * s
            val ps = min(s, 1.2f)
            val cols = ((actLeft - camRight - 12 * s - 2 * ps) / (66 * ps)).toInt()
            if (ctl.tray && wide && cols >= 1) {
                val c = min(cols, 4)
                val pw = c * 60 * ps + (c - 1) * 6 * ps + 8 * ps
                EmotionPanel(ctl, ps, DpSize(60.dp, 52.dp), Palette.bg, c, camH,
                    Modifier.offset(((camRight + actLeft - pw) / 2).dp, (camTop + 8 * s).dp))
            } else if (ctl.tray && wide) Box(Modifier.fillMaxWidth().offset(y = (camTop + camH - 70 * s).dp),
                contentAlignment = Alignment.TopCenter) { EmotionTray(ctl, s, DpSize(60.dp, 52.dp), Palette.bg, W.value - L0.value - R0.value - 2 * side * s) }
            else if (ctl.tray) TrayBesideActions(ctl, s, H.value, R0.value + 16 * s, railTop, DpSize(60.dp, 46.dp))
            if (voice.phase != VoiceController.Phase.Idle) VoiceOverlay(voice, W.value, H.value, if (wide) min(s, 1.3f) else s, portrait = false, micCenter = micCenter)
        }
    }
}

// ── 顶栏 ──

@Composable
private fun TopBar(ctl: DriveController, compact: Boolean, modifier: Modifier) {
    val model = LocalModel.current
    val session = model.session
    // 两种都浮在画面上：竖屏画面铺满，底色更透一些。
    val fill = Palette.bg.copy(alpha = if (compact) 0.6f else 0.78f)
    val border = Color.White.copy(alpha = 0.12f)
    val (label, dot) = ctl.stateLabel
    val reconnecting = session.linkState == LinkState.Reconnecting
    // 窄屏（约 450 dp 的手机、英文）放不下时只压缩左边的机器人标签（文字省略），右边电量 / 策略 / 电源保持完整。
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Row(Modifier.weight(1f, fill = false).padding(end = 8.dp).height(36.dp).background(fill).border(1.dp, border)
            .press(label = L("robot")) { session.disconnect(); model.path.clear() }
            .padding(start = 6.dp, end = if (compact) 12.dp else 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            DuckImage(Modifier.size(38.dp, 26.dp), quacking = ctl.quackDown)
            Dot(if (reconnecting) Palette.yellow else dot, 7.dp)
            T(if (reconnecting) L("reconnectingBle") else label, 13f, weight = FontWeight.SemiBold, maxLines = 1)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.height(36.dp).background(fill).border(1.dp, border).press(label = L("status")) { model.push(Route.Status) }
            .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            BatteryGlyph(session.batteryFraction)
            T(session.batteryPercentText + "%", 12f, weight = FontWeight.SemiBold, maxLines = 1)
            Box(Modifier.padding(horizontal = 3.dp).size(1.dp, 14.dp).background(Color.White.copy(alpha = 0.2f)))
            IconView(Icon.CHIP, 15.dp, weight = 2f)
            T(session.health?.cpuTempC?.let { "%.0f°".format(it) } ?: "--°", 12f, weight = FontWeight.SemiBold, maxLines = 1)
        }
        if (compact) CircleIconButton(Icon.BRAIN, L("policy"), fill = fill) { model.push(Route.Policy) }
        else {
            Row(Modifier.height(36.dp).background(fill).border(1.dp, border).press { model.push(Route.Policy) }.padding(start = 10.dp, end = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                IconView(Icon.BRAIN, 18.dp); T(L("policy"), 12f, weight = FontWeight.SemiBold)
            }
        }
        PowerButton(ctl, fill, border)
        }
    }
}

/**
 * 电源键：图标 + 文字的方块，长按时粉条从左往右走，文字提示松手后会做什么（2 秒休息、4 秒关机）。
 * 可视高度 36，触摸区四周各外扩 8dp（不占布局）。
 */
@Composable
private fun PowerButton(ctl: DriveController, fill: Color, border: Color) {
    val held = ctl.powerHeld
    val text = if (held >= 4f) L("powerHoldOff") else if (held >= 2f) L("powerHoldRest") else L("powerBtn")
    val tint = if (held >= 2f) Palette.bg else Palette.pink
    Box(Modifier.expandTouch(8.dp)
        .holdGesture({ ctl.powerHeld = it }) { ctl.powerReleased(it) }
        .semantics { contentDescription = L("powerAria"); role = Role.Button }
        .padding(8.dp)
        .height(36.dp).background(fill).border(1.dp, if (held > 0f) Palette.pink else border)) {
        Box(Modifier.matchParentSize().drawBehind {
            drawRect(Palette.pink, size = size.copy(width = size.width * min(held / 4f, 1f)))
        })
        Row(Modifier.fillMaxHeight().padding(start = 9.dp, end = 11.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            IconView(Icon.POWER, 18.dp, tint, 2f)
            T(text, 12f, color = tint, weight = FontWeight.Bold, maxLines = 1)
        }
    }
}

/** 把触摸区向四周外扩 [pad]，但对外报告的尺寸不变：子节点先 padding(pad)，这里再把它缩回去、平移 -pad。 */
private fun Modifier.expandTouch(pad: Dp): Modifier = layout { m, c ->
    val p = pad.roundToPx()
    val placeable = m.measure(c.copy(maxWidth = if (c.hasBoundedWidth) c.maxWidth + 2 * p else c.maxWidth,
        maxHeight = if (c.hasBoundedHeight) c.maxHeight + 2 * p else c.maxHeight))
    val w = (placeable.width - 2 * p).coerceAtLeast(0)
    val h = (placeable.height - 2 * p).coerceAtLeast(0)
    layout(w, h) { placeable.place(-p, -p) }
}

// ── 视频框 ──

/** 宽窗口的视频框：画面、LIVE 标签、拍照 / 录像 / 画面开关、提示、准星都在框里。 */
@Composable
private fun Camera(ctl: DriveController, voice: VoiceController, s: Float, gaze: Float, modifier: Modifier) {
    Box(modifier.border(1.dp, Color.White.copy(alpha = 0.14f)).clipToBounds()) {
        VideoLayer(ctl, s, gaze, portrait = null, fill = true, Modifier.fillMaxSize())
        LiveBadge(ctl, Modifier.padding(8.dp))
        CaptureButtons(ctl, Modifier.align(Alignment.TopEnd).padding(6.dp))
        Box(Modifier.align(Alignment.TopCenter).padding(top = 8.dp)) { Toast(ctl, voice, 320f) }
    }
}

/**
 * 画面本身（或"画面已关闭"）加准星。[fill]：等比铺满、裁掉多出的部分；否则完整显示、留黑边。
 * [portrait] 不为空时（手机），双击画面切换铺满 / 完整显示。
 */
@Composable
private fun VideoLayer(ctl: DriveController, s: Float, gaze: Float, portrait: Boolean?, fill: Boolean, modifier: Modifier) {
    val media = LocalModel.current.session.media
    // 看着画面开车时不熄屏；关了相机或没出帧就交还给系统。
    val view = androidx.compose.ui.platform.LocalView.current
    val keepAwake = ctl.camOn && media.videoLive
    DisposableEffect(view, keepAwake) {
        view.keepScreenOn = keepAwake
        onDispose { view.keepScreenOn = false }
    }
    BoxWithConstraints(modifier.background(Palette.video).clipToBounds().semantics { contentDescription = L("cameraRegion") },
        contentAlignment = Alignment.Center) {
        if (ctl.camOn) {
            // 按画面真实比例：铺满取较大的一边（裁掉多出的部分），完整显示取较小的一边（留黑边）。
            val a = media.videoAspect
            val tall = maxWidth / a
            val byWidth = if (fill) tall >= maxHeight else tall <= maxHeight
            if (byWidth) media.VideoView(Modifier.requiredSize(maxWidth, tall))
            else media.VideoView(Modifier.requiredSize(maxHeight * a, maxHeight))
        } else Column(Modifier.fillMaxSize().background(Palette.panel), verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally) {
            IconView(Icon.CAM_OFF, 34.dp, Palette.disabled, 2f); T(L("camIsOff"), 12f, color = Palette.disabled, weight = FontWeight.Bold)
        }
        if (portrait != null) Box(Modifier.matchParentSize().pointerInput(portrait, fill) {
            detectTapGestures(onDoubleTap = { ctl.videoFill[portrait] = !fill })
        })
        Reticle(Modifier.offset((ctl.reticle.x * gaze * s).dp, (ctl.reticle.y * gaze * 1.85f * s).dp))
    }
}

/** 左上角的 LIVE / OFF 标签；录像时换成 REC 和已录时长。 */
@Composable
private fun LiveBadge(ctl: DriveController, modifier: Modifier) {
    val media = LocalModel.current.session.media
    Row(modifier.height(20.dp).background(Palette.bg.copy(alpha = 0.72f)).padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val since = ctl.recordingSince
        if (since != null) {
            var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
            LaunchedEffect(since) { while (isActive) { now = System.currentTimeMillis(); delay(500) } }
            Dot(Palette.pink, 6.dp)
            T("REC", 10f, weight = FontWeight.ExtraBold)
            T(formatDuration((now - since) / 1000), 10f, weight = FontWeight.SemiBold)
        } else {
            Dot(if (ctl.camOn) Palette.pink else Palette.disabled, 6.dp)
            T(if (ctl.camOn) "LIVE" else "OFF", 10f, weight = FontWeight.ExtraBold)
            val kbps = media.videoKbps
            if (ctl.camOn && kbps != null) T(formatBitrate(kbps), 10f, color = Palette.dim, weight = FontWeight.SemiBold)
        }
    }
}

/** 提示条（动作结果、警告）；语音面板打开时不显示。 */
@Composable
private fun Toast(ctl: DriveController, voice: VoiceController, maxWidth: Float) {
    val t = ctl.toast
    if (t != null && voice.phase == VoiceController.Phase.Idle) {
        Box(Modifier.widthIn(max = maxWidth.dp).background(Palette.bg.copy(alpha = 0.78f)).padding(horizontal = 12.dp, vertical = 6.dp)) {
            T(t.first, 12f, color = if (t.second) Palette.yellow else Palette.text, weight = FontWeight.SemiBold, maxLines = 3)
        }
    }
}

/**
 * 拍照、录像、开关画面三个按钮（一行）。竖屏和宽窗口放在视频右上角；手机横屏视频框太窄（约 140 dp），
 * 放在视频右边的空白里，不压住 LIVE 标签和画面。
 */
@Composable
private fun CaptureButtons(ctl: DriveController, modifier: Modifier, fillToggle: Pair<Boolean, Boolean>? = null, vertical: Boolean = false) {
    val withCapturePermissions = LocalCapturePermissions.current
    val line: @Composable (@Composable () -> Unit) -> Unit = { content ->
        if (vertical) Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) { content() }
        else Row(modifier, horizontalArrangement = Arrangement.spacedBy(4.dp)) { content() }
    }
    line {
        // 手机上多一个铺满 / 完整显示的切换键（是否竖屏 to 当前是否铺满）。
        if (fillToggle != null && ctl.camOn) {
            val (portrait, fill) = fillToggle
            OverlayButton(if (fill) Icon.SHRINK else Icon.EXPAND, if (fill) L("videoFit") else L("videoFill")) { ctl.videoFill[portrait] = !fill }
        }
        if (ctl.camOn) {
            OverlayButton(Icon.SHUTTER, L("takePhoto")) { withCapturePermissions(false) { ctl.takePhoto() } }
            OverlayButton(if (ctl.recording) Icon.STOP else Icon.RECORD, if (ctl.recording) L("recStop") else L("recStart"), ctl.recording) {
                if (ctl.recording) ctl.stopRecording() else withCapturePermissions(true) { ctl.toggleRecord() }
            }
        }
        OverlayButton(if (ctl.camOn) Icon.CAM_ON else Icon.CAM_OFF, if (ctl.camOn) L("camTurnOff") else L("camTurnOn")) { ctl.toggleCam() }
    }
}

/** 视频右上角的方形小按钮（拍照、录像、开关画面）；`on` 时粉底（正在录像）。 */
@Composable
private fun OverlayButton(icon: Icon, label: String, on: Boolean = false, action: () -> Unit) {
    Box(Modifier.size(32.dp).background(if (on) Palette.pink else Palette.bg.copy(alpha = 0.72f))
        .border(1.dp, if (on) Palette.pink else Color.White.copy(alpha = 0.18f)).press(label = label, onClick = action),
        contentAlignment = Alignment.Center) { IconView(icon, 17.dp, if (on) Palette.bg else Palette.text, 2f) }
}

/**
 * 拍照 / 录像前先要权限：Android 9 及以下存相册要写存储权限，录像要麦克风（拒绝了也照录，音轨是静音）。
 * 由 [DriveScreen] 提供。
 */
private val LocalCapturePermissions = compositionLocalOf<(Boolean, () -> Unit) -> Unit> { { _, go -> go() } }

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

/** 摇杆模式（行走 / 头部）。[collapsible]（手机）：只放一个按钮显示当前模式，点一下切到另一个；宽窗口两个都列出来。 */
@Composable
private fun ModeColumn(ctl: DriveController, s: Float, button: DpSize, gap: Dp, fill: Color, modifier: Modifier, collapsible: Boolean = false) {
    val all = listOf(Triple(DriveController.Mode.Walk, L("mWalk"), Icon.MOVE), Triple(DriveController.Mode.Head, L("mHead"), Icon.HEAD))
    val modes = if (collapsible) all.filter { it.first == ctl.mode } else all
    Column(modifier.background(fill).border(1.dp, Color.White.copy(alpha = 0.12f)).padding((4 * s).dp)
        .semantics { contentDescription = L("modeAria") }, verticalArrangement = Arrangement.spacedBy(gap * s)) {
        modes.forEach { (m, name, icon) ->
            val on = ctl.mode == m
            val other = all.first { it.first != m }
            Box(Modifier.size(button.width * s, button.height * s).background(if (on) Palette.orange else Color.Transparent)
                .press(role = if (collapsible) Role.Button else Role.RadioButton,
                    label = if (collapsible) "$name，${L("modeSwitchTo")} ${other.second}" else null) {
                    ctl.mode = if (collapsible) other.first else m
                    ctl.tray = false
                }.semantics { selected = on }) {
                Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
                    IconView(icon, (22 * min(s, 1.2f)).dp, if (on) Palette.bg else Palette.text)
                    T(name, 11f, color = if (on) Palette.bg else Palette.text, weight = FontWeight.SemiBold, maxLines = 1)
                }
                if (collapsible) IconView(Icon.SWAP, 11.dp, Palette.bg, 2.6f, Modifier.align(Alignment.TopEnd).padding(3.dp))
            }
        }
    }
}

@Composable
private fun ActionColumn(ctl: DriveController, s: Float, button: DpSize, gap: Dp, fill: Color, boxed: Boolean, modifier: Modifier,
                         collapsible: Boolean = false) {
    // [collapsible]（手机竖屏）：顶上一个收起 / 展开键，收起后只剩这个键。
    val open = !collapsible || ctl.actionsOpen
    Column(modifier.then(if (boxed) Modifier.background(fill).border(1.dp, Color.White.copy(alpha = 0.12f)).padding((4 * s).dp) else Modifier),
        verticalArrangement = Arrangement.spacedBy(gap * s)) {
        if (collapsible) Box(Modifier.size(button.width * s, (24 * s).dp).press(label = if (open) L("actionsHide") else L("actionsShow")) {
            ctl.actionsOpen = !ctl.actionsOpen
            ctl.tray = false
        }, contentAlignment = Alignment.Center) {
            IconView(Icon.CHEVRON, 16.dp, Palette.text, 2.4f, Modifier.rotate(if (open) 180f else 0f))
        }
        if (open) ctl.actions.forEach { a ->
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
private fun TrayButton(e: DriveController.Emotion, s: Float, button: DpSize) {
    val fg = if (e.on) Palette.bg else Palette.text
    Column(Modifier.size(button.width * s, button.height * s).background(if (e.on) Palette.orange else Color.Transparent)
        .press(label = e.name, onClick = e.go).semantics { selected = e.on },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
        IconView(e.icon, 22.dp, if (e.on) Palette.bg else e.color, 2f); T(e.name, 11f, color = fg, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

/**
 * 手机上的托盘：从"更多"旁边弹出——贴在动作列左边、底边和动作列（"更多"在最下面）对齐，排成三列往上长，
 * 右手拇指顺手就点到。最高到动作列顶，放不下时露出半行。[button]：动作列按钮的尺寸，用来算动作列的高度。
 */
@Composable
private fun TrayBesideActions(ctl: DriveController, s: Float, H: Float, trailing: Float, top: Float, button: DpSize) {
    val n = ctl.actions.size
    val colH = 8 * s + (24 + 2) * s + n * button.height.value * s + (n - 1).coerceAtLeast(0) * 2 * s
    val colW = button.width.value * s + 8 * s
    Box(Modifier.fillMaxSize().padding(end = (trailing + colW + 6 * s).dp, bottom = (H - top - colH).coerceAtLeast(0f).dp),
        contentAlignment = Alignment.BottomEnd) {
        EmotionPanel(ctl, min(s, 1.2f), DpSize(60.dp, 52.dp), Palette.bg, 3, colH, Modifier)
    }
}

/** 托盘（一行）：玩法开关在前，然后是叫声和情绪；放不下时横向滑动。用在手机竖屏（视频下方）和手机横屏。 */
@Composable
private fun EmotionTray(ctl: DriveController, s: Float, button: DpSize, fill: Color, maxWidth: Float) {
    val items = ctl.trayItems
    val content = items.size * button.width.value * s + (items.size - 1).coerceAtLeast(0) * 6 * s
    Row(Modifier.background(fill).border(1.dp, Color.White.copy(alpha = 0.14f)).padding((4 * s).dp)
        .width(peek(content, maxWidth - 8 * s, button.width.value * s, 6 * s).dp).horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy((6 * s).dp)) {
        items.forEach { TrayButton(it, s, button) }
    }
}

/** 托盘放不下时的可见长度：停在某个按钮的一半，让后面的按钮露出半截图标和文字，一看就知道还能滑；放得下时就是内容本身。 */
private fun peek(content: Float, limit: Float, item: Float, gap: Float): Float {
    if (content <= limit) return content
    val whole = kotlin.math.floor((limit - item / 2) / (item + gap)).coerceAtLeast(0f)
    return whole * (item + gap) + item / 2
}

/** 宽窗口的托盘：放在视频和右侧动作列之间的空白里，排成网格，不盖住视频。 */
@Composable
private fun EmotionPanel(ctl: DriveController, s: Float, button: DpSize, fill: Color, columns: Int, maxHeight: Float, modifier: Modifier) {
    Column(modifier.background(fill).border(1.dp, Color.White.copy(alpha = 0.14f)).padding((4 * s).dp)
        .heightIn(max = run {
            val rows = (ctl.trayItems.size + columns - 1) / columns
            peek(rows * button.height.value * s + (rows - 1).coerceAtLeast(0) * 6 * s, maxHeight - 8 * s, button.height.value * s, 6 * s)
        }.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy((6 * s).dp)) {
        ctl.trayItems.chunked(columns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy((6 * s).dp)) { row.forEach { TrayButton(it, s, button) } }
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

/** 视频码率：1 Mbps 以下按 kbps，以上保留一位小数。 */
/** 录像时长：m:ss，一小时以上 h:mm:ss。 */
fun formatDuration(seconds: Long): String {
    val t = maxOf(0L, seconds)
    return if (t >= 3600) String.format(java.util.Locale.US, "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    else String.format(java.util.Locale.US, "%d:%02d", t / 60, t % 60)
}

fun formatBitrate(kbps: Int): String = if (kbps < 1000) "$kbps kbps" else String.format(java.util.Locale.US, "%.1f Mbps", kbps / 1000.0)
