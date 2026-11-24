package robot.duckbuddy.microduck.drive

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.design.Icon
import robot.duckbuddy.microduck.design.Palette
import robot.duckbuddy.microduck.state.AppModel
import robot.duckbuddy.microduck.state.DebugArgs
import robot.duckbuddy.microduck.state.Gallery
import robot.duckbuddy.microduck.state.VideoCapture
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewModelScope
import robot.duckbuddy.microduck.state.LinkState
import robot.duckbuddy.microduck.state.Power
import kotlinx.coroutines.*
import uniffi.duck_core.*
import kotlin.math.PI

/**
 * 驾驶页逻辑（与 iOS `DriveController.swift` 一一对应）：模式、摇杆发送、动作前置条件、
 * 启动键（短按启动 / 出发 / 停止，长按 1.5 s 回初始姿态）、电源键（长按 2 s 休息、4 s 关机）。
 */
class DriveController(private val model: AppModel, private val scope: CoroutineScope) {
    enum class Mode { Walk, Head }

    var mode by mutableStateOf(Mode.Walk)
    var left by mutableStateOf(Offset.Zero)
    var right by mutableStateOf(Offset.Zero)
    var camOn by mutableStateOf(true)
    var tray by mutableStateOf(false)
    /** 竖屏：动作列可以收起，让出画面。 */
    var actionsOpen by mutableStateOf(true)
    /** 用户手动切换过的画面铺满 / 完整显示（键：是否竖屏）；没切换过按窗口和画面比例决定。 */
    val videoFill = mutableStateMapOf<Boolean, Boolean>()
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
    private var gamesJob: Job? = null
    /** 推摇杆接管自由活动时只关一次（等机器人确认关掉之前不重复发）。 */
    private var takingOver = false
    /** 上一个情绪动作预计播完的时刻（毫秒）：机器人播放中会丢掉新的请求，这里先提示。 */
    private var emotingUntil = 0L
    private var wasIdle = true
    /** 上一拍是否发了非零速度（core 用它做站立 / 行走阈值的迟滞）。 */
    private var wasMoving = false

    private val session get() = model.session
    val power get() = session.power
    /** 不在站立（锁住的坐姿或未回零位）：技能、移动都要先站起。 */
    val seated get() = session.down
    val off get() = session.power == Power.Off

    val stateLabel: Pair<String, Color>
        get() = when {
            playing != null -> L("game_${GameStyle.key(playing!!)}On") to Palette.orange
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
        debugStick()
        gamesJob?.cancel()
        gamesJob = scope.launch { while (isActive) { session.refreshGames(); delay(3000) } }
        loop?.cancel()
        loop = scope.launch { while (isActive) { pump(); delay(20) } }
    }

    /** 调试：见 [DebugArgs.stick]。走真实的摇杆 → teleop 路径，只是没有手指。 */
    private fun debugStick() {
        if (DebugArgs.tray) { DebugArgs.tray = false; tray = true }
        // `--es capture photo|record:<秒>`：等出帧后拍一张 / 录一段，走真实的存相册路径。
        DebugArgs.capture?.split(":")?.let { c ->
            DebugArgs.capture = null
            scope.launch {
                delay(1000)
                repeat(200) { if (!session.media.videoLive) delay(100) }
                delay(1000)
                if (c[0] == "photo") return@launch takePhoto()
                toggleRecord()
                delay(((c.getOrNull(1)?.toDoubleOrNull() ?: 5.0) * 1000).toLong())
                stopRecording()
            }
        }
        val spec = DebugArgs.stick?.split(":") ?: return
        DebugArgs.stick = null
        if (spec.size != 3) return
        val v = spec[1].split(",").mapNotNull { it.toFloatOrNull() }
        val secs = spec[2].toDoubleOrNull() ?: return
        if (v.size != 4) return
        mode = mapOf("walk" to Mode.Walk, "head" to Mode.Head)[spec[0]] ?: Mode.Walk
        if (mode == Mode.Walk) session.power = Power.Walking
        scope.launch {
            delay(6000) // 等视频通道连上
            left = Offset(v[0], v[1]); right = Offset(v[2], v[3])
            delay((secs * 1000).toLong())
            left = Offset.Zero; right = Offset.Zero
        }
    }

    fun stopLoop() {
        gamesJob?.cancel()
        loop?.cancel()
        if (session.power == Power.Walking) scope.launch { session.intent(DuckCall.RobotMove(0.0, 0.0, 0.0)) }
    }

    private fun pump() {
        val m = when (mode) { Mode.Walk -> StickMode.WALK; Mode.Head -> StickMode.HEAD }
        val out = mapSticks(m, Stick(left.x.toDouble(), left.y.toDouble()), Stick(right.x.toDouble(), right.y.toDouble()), session.isRoller, wasMoving)
        output = out
        wasMoving = out.moving
        val idle = left == Offset.Zero && right == Offset.Zero
        if (!idle) takeOverFromAutonomous()
        if (idle && wasIdle) return
        wasIdle = idle
        if (off) return
        for (c in out.calls) {
            if (c is DuckCall.RobotMove && (session.power != Power.Walking || seated)) continue
            scope.launch { runCatching { session.call(c) } }
        }
    }

    /**
     * 自由活动（autod）只给实体手柄让路，不认 App 的摇杆：两边的指令会互相覆盖。
     * 所以一推摇杆就关掉自由活动，由用户接管。追激光和踢球不用关：机器人自己让推动的摇杆优先。
     */
    private fun takeOverFromAutonomous() {
        if (!session.games.autonomous || takingOver) return
        takingOver = true
        say(L("autonomousTakeover"))
        scope.launch {
            session.setGame(Game.AUTONOMOUS, false)?.let { say(it, true) }
            takingOver = false
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
                Mode.Head -> listOf(if (off) "0°" else out.readoutPrimary, L("uTurn"), if (off) "0°" else out.readoutSecondary, L("uNod"))
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
            }
            return set.mapNotNull { all[it] }
        }

    fun dimmed(a: Action) = (off && !a.sound) || (seated && a.id != "sit" && !a.sound)

    data class Emotion(val id: String, val name: String, val icon: Icon, val color: Color, val on: Boolean = false, val go: () -> Unit)

    /** 托盘里的全部按钮：行走模式下先是三个玩法开关（开着的高亮），再是叫声和情绪。 */
    val trayItems: List<Emotion>
        get() = gameTiles.map { g -> Emotion("game-${GameStyle.key(g.game)}", g.name, g.icon, Palette.orange, g.on) { toggleGame(g.game) } } + emotions

    val emotions: List<Emotion>
        get() = buildList {
            if (mode == Mode.Walk) add(Emotion("quack", L("quack"), Icon.QUACK, Palette.text) { tray = false; say(L("quackT")); sound(Quack.GREET) })
            val shipped = session.emotions
            shipped.forEach { e -> add(Emotion(e.name, EmotionStyle.label(e.name), EmotionStyle.icon(e.name), EmotionStyle.color(e.name)) { emote(e) }) }
            // API 49 之前的机器人没有自带情绪：点头 / 摇头用 robot.head 轨迹，兴奋用 wheee。
            if (shipped.isEmpty()) {
                add(Emotion("yes", L("yes"), Icon.CHECK, Palette.cyan) { gesture(true) })
                add(Emotion("no", L("no"), Icon.X, Palette.pink) { gesture(false) })
                add(Emotion("excited", L("excited"), Icon.EXCITED, Palette.orange) {
                    tray = false
                    if (off) say(L("needStart"), true) else {
                        say(L("excited")); sound(Quack.WHEEE, true); scope.launch { delay(1500); sound(Quack.WHEEE, false) }
                    }
                })
            }
            add(Emotion("custom", L("custom"), Icon.PLUS, Palette.purple) {
                tray = false
                val x = session.bindings.firstOrNull { it.button == "x" }?.skill.orEmpty()
                if (x.isEmpty()) say(L("assign"), true) else skill(x, if (isShippedEmotion(x)) EmotionStyle.label(x) else x)
            })
        }

    // ── 玩法（追激光、踢球、自由活动） ──

    data class GameTile(val game: Game, val name: String, val icon: Icon, val on: Boolean)

    /** 正在玩的玩法（机器人报告的），没有为 null。 */
    val playing: Game? get() = session.availableGames.firstOrNull { gameIsOn(session.games, it) }

    /** 托盘第一行的玩法开关，只在行走模式下出现。 */
    val gameTiles: List<GameTile>
        get() = if (mode != Mode.Walk || session.isRoller) emptyList()
                else session.availableGames.map { GameTile(it, L("game_${GameStyle.key(it)}"), GameStyle.icon(it), gameIsOn(session.games, it)) }

    /** 开 / 关一个玩法。激光和踢球要先启动、站着（它们靠行走策略走路）；自由活动由鸭子自己启动。 */
    fun toggleGame(game: Game) {
        val on = !gameIsOn(session.games, game)
        val name = L("game_${GameStyle.key(game)}")
        if (on && game != Game.AUTONOMOUS) {
            if (off) return say(L("needStart"), true)
            if (seated) return say(L("needStand"), true)
        }
        tray = false
        say(if (on) (if (game == Game.AUTONOMOUS) L("autonomousStarted") else L("gameStarted", name)) else L("gameStopped", name))
        scope.launch {
            val reason = session.setGame(game, on)
            if (reason != null) say(reason, true)
            else if (on && game != Game.AUTONOMOUS) { delay(2500); say(L("game_${GameStyle.key(game)}Hint")) }
        }
    }

    /** 机器人自带的情绪：`robot.do <名字>`，和技能同样要求站着、已启动；一次只播一个。 */
    private fun emote(e: EmotionInfo) {
        tray = false
        if (seated) return say(L("needStand"), true)
        if (off) return say(L("needStart"), true)
        val now = System.currentTimeMillis()
        if (now < emotingUntil) return say(L("emoBusy"), true)
        val label = EmotionStyle.label(e.name)
        say(if (e.sits) "$label · ${L("emoSits")}" else label)
        emotingUntil = now + (e.seconds * 1000).toLong()
        scope.launch { session.intent(DuckCall.RobotDo(e.name))?.let { emotingUntil = 0L; say(it, true) } }
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
            held >= 4f -> { say(L("poweringOff"), true); scope.launch {
                session.intent(DuckCall.RobotShutdown)?.let { say(it, true); return@launch }
                session.applied(DuckCall.RobotShutdown)
                leaveAfterPowerOff()
            } }
            held >= 2f -> { say(L("resting"), true); scope.launch { session.intent(DuckCall.RobotRest); session.applied(DuckCall.RobotRest) } }
            else -> say(L("holdRest"))
        }
    }

    /**
     * 关机被接受后：留在驾驶页看它坐下，等机器人断电、蓝牙断开（最多 20 s，演示 3 s），
     * 再断开会话回到机器人列表，免得停在一个连不上的控制页里静默重连。
     */
    private suspend fun leaveAfterPowerOff() {
        val limit = if (session.isDemo) 3_000L else 20_000L
        val start = System.currentTimeMillis()
        while (session.linkState == LinkState.Ready && System.currentTimeMillis() - start < limit) delay(250)
        session.disconnect()
        model.say(L("poweredOff"))
        model.path.clear()  // 最后一步：驾驶页离开后它的 scope 会被取消
    }

    fun toggleCam() {
        if (camOn) stopRecording()
        camOn = !camOn
        session.media.setVideo(camOn)
        say(if (camOn) L("camOnT") else L("camOffT"))
    }

    // ── 拍照 / 录像（权限由 DriveScreen 先要好） ──

    /** 正在录像时的开始时刻（毫秒，画面角标显示时长）。 */
    var recordingSince by mutableStateOf<Long?>(null)
    val recording get() = recordingSince != null
    private var saving = false
    /** 存文件要在离开驾驶页后继续，用 AppModel 的作用域。 */
    private val io get() = model.viewModelScope

    fun takePhoto() {
        val capture = session.media.capture
        val app = model.getApplication<android.app.Application>()
        io.launch {
            val msg = try {
                val jpeg = capture.photo()
                withContext(Dispatchers.IO) { Gallery.savePhoto(app, jpeg) }
                L("photoSaved") to false
            } catch (e: VideoCapture.NoFrame) { L("noFrame") to true
            } catch (e: CancellationException) { throw e
            } catch (e: SecurityException) { L("saveDenied") to true
            } catch (e: Throwable) { L("saveFailed") to true }
            say(msg.first, msg.second)
        }
    }

    fun toggleRecord() {
        if (recording) return stopRecording()
        if (!camOn || saving) return
        if (!session.media.videoLive) return say(L("noFrame"), true)
        val app = model.getApplication<android.app.Application>()
        if (!session.media.capture.startRecording()) return say(L("recFailed"), true)
        recordingSince = System.currentTimeMillis()
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) say(L("recNoMic"), true)
    }

    /** 停止录像并存进相册（离开驾驶页、关画面、退到后台时也会调用）。 */
    fun stopRecording() {
        if (!recording) return
        recordingSince = null
        saving = true
        val capture = session.media.capture
        val app = model.getApplication<android.app.Application>()
        io.launch {
            val msg = withContext(Dispatchers.IO) {
                val file = capture.stopRecording() ?: return@withContext L("recFailed") to true
                try { Gallery.saveVideo(app, file); L("videoSaved") to false }
                catch (e: SecurityException) { L("saveDenied") to true }
                catch (e: Throwable) { L("saveFailed") to true }
            }
            saving = false
            say(msg.first, msg.second)
        }
    }
}
