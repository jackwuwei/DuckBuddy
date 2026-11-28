package robot.duckbuddy.microduck.screens

import kotlin.math.roundToInt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.LocalModel
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.state.KnownRobot
import robot.duckbuddy.microduck.state.Route
import uniffi.duck_core.batteryFraction

/** 连接页（设计稿 PortraitConnect / Connect）。 */
@Composable
fun ConnectScreen() {
    val model = LocalModel.current
    val layout = LocalLayout.current
    var connecting by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { model.session.startScan() }

    fun toggle(id: String) { model.selectedID = if (model.selectedID == id) null else id }
    val rescan: @Composable () -> Unit = {
        CircleIconButton(Icon.RESCAN, L("rescan")) { model.session.stopScan(); model.session.startScan(); model.say(L("rescan")) }
    }
    val connect: @Composable (Float, Float, Boolean) -> Unit = { h, font, fill ->
        val can = model.selectedID != null && !connecting
        Box(
            (if (fill) Modifier.fillMaxWidth() else Modifier).height(h.dp).hardShadow(Palette.yellow)
                .background(if (can) Palette.orange else Palette.inset).border(2.dp, Palette.bg)
                .press(can) { connecting = true; model.connectSelected { connecting = false } }.padding(horizontal = 44.dp),
            contentAlignment = Alignment.Center,
        ) { Title(if (connecting) L("connecting") else L("connect"), font, color = if (can) Palette.bg else Palette.disabled, tracking = 0.04f) }
    }

    Box(Modifier.fillMaxSize().background(Palette.bg).safeDrawingPadding()) {
        if (layout == LayoutClass.PhonePortrait) {
            Column(Modifier.fillMaxSize().padding(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row { Spacer(Modifier.weight(1f)); rescan() }
                Column(Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    DuckImage(Modifier.size(180.dp, 107.dp))
                    Title(L("appName"), 34f)
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    model.robots.forEach { r -> RowCard(r, model.selectedID == r.id) { toggle(r.id) } }
                    Row(Modifier.fillMaxWidth().dashedBorder().press { model.push(Route.Setup) }.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(Modifier.size(56.dp, 40.dp), contentAlignment = Alignment.Center) { IconView(Icon.PLUS, 24.dp, Palette.light) }
                        T(L("setupDuck"), 15f, color = Palette.light, weight = FontWeight.SemiBold)
                    }
                }
                connect(56f, 22f, true)
            }
        } else if (LocalHinge.current?.vertical == true) {
            // 竖直铰链（书本姿态 / 双屏）：logo 与主按钮在左屏，机器人列表在右屏，任何卡片都不跨铰链。
            Box(Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 16.dp)) {
                TwoPane(primary = {
                    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically),
                        horizontalAlignment = Alignment.CenterHorizontally) {
                        DuckImage(Modifier.size(180.dp, 107.dp)); Title(L("appName"), 34f); connect(56f, 22f, false)
                    }
                }) {
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
                        model.robots.forEach { r -> RowCard(r, model.selectedID == r.id) { toggle(r.id) } }
                        Row(Modifier.fillMaxWidth().dashedBorder().press { model.push(Route.Setup) }.padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            Box(Modifier.size(56.dp, 40.dp), contentAlignment = Alignment.Center) { IconView(Icon.PLUS, 24.dp, Palette.light) }
                            T(L("setupDuck"), 15f, color = Palette.light, weight = FontWeight.SemiBold)
                        }
                    }
                }
            }
            Box(Modifier.align(Alignment.TopEnd).padding(top = 12.dp, end = 16.dp)) { rescan() }
        } else {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally) {
                if (layout.isWide) Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    DuckImage(Modifier.size(180.dp, 107.dp))
                    Title(L("appName"), 34f)
                }
                // 放得下就居中（设计稿），放不下再横向滚动。
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 6.dp).height(IntrinsicSize.Max),
                    horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    model.robots.forEach { r -> TallCard(r, model.selectedID == r.id) { toggle(r.id) } }
                    Column(Modifier.width(200.dp).fillMaxHeight().dashedBorder().press { model.push(Route.Setup) }.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.size(72.dp).background(Palette.card, CircleShape).border(1.dp, Palette.hairline, CircleShape), contentAlignment = Alignment.Center) {
                            IconView(Icon.PLUS, 28.dp)
                        }
                        T(L("setupDuck"), 15f, color = Palette.dim, weight = FontWeight.SemiBold)
                    }
                }
                connect(52f, 20f, false)
            }
            Box(Modifier.align(Alignment.TopEnd).padding(top = 12.dp, end = 16.dp)) { rescan() }
        }
    }
}

@Composable
private fun Info(r: KnownRobot) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconView(Icon.SIGNAL, 14.dp, Palette.light, 2.2f)
            T(if (r.lastIPv4 != null) L("linkWifi") else L("linkBle"), 12f, color = Palette.light)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            BatteryGlyph(r.lastVolts?.let { batteryFraction(it) } ?: 0.0, Palette.light)
            T(r.lastVolts?.let { "${(batteryFraction(it) * 100).roundToInt()}%" } ?: "--", 12f, color = Palette.light)
        }
    }
}

@Composable
private fun RowCard(r: KnownRobot, on: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().selectable(on).background(Palette.card).press(role = Role.RadioButton, onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        DuckImage(Modifier.size(56.dp, 40.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T(r.displayName, 16f, weight = FontWeight.Bold, maxLines = 1)
            Info(r)
        }
    }
}

@Composable
private fun TallCard(r: KnownRobot, on: Boolean, onClick: () -> Unit) {
    Column(Modifier.width(200.dp).selectable(on).background(Palette.card).press(role = Role.RadioButton, onClick = onClick)
        .padding(vertical = 20.dp, horizontal = 14.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        DuckImage(Modifier.size(110.dp, 72.dp))
        Title(r.displayName, 20f)
        Info(r)
    }
}
