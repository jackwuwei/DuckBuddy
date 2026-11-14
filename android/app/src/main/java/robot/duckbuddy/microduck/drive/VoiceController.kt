package robot.duckbuddy.microduck.drive

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.*
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.state.AppModel
import robot.duckbuddy.microduck.state.Power
import kotlinx.coroutines.*
import okhttp3.*
import uniffi.duck_core.*
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/**
 * 语音控制（PRD 5.4，技术方案 3.3）。手势：按住说话 → 上划到"发送"松开才执行；上划到"取消"或原地松开不执行。
 * 豆包事件的攒住 / 放行 / 规划由 duck-core 的 `VoiceTurn` 负责（与 iOS 共用）；这里做 WebSocket、麦克风、扬声器和执行。
 */
class VoiceController(private val ctx: Context, private val model: AppModel, private val scope: CoroutineScope,
                      private val say: (String, Boolean) -> Unit) {
    enum class Phase { Idle, Listening, Thinking }
    enum class Zone { Cancel, Send }

    var phase by mutableStateOf(Phase.Idle)
    var zone by mutableStateOf<Zone?>(null)
    var heard by mutableStateOf("")
    var level by mutableFloatStateOf(0f)
    var showConsent by mutableStateOf(false)

    private var pressedAt = 0L
    private val engine = DoubaoEngine(ctx, scope) { handle(it) }
    private var demoJob: Job? = null
    private var demoIndex = 0

    val hasKey get() = model.doubaoKey != null && !model.doubaoInvalid
    val online: Boolean
        get() {
            val cm = ctx.getSystemService(ConnectivityManager::class.java)
            return cm?.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        }
    val locked get() = !hasKey || !online

    fun press() {
        if (phase != Phase.Idle) return
        engine.stopPlayback() // 按住时立即停播
        if (!hasKey) return say(L("needKey"), true)
        if (!online) return say(L("needNet"), true)
        if (!model.voiceConsent) { showConsent = true; return }
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED && !model.demo) {
            showConsent = true; return
        }
        pressedAt = System.currentTimeMillis()
        heard = ""; zone = null
        phase = Phase.Listening
        if (model.demo) { startDemo(); return }
        val s = model.session
        engine.begin(model.doubaoKey!!.credential, s.robotName, s.skills.filter { !it.disabled }.map { it.name }, context())
    }

    /** 相对按下点的位移（dp）。上划超过 50 才进入目标区。 */
    fun move(dx: Float, dy: Float) {
        if (phase != Phase.Listening) return
        val z = if (dy < -50) (if (dx < 0) Zone.Cancel else Zone.Send) else null
        if (z != zone) zone = z
    }

    fun release(interrupted: Boolean = false) {
        if (phase != Phase.Listening) return
        val z = if (interrupted) Zone.Cancel else zone
        if (z != Zone.Cancel && System.currentTimeMillis() - pressedAt < 350) {
            reset(); engine.cancelTurn(); demoJob?.cancel(); return say(L("holdTalk"), false)
        }
        if (z != Zone.Send) {
            reset(); engine.cancelTurn(); demoJob?.cancel()
            return say(if (z == Zone.Cancel) L("cancelled") else L("notSent"), z != Zone.Cancel)
        }
        phase = Phase.Thinking
        if (model.demo) finishDemo() else engine.send(model.speakReplies)
    }

    private fun reset() { phase = Phase.Idle; zone = null; heard = ""; level = 0f }

    private fun context(): RobotContext {
        val s = model.session
        return RobotContext(s.power != Power.Off, s.seated, s.homed, s.state?.posture?.posture == Posture.LYING, s.isRoller,
            s.media.isOpen, s.busy, s.skills.filter { !it.disabled }.map { it.name })
    }

    private fun handle(e: DoubaoEngine.Event) {
        when (e) {
            is DoubaoEngine.Event.Level -> level = e.v
            is DoubaoEngine.Event.Transcript -> heard = e.text
            DoubaoEngine.Event.Plan -> engine.plan(context())?.let { steps -> scope.launch { execute(steps) } }
            DoubaoEngine.Event.Nothing -> {
                reset()
                scope.launch { model.session.intent(DuckCall.RobotSound(Quack.INQUIRE, null)) }
                say(L("notGot"), true)
            }
            DoubaoEngine.Event.AuthFailed -> { model.doubaoInvalid = true; reset(); say(L("keyInvalid"), true) }
            is DoubaoEngine.Event.Failed -> { reset(); say(e.message, true) }
        }
    }

    /** 按顺序执行；移动以 20 Hz 发 robot.move，到时发零速（限时限速已由核心强制）。 */
    private suspend fun execute(steps: List<VoiceStep>) {
        val s = model.session
        val results = mutableListOf<Pair<String, String>>()
        val summary = "“$heard” → "
        reset()
        for (step in steps) when (step) {
            is VoiceStep.Refuse -> {
                s.intent(DuckCall.RobotSound(Quack.ALARM, null)); say(summary + step.reason, true); results += step.callId to step.reason
            }
            is VoiceStep.Stop -> {
                runCatching { s.call(DuckCall.RobotMove(0.0, 0.0, 0.0)) }; s.intent(DuckCall.RobotStop); results += step.callId to "已停下"
            }
            is VoiceStep.Act -> {
                step.quack?.let { q ->
                    scope.launch {
                        repeat(maxOf(1, step.quackTimes.toInt())) { i ->
                            if (i > 0) delay(400)
                            s.intent(DuckCall.RobotSound(q, if (q == Quack.WHEEE) true else null))
                        }
                        if (q == Quack.WHEEE) { delay(1500); s.intent(DuckCall.RobotSound(Quack.WHEEE, false)) }
                    }
                }
                var outcome = "完成"
                val call = step.call
                val secs = step.moveSeconds
                if (call != null && secs != null) {
                    if (s.power == Power.Stiff) s.power = Power.Walking
                    val end = System.currentTimeMillis() + (secs * 1000).toLong()
                    while (System.currentTimeMillis() < end) { runCatching { s.call(call) }; delay(50) }
                    runCatching { s.call(DuckCall.RobotMove(0.0, 0.0, 0.0)) }
                } else if (call != null) {
                    val r = s.intent(call)
                    if (r != null) outcome = r else s.applied(call)
                }
                say(summary + step.note, false)
                results += step.callId to outcome
            }
        }
        engine.report(results)
    }

    private val demoPhrases = listOf("站起来" to "stand", "往前走" to "walk", "嘎嘎叫" to "quack", "点个头" to "yes",
        "停下" to "stop", "今天吃什么" to "?", "坐下" to "sit")

    private fun startDemo() {
        val phrase = demoPhrases[demoIndex % demoPhrases.size].first
        val t0 = System.currentTimeMillis()
        demoJob = scope.launch {
            while (isActive && phase == Phase.Listening) {
                val k = ((System.currentTimeMillis() - t0 - 300) / 1400f).coerceIn(0f, 1f)
                heard = phrase.take(kotlin.math.ceil(phrase.length * k).toInt())
                level = (2..10).random() / 10f
                delay(80)
            }
        }
    }

    private fun finishDemo() {
        demoJob?.cancel()
        val (phrase, id) = demoPhrases[demoIndex++ % demoPhrases.size]
        heard = phrase
        scope.launch {
            delay(550)
            val q = "“$phrase” → "
            val s = model.session
            reset()
            when (id) {
                "stand", "sit", "walk", "yes" -> {
                    if (s.power == Power.Off) return@launch say(q + L("needStart"), true)
                    if (id == "walk" && s.down) return@launch say(q + L("needStand"), true)
                    if (id == "stand" || id == "sit") s.postureCall(id == "sit")?.let { s.applied(it) }
                    if (id == "walk") s.power = Power.Walking
                    say(q + L(mapOf("stand" to "stand", "sit" to "sit", "walk" to "sMove", "yes" to "yes")[id]!!), false)
                }
                "stop" -> { if (s.power == Power.Walking) s.power = Power.Stiff; say(q + L("stop"), false) }
                "quack" -> say(q + L("quackT"), false)
                else -> say(q + L("notGot"), true)
            }
        }
    }

    fun close() = engine.close()
}

/** 豆包实时语音（全双工）：OkHttp WebSocket + AudioRecord 16 kHz + AudioTrack 24 kHz。 */
class DoubaoEngine(private val ctx: Context, private val scope: CoroutineScope, private val onEvent: (Event) -> Unit) {
    sealed class Event {
        data class Level(val v: Float) : Event()
        data class Transcript(val text: String) : Event()
        object Plan : Event()
        object Nothing : Event()
        object AuthFailed : Event()
        data class Failed(val message: String) : Event()
    }

    private val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()
    private val turn = VoiceTurn()
    private var socket: WebSocket? = null
    @Volatile private var ready = false
    private val buffered = mutableListOf<String>()
    private var recordJob: Job? = null
    /** 松手后的静音上行（见 [keepAlive]）。 */
    private var silenceJob: Job? = null
    private var track: AudioTrack? = null
    private var played = 0.0
    @Volatile private var gotDone = false
    private var speak = true

    private fun post(e: Event) = scope.launch(Dispatchers.Main) { onEvent(e) }

    fun begin(credential: DoubaoCredential, duckName: String, skills: List<String>, context: RobotContext) {
        turn.begin()
        gotDone = false
        stopKeepAlive()
        if (socket == null) connect(credential, duckName, skills)
        sendText(turn.contextUpdate(context))
        startMic()
    }

    private fun connect(credential: DoubaoCredential, duckName: String, skills: List<String>) {
        val req = Request.Builder().url(doubaoUrl()).apply {
            doubaoHeaders(credential, UUID.randomUUID().toString()).forEach { header(it.name, it.value) }
        }.build()
        ready = false
        socket = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                ws.send(turn.sessionCreate(UUID.randomUUID().toString(), duckName, skills))
            }

            override fun onMessage(ws: WebSocket, text: String) {
                if (text.contains("\"session.created\"")) {
                    synchronized(buffered) { ready = true; buffered.forEach { ws.send(it) }; buffered.clear() }
                }
                for (e in turn.onServerEvent(text)) when (e) {
                    is VoiceEvent.Transcript -> post(Event.Transcript(e.text))
                    is VoiceEvent.Speech -> if (speak) play(e.pcm)
                    is VoiceEvent.ResponseDone -> gotDone = true
                    is VoiceEvent.AuthFailed -> post(Event.AuthFailed)
                    is VoiceEvent.Error -> post(Event.Failed(e.message))
                    is VoiceEvent.Caption -> {}
                }
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                // 取消后会重连：旧连接迟到的回调不能动新连接。
                if (socket !== ws) return
                socket = null; ready = false; stopKeepAlive()
                if (response?.code == 401 || response?.code == 403) post(Event.AuthFailed) else post(Event.Failed(L("errNet")))
            }

            override fun onClosed(ws: WebSocket, code: Int, reason: String) { if (socket === ws) { socket = null; ready = false } }
        })
    }

    private fun sendText(s: String) = synchronized(buffered) { if (ready) socket?.send(s) else buffered.add(s) }

    /** 麦克风：16 kHz 单声道 s16le，512 采样（32 ms）一包。 */
    @SuppressLint("MissingPermission")
    private fun startMic() {
        recordJob?.cancel()
        recordJob = scope.launch(Dispatchers.IO) {
            val min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 4096))
            val buf = ShortArray(512)
            rec.startRecording()
            try {
                while (isActive) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n <= 0) continue
                    var sum = 0.0
                    val bytes = ByteArray(n * 2)
                    for (i in 0 until n) {
                        val v = buf[i].toInt()
                        sum += (v / 32768.0) * (v / 32768.0)
                        bytes[2 * i] = (v and 0xFF).toByte(); bytes[2 * i + 1] = (v shr 8).toByte()
                    }
                    post(Event.Level((sqrt(sum / n) * 6).toFloat().coerceAtMost(1f)))
                    sendText(turn.audioAppend(bytes))
                }
            } finally {
                rec.stop(); rec.release()
            }
        }
    }

    private fun stopMic() { recordJob?.cancel(); recordJob = null }

    /**
     * 松手在"发送"：关麦、强制判停、放出缓存的开始语，等到工具调用或 response.done（最多 4 s）后规划执行。
     * 带工具调用的回复要等结果回传后才有 response.done，所以收到调用就规划，不干等 4 s。
     */
    fun send(speak: Boolean) {
        this.speak = speak
        stopMic()
        sendText(turn.commit())
        keepAlive()
        turn.release(true).forEach { if (it is VoiceEvent.Speech && speak) play(it.pcm) }
        scope.launch {
            val t0 = System.currentTimeMillis()
            while (!gotDone && !turn.hasCalls() && System.currentTimeMillis() - t0 < 4000) delay(50)
            onEvent(if (turn.hasCalls()) Event.Plan else Event.Nothing)
        }
    }

    fun plan(ctx: RobotContext): List<VoiceStep>? = turn.plan(ctx)

    /** 结果统一回传后只 commit 一次，模型据此说一句结果语。 */
    fun report(results: List<Pair<String, String>>) {
        results.forEach { (id, text) -> sendText(turn.toolResult(id, text)) }
        if (results.isNotEmpty()) { sendText(turn.commit()); keepAlive() }
    }

    /**
     * 取消：丢弃这一轮并关掉会话，下次按住时重连（约 0.2 s）。
     * 豆包没有清空输入缓冲的事件（`input_audio_buffer.clear` 会报错并断开），`response.cancel` 又会卡死会话；
     * 不关会话的话，取消掉的那句话会和下一句拼在一起被执行（实测"停下" + 下一句）。
     */
    fun cancelTurn() {
        stopMic()
        stopKeepAlive()
        turn.release(false)
        synchronized(buffered) {
            if (ready) socket?.send(turn.sessionClose())
            socket?.close(1000, null)
            socket = null; ready = false; buffered.clear()
        }
    }

    /** 关麦后用静音维持上行 [seconds] 秒：服务端只有继续收到音频才会结束识别、说出结果语（实测）。 */
    private fun keepAlive(seconds: Double = 10.0) {
        silenceJob?.cancel()
        silenceJob = scope.launch(Dispatchers.IO) {
            val end = System.currentTimeMillis() + (seconds * 1000).toLong()
            while (isActive && System.currentTimeMillis() < end) { sendText(turn.silence()); delay(32) }
        }
    }

    private fun stopKeepAlive() { silenceJob?.cancel(); silenceJob = null }

    /** 播报：24 kHz s16le，走媒体音量，单句超过 4 s 截断。 */
    private fun play(pcm: ByteArray) {
        if (played >= 4.0) return
        val t = track ?: AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(24000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STREAM).build().also { track = it; it.play() }
        played += pcm.size / 2 / 24000.0
        scope.launch(Dispatchers.IO) { t.write(pcm, 0, pcm.size) }
    }

    fun stopPlayback() {
        track?.run { runCatching { pause(); flush(); stop(); release() } }
        track = null
        played = 0.0
    }

    fun close() {
        stopKeepAlive()
        if (ready) socket?.send(turn.sessionClose())
        socket?.close(1000, null)
        socket = null
        stopMic()
        stopPlayback()
    }
}

/** 一次性连接豆包验证密钥（超时 10 s）。 */
object DoubaoTester {
    enum class Result { Ok, BadKey, NotEnabled, Network }

    suspend fun test(credential: DoubaoCredential): Result = withContext(Dispatchers.IO) {
        val done = CompletableDeferred<Result>()
        val turn = VoiceTurn()
        val req = Request.Builder().url(doubaoUrl()).apply {
            doubaoHeaders(credential, UUID.randomUUID().toString()).forEach { header(it.name, it.value) }
        }.build()
        val ws = OkHttpClient().newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) { ws.send(turn.sessionCreate(UUID.randomUUID().toString(), "duck", emptyList())) }
            override fun onMessage(ws: WebSocket, text: String) {
                if (text.contains("\"session.created\"")) { ws.send(turn.sessionClose()); done.complete(Result.Ok) }
                else if (text.contains("\"error\"")) done.complete(
                    if (text.lowercase().contains("auth") || text.contains("401") || text.contains("403")) Result.BadKey else Result.NotEnabled)
            }
            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                done.complete(if (response?.code == 401 || response?.code == 403) Result.BadKey else Result.Network)
            }
        })
        val r = withTimeoutOrNull(10_000) { done.await() } ?: Result.Network
        ws.close(1000, null)
        r
    }
}
