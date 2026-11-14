package robot.duckbuddy.microduck.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.LocalModel
import robot.duckbuddy.microduck.ScreenFrame
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.state.DemoRobot
import robot.duckbuddy.microduck.state.Route
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.duck_core.*
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt

/** 状态页（设计稿 PortraitStatus / Telemetry）：3D 姿态、站姿、电池 / 舵机 / 主控温度、15 个舵机偏差。 */
@Composable
fun StatusScreen() {
    val model = LocalModel.current
    val session = model.session
    val layout = LocalLayout.current
    val scope = rememberCoroutineScope()
    var degrees by remember { mutableStateOf(true) }
    var sim by remember { mutableStateOf(SimState.Loading) }
    var resetToken by remember { mutableIntStateOf(0) }
    var rebooting by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { session.refreshHealth(); delay(5000) } }

    val viewer: @Composable (Modifier) -> Unit = { m ->
        val p = session.state?.posture
        val (label, color, note) = when (p?.posture) {
            Posture.STANDING -> Triple(L("pStanding"), Palette.cyan, L("nStanding"))
            Posture.SEATED -> Triple(L("pSeated"), Palette.purple, L("nSeated"))
            Posture.LYING -> Triple(L("pLying"), Palette.pink, L("nLying"))
            Posture.UNSURE -> Triple(L("pUnsure"), Palette.yellow, L("nUnsure"))
            null -> Triple("—", Palette.dim, L("noStream"))
        }
        val nums = p?.let { L("pNums", if (it.posture == Posture.LYING) "—" else "${(it.heightRatio * 100).roundToInt()}%", it.tiltDeg.roundToInt()) } ?: ""
        Column(m.background(Palette.panel).border(1.dp, Palette.hairline)) {
            Row(Modifier.fillMaxWidth().height(40.dp).padding(start = 12.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Title(label, 22f, Modifier.semantics { contentDescription = L("posture") + " " + label }, color)
                Column(Modifier.weight(1f)) { T(nums, 11f, color = Palette.light, maxLines = 1); T(note, 10f, color = Palette.dim, maxLines = 1) }
                Box(Modifier.size(30.dp).border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape).press(label = L("resetView")) { resetToken++ },
                    contentAlignment = Alignment.Center) { IconView(Icon.RESET_VIEW, 16.dp, Palette.light) }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.08f)))
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                DuckViewer(session.state?.joints ?: DemoRobot.HOME, session.state?.quat, model.colourway, resetToken, { sim = it },
                    Modifier.fillMaxSize().semantics { contentDescription = L("simHint") })
                if (sim == SimState.Ready) ColourwayPicker(Modifier.align(Alignment.BottomStart).padding(start = 4.dp, bottom = 2.dp))
                if (sim != SimState.Ready) T(if (sim == SimState.Failed) L("simFail") else L("simLoading"), 12f,
                    color = if (sim == SimState.Failed) Palette.pink else Palette.dim, weight = FontWeight.SemiBold)
            }
        }
    }

    val stats: @Composable (Float) -> Unit = { height ->
        val h = session.health
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(Triple(null as Icon?, h?.batteryVolts?.let { "%.1f".format(it) } ?: "--", " V" to L("battery")),
                Triple(Icon.TEMP, h?.motorMaxC?.let { "%.0f".format(it) } ?: "--", " °C" to L("servoMax")),
                Triple(Icon.CHIP, h?.cpuTempC?.let { "%.0f".format(it) } ?: "--", " °C" to L("board"))).forEach { (icon, value, ul) ->
                Row(Modifier.weight(1f).height(height.dp).card().padding(horizontal = 8.dp).semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.size(34.dp).background(Palette.inset, CircleShape), contentAlignment = Alignment.Center) {
                        if (icon != null) IconView(icon, 18.dp, weight = 2f) else BatteryGlyph(session.batteryFraction)
                    }
                    Column {
                        Row(verticalAlignment = Alignment.Bottom) { Title(value, 22f); T(ul.first, 12f, color = Palette.dim) }
                        T(ul.second, 11f, color = Palette.dim, maxLines = 1)
                    }
                }
            }
        }
    }

    val jointsCard: @Composable (Modifier) -> Unit = { m ->
        val names = listOf("jHipYaw", "jHipRoll", "jHipPitch", "jKnee", "jAnkle")
        val headNames = listOf("jNeckPitch", "jHeadPitch", "jHeadYaw", "jHeadRoll", "jMouth")
        val ids = jointIds()
        val groups = listOf(Triple(L("gLeft"), Icon.FOOT, 0 to names), Triple(L("gHead"), Icon.HEAD_SMALL, 5 to headNames), Triple(L("gRight"), Icon.FOOT, 10 to names))
        Column(m.card().padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Title(L("joints"), 16f)
                T(L("legend"), 10.5f, Modifier.weight(1f), color = Palette.dim, maxLines = 1)
                Row(Modifier.background(Palette.bg).border(1.dp, Color.White.copy(alpha = 0.12f)).padding(2.dp)) {
                    for ((t, on) in listOf("°" to degrees, "rad" to !degrees)) Box(
                        Modifier.heightIn(min = 26.dp).widthIn(min = 34.dp).background(if (on) Palette.orange else Color.Transparent)
                            .press(role = Role.RadioButton) { degrees = t == "°" }.semantics { selected = on }, contentAlignment = Alignment.Center) {
                        T(t, 12f, color = if (on) Palette.bg else Palette.light, weight = FontWeight.Bold)
                    }
                }
            }
            LazyVerticalGrid(GridCells.Fixed(if (layout == LayoutClass.Expanded) 2 else 1), horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(groups) { (gname, icon, spec) ->
                    Column {
                        Row(Modifier.height(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            IconView(icon, 14.dp, Palette.dim); T(gname, 11f, color = Palette.dim, weight = FontWeight.Bold)
                        }
                        spec.second.forEachIndexed { k, key -> JointRow(spec.first + k, ids[spec.first + k].toInt(), L(key), degrees) }
                    }
                }
            }
        }
    }

    ScreenFrame {
        TitleBar(L("statusTitle"), { model.pop() }) {
            Box(Modifier.size(36.dp).card().press(label = L("settings")) { model.push(Route.Settings) }, contentAlignment = Alignment.Center) {
                IconView(Icon.GEAR, 18.dp)
            }
            SquareAction(Icon.RESET, L("rebootServos"), enabled = !rebooting) {
                scope.launch {
                    rebooting = true
                    session.intent(DuckCall.RobotRebootMotors(ByteArray(0)))?.let { model.say(it, true) } ?: model.say(L("rebooted"))
                    rebooting = false
                }
            }
        }
        if (layout == LayoutClass.PhonePortrait) {
            viewer(Modifier.fillMaxWidth().height(420.dp))
            stats(60f)
            jointsCard(Modifier.weight(1f).fillMaxWidth())
        } else {
            TwoPane(if (layout == LayoutClass.PhoneLandscape) 0.47f else 0.5f, Modifier.weight(1f), primary = { viewer(Modifier.fillMaxSize()) }) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    stats(if (layout == LayoutClass.PhoneLandscape) 50f else 60f)
                    jointsCard(Modifier.weight(1f).fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun JointRow(index: Int, id: Int, name: String, degrees: Boolean) {
    val state = LocalModel.current.session.state
    val meas = state?.joints?.getOrNull(index)
    val cmd = state?.targets?.getOrNull(index)
    val errDeg = if (meas != null && cmd != null) (meas - cmd) * 180 / PI else 0.0
    val frac = (errDeg / 5).coerceIn(-1.0, 1.0).toFloat()
    val color = if (meas != null && cmd != null) when (deviationLevel(meas, cmd)) {
        DeviationLevel.FINE -> Palette.muted; DeviationLevel.WARN -> Palette.yellow; DeviationLevel.BAD -> Palette.pink
    } else Palette.muted
    fun fmt(r: Double) = if (degrees) "%.1f°".format(r * 180 / PI) else "%.3f".format(r)
    Row(Modifier.fillMaxWidth().height(30.dp).semantics(mergeDescendants = true) {
        contentDescription = "$name ${meas?.let(::fmt) ?: "--"}" + (cmd?.let { " · ${L("cmd")} ${fmt(it)} · ${L("err")} %.1f°".format(errDeg) } ?: "")
    }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        T("$id", 10f, Modifier.width(18.dp), color = Palette.muted)
        T(name, 12.5f, Modifier.weight(1f), color = Palette.light, maxLines = 1)
        Box(Modifier.size(72.dp, 8.dp), contentAlignment = Alignment.CenterStart) {
            Box(Modifier.fillMaxWidth().height(4.dp).background(Palette.inset))
            Box(Modifier.offset(35.5.dp).size(1.dp, 8.dp).background(Color.White.copy(alpha = 0.35f)))
            val l = if (frac < 0) 50 + frac * 50 else 50f
            Box(Modifier.offset((l / 100 * 72).dp).size((maxOf(1.5f, abs(frac) * 50) / 100 * 72).dp, 4.dp).background(color))
        }
        T(meas?.let(::fmt) ?: "--", 14f, Modifier.width(58.dp), weight = FontWeight.Bold)
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.06f)))
}

/** 官方四种配色（与官网色块一致），选了只改 3D 模型的外壳颜色，按机器人记住。 */
@Composable
private fun ColourwayPicker(modifier: Modifier) {
    val model = LocalModel.current
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (c in colourwayAll()) {
            val on = model.colourway == c
            val name = when (c) {
                Colourway.CREAM -> "cwCream"; Colourway.GRAPHITE -> "cwGraphite"
                Colourway.LAVENDER -> "cwLavender"; Colourway.SKY -> "cwSky"
            }
            Box(Modifier.size(40.dp).press(role = Role.RadioButton, label = L("colourway") + " " + L(name)) { model.setColourway(c) },
                contentAlignment = Alignment.Center) {
                Box(Modifier.size(22.dp).selectable(on).background(Color(0xFF000000L or colourwaySwatch(c).toLong()))
                    .border(2.dp, if (on) Palette.orange else Palette.bg))
            }
        }
    }
}
