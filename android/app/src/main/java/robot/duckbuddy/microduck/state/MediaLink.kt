package robot.duckbuddy.microduck.state

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
    /** 关闭视频：只把视频收发器设为 inactive，数据通道保留（D-7）。 */
    fun setVideo(on: Boolean)
    fun close()
    @Composable fun VideoView(modifier: Modifier)
}

/**
 * 真机 WebRTC 通道。依赖 Google libwebrtc（`org.webrtc`）与 `duck-gateway` 认证隧道，接入点已固定；
 * 接入之前保持未打开：驾驶页显示"视频需要机器人联网"，蓝牙控制（动作、启动、电源）照常可用。
 */
class WebRTCMediaLink : MediaLink {
    override var onState: ((DuckState) -> Unit)? = null
    override var isOpen = false; private set
    private val codec = RpcCodec()

    override fun open(ip: String, session: RobotSession) {
        // TODO(M2): PeerConnectionFactory + 经认证隧道交换 offer/answer；teleop / control 两个数据通道。
        isOpen = false
    }

    override fun send(call: DuckCall) {
        if (!isOpen) return
        codec.encode(call) // 由 teleop 数据通道发送
    }

    override fun setVideo(on: Boolean) {}
    override fun close() { isOpen = false }

    @Composable
    override fun VideoView(modifier: Modifier) = VideoPlaceholder(L("videoNeedsWifi"), modifier)
}

/** 演示通道：10 Hz 状态流 + 动图画面。 */
class DemoMediaLink(private val robot: DemoRobot, private val scope: CoroutineScope) : MediaLink {
    override var onState: ((DuckState) -> Unit)? = null
    override var isOpen = false; private set
    private var job: Job? = null

    override fun open(ip: String, session: RobotSession) {
        isOpen = true
        job?.cancel()
        job = scope.launch { while (isActive) { onState?.invoke(robot.tick()); delay(100) } }
    }

    override fun send(call: DuckCall) = robot.apply(call)
    override fun setVideo(on: Boolean) {}
    override fun close() { isOpen = false; job?.cancel() }

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
