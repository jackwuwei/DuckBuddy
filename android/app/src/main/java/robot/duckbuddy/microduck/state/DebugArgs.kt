package robot.duckbuddy.microduck.state

/**
 * 调试启动参数（只在演示模式下由 MainActivity 填）：
 * - `--es webrtc <ip>`：其余仍是演示数据，视频和摇杆接真机的 mediad（模拟器没有蓝牙）；
 * - `--es stick walk|head|look|height:<lx>,<ly>,<rx>,<ry>:<秒>`：启动后按住摇杆一段时间再松手；
 * - `--ez tray true`：启动后打开情绪托盘（截图用）；
 * - `--es capture photo|record:<秒>`：启动后拍照 / 录像。
 */
object DebugArgs {
    var webrtcIP: String? = null
    var stick: String? = null
    var tray = false
    var capture: String? = null
}
