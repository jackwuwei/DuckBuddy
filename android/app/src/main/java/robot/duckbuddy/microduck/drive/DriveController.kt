package robot.duckbuddy.microduck.drive

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.design.Icon
import robot.duckbuddy.microduck.design.Palette
import robot.duckbuddy.microduck.state.AppModel
import robot.duckbuddy.microduck.state.Power
import kotlinx.coroutines.*
import uniffi.duck_core.*
import kotlin.math.PI

/**
 * 驾驶页逻辑（与 iOS `DriveController.swift` 一一对应）：模式、摇杆发送、动作前置条件、
 * 启动键（短按启动 / 出发 / 停止，长按 1.5 s 回初始姿态）、电源键（长按 2 s 休息、4 s 关机）。
 */
class DriveController(private val model: AppModel, private val scope: CoroutineScope) {
    enum class Mode { Walk, Head, Look, Height }

    var mode by mutableStateOf(Mode.Walk)
    var left by mutableStateOf(Offset.Zero)
    var right by mutableStateOf(Offset.Zero)
    var camOn by mutableStateOf(true)
    var tray by mutableStateOf(false)
    var rolling by mutableStateOf(false)
    var quackDown by mutableStateOf(false)
    var wheeeDown by mutableStateOf(false)
    var startHeld by mutableFloatStateOf(0f)
    var powerHeld by mutableFloatStateOf(0f)
    var toast by mutableStateOf<Pair<String, Boolean>?>(null)
    var output by mutableStateOf<DriveOutput?>(null)

    private var loop: Job? = null
    private var toastJob: Job? = null
    private var rollJob: Job? = null
    private var wasIdle = true

    private val session get() = model.session
    val power get() = session.power
    /** 不在站立（锁住的坐姿或未回零位）：技能、移动都要先站起。 */
    val seated get() = session.down
    val off get() = session.power == Power.Off

    val stateLabel: Pair<String, Color>
        get() = when {
            off -> L("relaxed") to Color.White.copy(alpha = 0.5f)
            seated -> L("seated") to Palette.purple
            power == Power.Stiff -> L("standing") to Palette.purple
            else -> {
                val moving = output?.calls?.any { it is DuckCall.RobotMove && (it.vx != 0.0 || it.vy != 0.0 || it.vyaw != 0.0) } == true
                (if (moving) L("walking") else L("readyState")) to Palette.cyan
            }
        }

    // ── 摇杆 → teleop（20 ms 一次，松手只发一次零） ──

    fun startLoop() {
        loop?.cancel()
        loop = scope.launch { while (isActive) { pump(); delay(20) } }
    }

    fun stopLoop() {
        loop?.cancel()
        if (session.power == Power.Walking) scope.launch { session.intent(DuckCall.RobotMove(0.0, 0.0, 0.0)) }
    }

    private fun pump() {
        val m = when (mode) { Mode.Walk -> StickMode.WALK; Mode.Head -> StickMode.HEAD; Mode.Look -> StickMode.WALK_LOOK; Mode.Height -> StickMode.HEIGHT }
        val out = mapSticks(m, Stick(left.x.toDouble(), left.y.toDouble()), Stick(right.x.toDouble(), right.y.toDouble()), session.isRoller)
        output = out
        val idle = left == Offset.Zero && right == Offset.Zero
        if (idle && wasIdle) return
        wasIdle = idle
        if (off) return
        for (c in out.calls) {
            if (c is DuckCall.RobotMove && (session.power != Power.Walking || seated)) continue
            scope.launch { runCatching { session.call(c) } }
        }
    }

    /** 读数：未启动时为 0（设计稿行为）。 */
    val readout: List<String>
        get() {
            val out = output ?: return listOf("0.00", "m/s", "0.00", "rad/s")
            fun first(s: String) = s.substringBefore(' ')
            return when (mode) {
                Mode.Walk -> listOf(if (off) "0.00" else first(out.readoutPrimary), "m/s",
                    if (off) "0.00" else first(out.readoutSecondary).removePrefix("-"), "rad/s")
                Mode.Look -> listOf(if (off) "0.00" else first(out.readoutPrimary), "m/s", if (off) "0°" else out.readoutSecondary, L("uTurn"))
                Mode.Head -> listOf(if (off) "0°" else out.readoutPrimary, L("uTurn"), if (off) "0°" else out.readoutSecondary, L("uNod"))
                Mode.Height -> listOf(if (off) "0%" else out.readoutPrimary, L("uHeight"), if (off) "0°" else out.readoutSecondary, L("uLean"))
            }
        }

    val reticle: Offset get() = output?.takeIf { !off }?.let { Offset(it.reticleX.toFloat(), it.reticleY.toFloat()) } ?: Offset.Zero

    fun say(text: String, warn: Boolean = false) {
        toast = text to warn
        toastJob?.cancel()
        toastJob = scope.launch { delay(1600); toast = null }
    }

    // ── 动作 ──

    data class Action(val id: String, val name: String, val icon: Icon, val on: Boolean = false, val sound: Boolean = false,
                      val down: () -> Unit, val up: () -> Unit = {})

    private fun needOn(f: () -> Unit): () -> Unit = { if (off) say(L("needStart"), true) else f() }

    /** 技能：坐着时提示先站起、未启动时提示先启动（D-6）。 */
    fun skill(name: String, label: String) {
        tray = false
        if (seated) return say(L("needStand"), true)
        if (off) return say(L("needStart"), true)
        say(label)
        scope.launch { session.intent(DuckCall.RobotDo(name))?.let { say(it, true) } }
    }

    private fun sound(q: Quack, hold: Boolean? = null) = scope.launch { session.intent(DuckCall.RobotSound(q, hold)) }

    val actions: List<Action>
        get() {
            val all = mapOf(
                "sit" to Action("sit", if (seated) L("stand") else L("sit"), if (seated) Icon.STAND else Icon.SIT, down = needOn {
                    // 站起：锁住的坐姿发 sit_toggle，未回零位发 init；坐下：sit_toggle。
                    session.postureCall(!seated)?.let { call ->
                        scope.launch { session.intent(call)?.let { say(it, true) } ?: session.applied(call) }
                    }
                }),
                "pick" to Action("pick", L("pickUp"), Icon.PICK, down = { skill("ground_pick", L("pickUp")) }),
                "kickL" to Action("kickL", L("kickL"), Icon.KICK_L, down = { skill("kick_left", L("kickL")) }),
                "kickR" to Action("kickR", L("kickR"), Icon.KICK_R, down = { skill("kick_right", L("kickR")) }),
                "roll" to Action("roll", L("roulade"), Icon.ROULADE, on = rolling, down = {
                    if (seated || power != Power.Walking) skill("roulade", L("roulade")) else {
                        rolling = true
                        say(L("rouladeT"))
                        // 按住连续翻：技能 chain，按住期间持续请求。
                        rollJob = scope.launch { while (isActive && rolling) { session.intent(DuckCall.RobotDo("roulade")); delay(400) } }
                    }
                }, up = { rolling = false; rollJob?.cancel() }),
                "center" to Action("center", L("center"), Icon.CENTER, down = needOn {
                    say(L("centered")); scope.launch { runCatching { session.call(DuckCall.RobotHead(0.0, 0.0, 0.0, 0.0)) } }
                }),
                "level" to Action("level", L("level"), Icon.RESET, down = needOn { say(L("leveled")) }),
                "quack" to Action("quack", L("quack"), Icon.QUACK, on = quackDown, sound = true,
                    down = { quackDown = true; say(L("quackT")); sound(Quack.GREET) }, up = { quackDown = false }),
                "wheee" to Action("wheee", L("wheee"), Icon.WHEEE, on = wheeeDown, sound = true,
                    down = { wheeeDown = true; say(L("wheeeT")); sound(Quack.WHEEE, true) }, up = { wheeeDown = false; sound(Quack.WHEEE, false) }),
                "emo" to Action("emo", L("emotion"), Icon.EMOTION, on = tray, down = { tray = !tray }),
                "more" to Action("more", L("more"), Icon.MORE, on = tray, sound = true, down = { tray = !tray }),
            )
            val set = when (mode) {
                Mode.Walk -> if (session.isRoller) listOf("pick", "kickL", "kickR", "roll", "more") else listOf("sit", "pick", "kickL", "kickR", "roll", "more")
                Mode.Head -> listOf("center", "quack", "wheee", "emo")
                Mode.Look -> listOf("sit", "center", "quack", "emo")
                Mode.Height -> listOf("level", "sit", "quack", "wheee")
            }
            return set.mapNotNull { all[it] }
        }

    fun dimmed(a: Action) = (off && !a.sound) || (seated && a.id != "sit" && !a.sound)

    data class Emotion(val id: String, val name: String, val icon: Icon, val color: Color, val go: () -> Unit)

    val emotions: List<Emotion>
        get() = buildList {
            if (mode == Mode.Walk) add(Emotion("quack", L("quack"), Icon.QUACK, Palette.text) { tray = false; say(L("quackT")); sound(Quack.GREET) })
            add(Emotion("yes", L("yes"), Icon.CHECK, Palette.cyan) { gesture(true) })
            add(Emotion("no", L("no"), Icon.X, Palette.pink) { gesture(false) })
            add(Emotion("excited", L("excited"), Icon.EXCITED, Palette.orange) {
                tray = false
                if (off) say(L("needStart"), true) else {
                    say(L("excited")); sound(Quack.WHEEE, true); scope.launch { delay(1500); sound(Quack.WHEEE, false) }
                }
            })
            add(Emotion("custom", L("custom"), Icon.PLUS, Palette.purple) {
                tray = false
                val x = session.bindings.firstOrNull { it.button == "x" }?.skill.orEmpty()
                if (x.isEmpty()) say(L("assign"), true) else skill(x, x)
            })
        }

    /** 点头 / 摇头：robot.head 预设轨迹（点头 = 俯仰 ±15° 两次，摇头 = 转向 ±25° 两次）。 */
    private fun gesture(nod: Boolean) {
        tray = false
        if (seated) return say(L("needStand"), true)
        if (off) return say(L("needStart"), true)
        say(if (nod) L("yes") else L("no"))
        scope.launch {
            val a = (if (nod) 15.0 else 25.0) * PI / 180
            for (v in listOf(a, -a, a, -a, 0.0)) {
                val c = if (nod) DuckCall.RobotHead(0.0, v, 0.0, 0.0) else DuckCall.RobotHead(0.0, 0.0, v, 0.0)
                repeat(6) { runCatching { session.call(c) }; delay(50) }
            }
        }
    }

    // ── 启动键 / 电源键 ──

    val startIcon get() = if (off) Icon.BOLT else if (power == Power.Stiff) Icon.PLAY else Icon.PAUSE
    val startText get() = if (off) L("start") else if (power == Power.Stiff) L("go") else L("stop")

    fun startReleased(held: Float) = scope.launch {
        if (held >= 1.5f) {
            // init 只把鸭子送到座位、策略不驱动：保持"关"，下一次 Start 才发 enable 起身。
            session.intent(DuckCall.RobotInit)?.let { say(it, true); return@launch }
            session.applied(DuckCall.RobotInit)
            say(L("home"))
            return@launch
        }
        when (session.power) {
            Power.Off -> session.intent(DuckCall.RobotEnable(true))?.let { say(it, true) } ?: session.applied(DuckCall.RobotEnable(true))
            Power.Stiff -> session.power = Power.Walking
            Power.Walking -> { session.intent(DuckCall.RobotStop); session.power = Power.Stiff }
        }
    }

    fun powerReleased(held: Float) {
        when {
            held >= 4f -> { say(L("poweringOff"), true); scope.launch { session.intent(DuckCall.RobotShutdown); session.applied(DuckCall.RobotShutdown) } }
            held >= 2f -> { say(L("resting"), true); scope.launch { session.intent(DuckCall.RobotRest); session.applied(DuckCall.RobotRest) } }
            else -> say(L("holdRest"))
        }
    }

    fun toggleCam() {
        camOn = !camOn
        session.media.setVideo(camOn)
        say(if (camOn) L("camOnT") else L("camOffT"))
    }
}
