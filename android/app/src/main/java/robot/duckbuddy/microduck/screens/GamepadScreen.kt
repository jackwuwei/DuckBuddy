package robot.duckbuddy.microduck.screens

import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import robot.duckbuddy.microduck.design.*
import kotlinx.coroutines.launch
import uniffi.duck_core.DuckCall
import uniffi.duck_core.PadTarget
import uniffi.duck_core.decodePadBindings
import uniffi.duck_core.isShippedEmotion
import robot.duckbuddy.microduck.drive.EmotionStyle

/** 手柄按键（设计稿 PortraitButtons / Mapping）：A B X Y LB RB 六个可绑定键，"—"为不绑定。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun GamepadScreen() {
    val model = LocalModel.current
    val session = model.session
    val layout = LocalLayout.current
    val scope = rememberCoroutineScope()
    var sel by remember { mutableStateOf("x") }
    val keys = listOf("a", "b", "x", "y", "lb", "rb")
    val colors = mapOf("a" to Palette.cyan, "b" to Palette.pink, "x" to Palette.purple, "y" to Palette.orange, "lb" to Color.White, "rb" to Color.White)
    suspend fun reload() { runCatching { session.bindings = decodePadBindings(session.call(DuckCall.PadBindings)) } }
    LaunchedEffect(Unit) { reload() }
    fun binding(k: String) = session.bindings.firstOrNull { it.button == k }?.skill.orEmpty()
    fun label(n: String) = mapOf("sit_toggle" to L("slotSitstand"), "ground_pick" to L("pickUp"), "kick_left" to L("kickL"),
        "kick_right" to L("kickR"), "roulade" to L("roulade"))[n] ?: if (isShippedEmotion(n)) EmotionStyle.label(n) else n
    val portrait = layout == LayoutClass.PhonePortrait

    @Composable
    fun KeyButton(k: String, height: Int, circle: Int, modifier: Modifier) {
        val on = sel == k
        val skill = binding(k)
        val dead = session.isRoller && (k == "a" || k == "x")
        Column(modifier.heightIn(min = height.dp).background(Palette.card).border(2.dp, if (on) Palette.orange else Color.Transparent)
            .press(role = Role.RadioButton) { sel = k }.semantics { selected = on },
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
            val a = if (dead) 0.45f else 1f
            Box(Modifier.size(circle.dp).border(2.dp, colors[k]!!.copy(alpha = a), CircleShape), contentAlignment = Alignment.Center) {
                T(k.uppercase(), 15f, color = colors[k]!!.copy(alpha = a), weight = FontWeight.Bold)
            }
            T(if (skill.isEmpty()) "—" else label(skill), 13f, color = if (skill.isEmpty()) Palette.disabled else Palette.text.copy(alpha = a), weight = FontWeight.SemiBold, maxLines = 1)
        }
    }

    Column(Modifier.fillMaxSize().background(Palette.bg).safeDrawingPadding()
        .padding(horizontal = if (portrait) 16.dp else 40.dp).padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(if (portrait) 20.dp else 24.dp)) {
        TitleBar(L("padTitle"), { model.pop() }) {
            SquareAction(Icon.RESET, L("padReset")) {
                scope.launch { keys.forEach { session.intent(DuckCall.PadBind(it, PadTarget.Default)) }; reload() }
            }
        }
        Box(Modifier.fillMaxWidth(), contentAlignment = if (portrait) Alignment.CenterStart else Alignment.Center) {
            T(L("padHint"), 13f, color = Palette.dim, lineHeight = 19.5f)
        }
        if (session.isRoller) T(L("padRollerNote"), 12f, color = Palette.yellow, weight = FontWeight.Bold)
        if (portrait) {
            keys.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { row.forEach { KeyButton(it, 120, 46, Modifier.weight(1f)) } }
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally)) {
                keys.forEach { KeyButton(it, 124, 44, Modifier.widthIn(max = if (layout.isWide) 146.dp else 104.dp).weight(1f, fill = false).width(146.dp)) }
            }
        }
        // 机器人上的全部技能（含内置），再加自带的情绪动作；"—"为不绑定。
        val skills = session.skills.filter { !it.disabled }.map { it.name }
        val choices = listOf("" to "—") + (skills + session.emotions.map { it.name }.filter { it !in skills }).map { it to label(it) }
        FlowRow(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp, if (portrait) Alignment.Start else Alignment.CenterHorizontally),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            choices.forEach { (value, text) ->
                val on = binding(sel) == value
                Box(Modifier.height(if (portrait) 40.dp else 36.dp).background(if (on) Palette.orange else Palette.card)
                    .press(role = Role.RadioButton) {
                        scope.launch { session.intent(DuckCall.PadBind(sel, if (value.isEmpty()) PadTarget.Off else PadTarget.Skill(value))); reload() }
                    }.semantics { selected = on }.padding(horizontal = if (portrait) 16.dp else 14.dp), contentAlignment = Alignment.Center) {
                    T(text, if (portrait) 14f else 13f, color = if (on) Palette.bg else Palette.light, weight = FontWeight.SemiBold)
                }
            }
        }
    }
}
