package robot.duckbuddy.microduck

import robot.duckbuddy.microduck.state.DebugArgs

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import robot.duckbuddy.microduck.design.*
import robot.duckbuddy.microduck.screens.*
import robot.duckbuddy.microduck.drive.DriveScreen
import robot.duckbuddy.microduck.state.AppModel
import robot.duckbuddy.microduck.state.LinkState
import robot.duckbuddy.microduck.state.Power
import robot.duckbuddy.microduck.state.Route
import kotlinx.coroutines.delay
import uniffi.duck_core.colourwayFromKey

val LocalModel = staticCompositionLocalOf<AppModel> { error("no model") }

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (model.demo.not()) model.session.startScan()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val demo = intent.getBooleanExtra("demo", false)
        if (demo) {
            DebugArgs.webrtcIP = intent.getStringExtra("webrtc")
            DebugArgs.stick = intent.getStringExtra("stick")
            DebugArgs.tray = intent.getBooleanExtra("tray", false)
            DebugArgs.capture = intent.getStringExtra("capture")
        }
        model.start(demo)

        // 后台立即关闭视频与控制通道，机器人"死人开关"约 0.6 s 内停下（PRD §6）。
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStop(owner: LifecycleOwner) = model.session.media.close()
            override fun onStart(owner: LifecycleOwner) {
                val s = model.session
                if (s.linkState == LinkState.Ready) s.mediaIP?.let { s.media.open(it, s) }
            }
        })

        if (!demo) {
            // 首次用到时再申请：启动即连接页，需要蓝牙。
            permissions.launch(if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
                else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION))
        }

        // 调试：`--es route drive|status|...`、`--es window 820x904`（模拟折叠屏内屏等窗口）、`--ez en true`、`--es colourway sky`。
        val route = intent.getStringExtra("route")
        val window = intent.getStringExtra("window")?.split("x")?.mapNotNull { it.toFloatOrNull() }
        if (intent.getBooleanExtra("en", false)) model.setLanguage(Lang.en)

        setContent {
            CompositionLocalProvider(LocalModel provides model) {
                key(model.lang) {
                    Box(Modifier.fillMaxSize().background(if (window != null) Color(0xFF3A3A3A) else Palette.bg), contentAlignment = Alignment.Center) {
                        val m = if (window != null && window.size == 2) Modifier.size(window[0].dp, window[1].dp).border(1.dp, Color.White.copy(alpha = 0.4f))
                            else Modifier.fillMaxSize()
                        Box(m) { AdaptiveRoot { Root() } }
                    }
                }
            }
            if (demo && route != null) LaunchedEffect(Unit) {
                if (route == "setup") { model.push(Route.Setup); return@LaunchedEffect }
                model.connectNow()
                if (intent.getBooleanExtra("started", false)) model.session.power = Power.Stiff
                intent.getStringExtra("colourway")?.let { model.setColourway(colourwayFromKey(it)) }
                Route.entries.firstOrNull { it.name.equals(route, true) && it != Route.Drive }?.let { model.push(it) }
            }
        }
    }
}

@Composable
fun Root() {
    val model = LocalModel.current
    BackHandler(model.path.isNotEmpty()) {
        if (model.path.last() == Route.Drive) model.session.disconnect()
        model.pop()
    }
    Box(Modifier.fillMaxSize().background(Palette.bg)) {
        AnimatedContent(model.path.lastOrNull(), transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "route") { r ->
            when (r) {
                null -> ConnectScreen()
                Route.Setup -> SetupScreen()
                Route.Drive -> DriveScreen()
                Route.Status -> StatusScreen()
                Route.Policy -> PolicyScreen()
                Route.Gamepad -> GamepadScreen()
                Route.Settings -> SettingsScreen()
            }
        }
        val t = model.toast
        if (t != null && model.path.lastOrNull() != Route.Drive) {
            Box(Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 8.dp)
                .background(Palette.bg.copy(alpha = 0.78f)).padding(horizontal = 10.dp, vertical = 6.dp)) {
                T(t.first, 12f, color = if (t.second) Palette.yellow else Palette.text, weight = FontWeight.SemiBold)
            }
        }
    }
}

/** 页面外框：底色 + 系统栏内边距 + 统一页边距。 */
@Composable
fun ScreenFrame(content: @Composable ColumnScope.() -> Unit) {
    val layout = LocalLayout.current
    Column(
        Modifier.fillMaxSize().background(Palette.bg).safeDrawingPadding()
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(if (layout == LayoutClass.PhonePortrait) 14.dp else 10.dp),
        content = content,
    )
}
