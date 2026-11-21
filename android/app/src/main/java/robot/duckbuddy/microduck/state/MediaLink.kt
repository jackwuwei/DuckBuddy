package robot.duckbuddy.microduck.state

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.webrtc.*
import uniffi.duck_core.LinkEvent
import uniffi.duck_core.SignalAction
import uniffi.duck_core.Signalling
import uniffi.duck_core.decodeVideoInfo
import uniffi.duck_core.videoInfoNotification
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.ImageDecoder
import android.os.Build
import android.widget.ImageView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.design.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import uniffi.duck_core.DuckCall
import uniffi.duck_core.DuckState
import uniffi.duck_core.RpcCodec

/**
 * WebRTC 通道（技术方案 §3.2）：视频轨 + `teleop`（不可靠）+ `control`（可靠）数据通道，经 `duck-gateway` 认证。
 * 连续意图（`robot.move` / `robot.head`）由 duck-core 的 `RpcCodec` 编码后发到 `teleop`。
 */
interface MediaLink {
    var onState: ((DuckState) -> Unit)?
    val isOpen: Boolean
    fun open(ip: String, session: RobotSession)
    fun send(call: DuckCall)
    /** 经 `control` 发一个请求并等回复 JSON；没打开或机器人拒绝时抛 [RobotError]。（调试 `webrtc` 模式下替代蓝牙。） */
    suspend fun request(call: DuckCall, timeoutMs: Long = 10_000): String = throw RobotError(L("linkLost"))
    /** 关闭视频：只把视频收发器设为 inactive，数据通道保留（D-7）。 */
    fun setVideo(on: Boolean)
    fun close()
    @Composable fun VideoView(modifier: Modifier)
    /** 正在出帧（驾驶页据此保持亮屏）。 */
    val videoLive: Boolean
    /** 视频接收码率（kbit/s），还没有统计时为 null。 */
    val videoKbps: Int?
    /** 拍照和录像从这里取帧。 */
    val capture: VideoCapture
}

/**
 * 真机 WebRTC 通道：局域网直连机器人的 `mediad`（`ws://<ip>:8443`，webrtcsink 信令，无认证）。与 iOS `WebRTCMediaLink` 一一对应。
 *
 * 流程与机器人自带网页客户端一致，协议在 duck-core 的 [Signalling] 里：机器人出 offer、App 答；
 * 机器人创建 `control` 数据通道（可靠，JSON-RPC 一行一条），0.17.8 还没有 `teleop`，连续意图也走 `control`。
 * 视频是机器人硬件编码的 H.264，按 `media.video` 的安装角度旋转显示。
 *
 * 机器人端的视频管线偶尔会停在上一帧（实测，重启 mediad 才恢复）：这里每 2 s 看一次解码帧数，
 * 停住就重开会话；连续几次重开都没有画面，就提示需要在机器人上重启 mediad。
 */
class WebRTCMediaLink(ctx: Context, private val scope: CoroutineScope) : MediaLink {
    override var onState: ((DuckState) -> Unit)? = null
    override var isOpen = false; private set
    private val codec = RpcCodec()
    private val app = ctx.applicationContext

    /** 显示状态，供 Compose 观察。 */
    private var live by mutableStateOf(false)
    private var rotate by mutableStateOf(0)
    private var status by mutableStateOf<String?>(null)
    private var kbps by mutableStateOf<Int?>(null)
    override val videoLive get() = live
    override val videoKbps get() = if (live) kbps else null

    private val egl: EglBase by lazy { EglBase.create() }
    private val factory: PeerConnectionFactory by lazy {
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(app).createInitializationOptions())
        PeerConnectionFactory.builder()
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
            .createPeerConnectionFactory()
    }
    private val http = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()

    private var ip: String? = null
    private var socket: WebSocket? = null
    private var sig = Signalling()
    private var pc: PeerConnection? = null
    private var control: DataChannel? = null
    private var teleop: DataChannel? = null
    private var track: VideoTrack? = null
    private var mediaVideoId: ULong? = null
    private val pending = HashMap<ULong, CompletableDeferred<String>>()
    private var watchdog: Job? = null
    private var retry: Job? = null
    private var lastDecoded = -1L
    private var lastBytes = -1L
    private var lastBytesAt = 0L
    private var lastProgress = 0L
    private var sessionStarted = 0L
    private var restarts = 0

    /** 当前的画面视图（Compose 里创建）；帧按安装角度转好再交给它。 */
    private var renderer: SurfaceViewRenderer? = null
    override val capture = VideoCapture(app) { egl.eglBaseContext }
    private val sink = VideoSink { frame ->
        val turned = VideoFrame(frame.buffer, (frame.rotation + rotate) % 360, frame.timestampNs)
        renderer?.onFrame(turned)
        capture.onFrame(turned)
    }

    private fun main(block: () -> Unit) { scope.launch(Dispatchers.Main) { block() } }

    override fun open(ip: String, session: RobotSession) {
        if (this.ip == ip && socket != null) return
        close()
        this.ip = ip
        restarts = 0
        connect()
    }

    private fun connect() {
        val ip = ip ?: return
        sig = Signalling()
        status = L("videoConnecting")
        val req = Request.Builder().url(sig.url(ip)).build()
        socket = http.newWebSocket(req, object : WebSocketListener() {
            override fun onMessage(ws: WebSocket, text: String) = main {
                if (ws !== socket) return@main
                sig.onMessage(text).forEach { handle(it) }
            }
            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) = main {
                if (ws !== socket) return@main
                // 信令断了（机器人重启、离开局域网）：拆掉会话，过一会儿重连。
                teardownPeer()
                socket = null
                status = L("videoNeedsWifi")
                scheduleReconnect(5000)
            }
        })
        startWatchdog()
    }

    private fun sendSignal(text: String?) { if (text != null) socket?.send(text) }

    private fun handle(action: SignalAction) {
        when (action) {
            is SignalAction.Send -> sendSignal(action.text)
            is SignalAction.CreatePeer -> makePeer()
            is SignalAction.RemoteOffer -> {
                val pc = pc ?: return
                pc.setRemoteDescription(object : SdpAdapter() {
                    override fun onSetSuccess() {
                        pc.createAnswer(object : SdpAdapter() {
                            override fun onCreateSuccess(answer: SessionDescription) {
                                pc.setLocalDescription(object : SdpAdapter() {
                                    override fun onSetSuccess() = main { sendSignal(sig.answer(answer.description)) }
                                }, answer)
                            }
                        }, MediaConstraints())
                    }
                }, SessionDescription(SessionDescription.Type.OFFER, action.sdp))
            }
            is SignalAction.RemoteIce -> pc?.addIceCandidate(IceCandidate("", action.sdpMlineIndex.toInt(), action.candidate))
            is SignalAction.NoProducer -> { status = L("videoNoProducer"); scheduleRestart(5000) }
            is SignalAction.Ended -> { teardownPeer(); scheduleRestart(2000) }
        }
    }

    private fun makePeer() {
        teardownPeer()
        val config = PeerConnection.RTCConfiguration(emptyList()).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN }
        val created = factory.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onIceCandidate(c: IceCandidate) = main {
                if (pc != null) sendSignal(sig.ice(c.sdp, c.sdpMLineIndex.toUInt()))
            }
            override fun onDataChannel(dc: DataChannel) = main { didOpen(dc) }
            override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) = main {
                (receiver.track() as? VideoTrack)?.let { t -> track?.removeSink(sink); track = t; t.addSink(sink) }
            }
            override fun onSignalingChange(s: PeerConnection.SignalingState) {}
            override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) {}
            override fun onIceConnectionReceivingChange(b: Boolean) {}
            override fun onIceGatheringChange(s: PeerConnection.IceGatheringState) {}
            override fun onIceCandidatesRemoved(c: Array<out IceCandidate>) {}
            override fun onAddStream(s: MediaStream) {}
            override fun onRemoveStream(s: MediaStream) {}
            override fun onRenegotiationNeeded() {}
        })
        pc = created
        sessionStarted = System.currentTimeMillis()
        lastDecoded = -1
        lastBytes = -1
        kbps = null
        lastProgress = sessionStarted
    }

    private fun teardownPeer() {
        track?.removeSink(sink)
        track = null
        control?.unregisterObserver(); teleop?.unregisterObserver()
        control = null; teleop = null
        pending.values.forEach { it.completeExceptionally(RobotError(L("linkLost"))) }
        pending.clear()
        pc?.dispose()
        pc = null
        isOpen = false
        live = false
    }

    /** 同一条信令连接上重开会话（视频卡住、机器人结束会话）。 */
    private fun scheduleRestart(ms: Long) {
        retry?.cancel()
        retry = scope.launch(Dispatchers.Main) {
            delay(ms)
            if (socket == null) return@launch
            teardownPeer()
            sig.restart().forEach { sendSignal(it) }
        }
    }

    private fun scheduleReconnect(ms: Long) {
        retry?.cancel()
        retry = scope.launch(Dispatchers.Main) {
            delay(ms)
            if (ip != null && socket == null) connect()
        }
    }

    /** 每 2 s 读一次接收统计：解码帧数不再增长就算卡住。 */
    private fun startWatchdog() {
        watchdog?.cancel()
        watchdog = scope.launch(Dispatchers.Main) {
            while (isActive) {
                delay(2000)
                val pc = pc ?: continue
                pc.getStats { report ->
                    val n = report.statsMap.values.firstOrNull { it.type == "inbound-rtp" && it.members["kind"] == "video" }
                    val decoded = (n?.members?.get("framesDecoded") as? Number)?.toLong() ?: 0L
                    val bytes = (n?.members?.get("bytesReceived") as? Number)?.toLong() ?: 0L
                    main { measure(bytes); check(decoded) }
                }
            }
        }
    }

    /** 两次统计之间收到的字节数换算成码率。 */
    private fun measure(bytes: Long) {
        val now = System.currentTimeMillis()
        if (lastBytes >= 0 && bytes >= lastBytes && now - lastBytesAt > 500) kbps = ((bytes - lastBytes) * 8 / (now - lastBytesAt)).toInt()
        lastBytes = bytes
        lastBytesAt = now
    }

    private fun check(decoded: Long) {
        val now = System.currentTimeMillis()
        if (decoded > lastDecoded) {
            lastDecoded = decoded
            lastProgress = now
            if (decoded > 0) { live = true; status = null; restarts = 0 }
            return
        }
        // 刚开会话给 8 s 出第一帧；之后 5 s 没有新帧算卡住。
        val grace = if (decoded == 0L) 8000 else 5000
        if (now - lastProgress <= grace || now - sessionStarted <= grace) return
        live = false
        restarts += 1
        lastProgress = now
        if (restarts > 3) { status = L("videoStuck"); scheduleRestart(30_000) }
        else { status = L("videoStalled"); scheduleRestart(200) }
    }

    // ── 数据通道 ──

    private fun didOpen(dc: DataChannel) {
        if (dc.label() == "teleop") teleop = dc else control = dc
        dc.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previous: Long) {}
            override fun onStateChange() {
                val state = dc.state()
                main {
                    if (state == DataChannel.State.OPEN) opened(dc)
                    else if (state == DataChannel.State.CLOSED && dc === control) isOpen = false
                }
            }
            override fun onMessage(buffer: DataChannel.Buffer) {
                if (buffer.binary) return
                val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
                val text = String(bytes, Charsets.UTF_8)
                main { onControl(text) }
            }
        })
        if (dc.state() == DataChannel.State.OPEN) opened(dc)
    }

    private fun opened(dc: DataChannel) {
        if (dc !== control || isOpen) return
        isOpen = true
        // 状态流（10 Hz）和画面角度都走 control。
        write(codec.encode(DuckCall.RobotSubscribe(10u)).line, dc)
        val mv = codec.encodeMediaVideo()
        mediaVideoId = mv.id
        write(mv.line, dc)
    }

    private fun onControl(text: String) {
        for (line in text.lineSequence().filter { it.isNotBlank() }) {
            when (val e = codec.decode(line)) {
                is LinkEvent.State -> onState?.invoke(e.state)
                is LinkEvent.Notification -> videoInfoNotification(e.method, e.paramsJson)?.let { rotate = it.rotate.toInt() }
                is LinkEvent.Reply -> if (e.id == mediaVideoId) decodeVideoInfo(e.resultJson)?.let { rotate = it.rotate.toInt() }
                    else pending.remove(e.id)?.complete(e.resultJson)
                is LinkEvent.Refused -> pending.remove(e.id)?.completeExceptionally(RobotError(e.message))
                else -> {}
            }
        }
    }

    private fun write(line: String, dc: DataChannel) {
        dc.send(DataChannel.Buffer(ByteBuffer.wrap(line.toByteArray(Charsets.UTF_8)), false))
    }

    override fun send(call: DuckCall) {
        val control = control
        if (!isOpen || control == null) return
        val out = codec.encode(call)
        // 0.17.8 的 mediad 只建 control；有 teleop（不可靠通道）时连续意图走它。
        val t = teleop
        write(out.line, if (out.teleop && t != null && t.state() == DataChannel.State.OPEN) t else control)
    }

    override suspend fun request(call: DuckCall, timeoutMs: Long): String {
        val control = control
        if (!isOpen || control == null) throw RobotError(L("linkLost"))
        val out = codec.encode(call)
        val id = out.id ?: run { write(out.line, control); return "null" }
        val d = CompletableDeferred<String>()
        pending[id] = d
        write(out.line, control)
        return try {
            withTimeout(timeoutMs) { d.await() }
        } catch (e: TimeoutCancellationException) {
            throw RobotError(L("linkLost"))
        } finally {
            pending.remove(id)
        }
    }

    override fun setVideo(on: Boolean) { track?.setEnabled(on) }

    override fun close() {
        retry?.cancel(); watchdog?.cancel()
        sendSignal(sig.end())
        teardownPeer()
        socket?.close(1000, null)
        socket = null
        ip = null
        status = null
    }

    @Composable
    override fun VideoView(modifier: Modifier) {
        Box(modifier) {
            AndroidView(
                factory = { c ->
                    SurfaceViewRenderer(c).apply {
                        init(egl.eglBaseContext, null)
                        setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                        renderer = this
                    }
                },
                onRelease = { v -> if (renderer === v) renderer = null; v.release() },
                modifier = Modifier.fillMaxSize(),
            )
            if (!live) VideoPlaceholder(status ?: L("videoConnecting"), Modifier.fillMaxSize())
        }
    }
}

/** 只关心成功回调的 SdpObserver。 */
private open class SdpAdapter : SdpObserver {
    override fun onCreateSuccess(sdp: SessionDescription) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(error: String?) {}
    override fun onSetFailure(error: String?) {}
}

/** 演示通道：10 Hz 状态流 + 动图画面。 */
class DemoMediaLink(private val robot: DemoRobot, private val scope: CoroutineScope, private val ctx: Context) : MediaLink {
    override var onState: ((DuckState) -> Unit)? = null
    override var isOpen = false; private set
    private var job: Job? = null
    private var frames: Job? = null
    override val capture = VideoCapture(ctx.applicationContext) { null }

    override fun open(ip: String, session: RobotSession) {
        isOpen = true
        job?.cancel()
        job = scope.launch { while (isActive) { onState?.invoke(robot.tick()); delay(100) } }
        // 演示画面也能拍照录像：拍照 / 录像时按 30 fps 把 GIF 的当前帧喂给 capture。
        frames?.cancel()
        frames = scope.launch(Dispatchers.Default) {
            // 演示模式不建 PeerConnection，libwebrtc 的 native 库没人加载；转 I420 要用它。
            runCatching { System.loadLibrary("jingle_peerconnection_so") }
            @Suppress("DEPRECATION")
            val movie = ctx.assets.open("demo_camera.gif").use { android.graphics.Movie.decodeStream(it) } ?: return@launch
            val bmp = android.graphics.Bitmap.createBitmap(movie.width(), movie.height(), android.graphics.Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bmp)
            val t0 = System.currentTimeMillis()
            while (isActive) {
                if (capture.wantsFrames) {
                    @Suppress("DEPRECATION")
                    movie.setTime(((System.currentTimeMillis() - t0) % maxOf(movie.duration(), 1)).toInt())
                    @Suppress("DEPRECATION")
                    movie.draw(canvas, 0f, 0f)
                    val f = VideoCapture.frameOf(bmp, System.nanoTime())
                    capture.onFrame(f)
                    f.release()
                }
                delay(33)
            }
        }
    }

    override fun send(call: DuckCall) = robot.apply(call)
    override fun setVideo(on: Boolean) {}
    override fun close() { isOpen = false; job?.cancel(); frames?.cancel() }
    override val videoLive = true
    override val videoKbps: Int? = null

    @Composable
    override fun VideoView(modifier: Modifier) {
        AndroidView({ ctx ->
            ImageView(ctx).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                if (Build.VERSION.SDK_INT >= 28) {
                    val d = ImageDecoder.decodeDrawable(ImageDecoder.createSource(ctx.assets, "demo_camera.gif"))
                    setImageDrawable(d)
                    (d as? AnimatedImageDrawable)?.start()
                } else {
                    setImageBitmap(ctx.assets.open("demo_camera.gif").use { android.graphics.BitmapFactory.decodeStream(it) })
                }
            }
        }, modifier)
    }
}

@Composable
fun VideoPlaceholder(text: String, modifier: Modifier = Modifier) {
    Column(modifier.background(Palette.panel).padding(16.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        IconView(Icon.WIFI, 30.dp, Palette.disabled, 2f)
        Spacer(Modifier.height(8.dp))
        T(text, 12f, color = Palette.disabled, weight = FontWeight.Bold)
    }
}
