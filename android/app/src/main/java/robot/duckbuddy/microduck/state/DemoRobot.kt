package robot.duckbuddy.microduck.state

import kotlinx.coroutines.delay
import uniffi.duck_core.*
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * 演示鸭子：按官方回复的形状应答（JSON 与 `duck-ipc-proto` 一致，经同一套 duck-core 解码）。
 * 与 iOS `DemoRobot.swift` 同一份数据。启动参数 `--ez demo true`。
 */
class DemoRobot {
    private var mode = "walk"
    private var sitting = false
    /** 与真机一致：休息后没回零位（趴着但不是 sit_toggle 锁住的坐姿），站起要 init。 */
    private var homed = true
    private var enabled = false
    private var name = "duck-1a2b"
    private var head = listOf(0.0, 0.0, 0.0, 0.0)
    private var move = listOf(0.0, 0.0, 0.0)
    private var t = 0.0
    private val bindings = mutableMapOf("a" to "sit_toggle", "b" to "ground_pick", "x" to "", "y" to "", "lb" to "", "rb" to "")
    private val disabledSkills = mutableSetOf<String>()

    companion object {
        val HOME = listOf(0.0, -0.0873, -0.4579, -0.0049, 0.453, 0.3491, 0.3491, 0.0, 0.0, 0.0, 0.0, 0.0873, 0.4579, 0.0049, -0.453)
        val REST = listOf(0.3129, 0.405, -0.2338, 1.5493, 0.5522, 0.9572, 1.4787, -0.0129, -0.0522, -0.0121, 0.0353, -0.566, 0.2853, -1.4696, -0.4096)
    }

    val nearby: List<NearbyRobot>
        get() = listOf(
            NearbyRobot(Advertisement("duck-1a2b", "192.168.1.42", true, true, false), -52, null, System.currentTimeMillis()),
            NearbyRobot(Advertisement("duck-7c90", null, true, true, false), -74, null, System.currentTimeMillis()),
            NearbyRobot(Advertisement("duck-e41f", null, true, true, false), -88, null, System.currentTimeMillis()),
        )

    fun name(id: String) = if (id == "duck-1a2b") name else id

    fun apply(c: DuckCall) {
        when (c) {
            is DuckCall.RobotMove -> move = listOf(c.vx, c.vy, c.vyaw)
            is DuckCall.RobotHead -> head = listOf(c.neckPitch, c.headPitch, c.headYaw, c.headRoll)
            else -> {}
        }
    }

    fun tick(): DuckState {
        t += 0.1
        val targets = (if (sitting || !homed) REST else HOME).toMutableList()
        targets[6] += head[1]; targets[7] += head[2]; targets[8] += head[3]
        val joints = targets.mapIndexed { i, v -> v + ((if (i == 3) 2.2 else 0.0) + sin(t * 0.9 + i * 1.7) * 0.35) * PI / 180 }
        val pitch = -(if (sitting || !homed) 9.0 else 3.0) * PI / 180
        val quat = listOf(cos(pitch / 2), 0.0, sin(pitch / 2), 0.0)
        return DuckState(t, joints, targets, quat, if (enabled) "walk" else "held", false, !enabled, false, head, move,
            classifyPosture(joints, quat))
    }

    suspend fun answer(c: DuckCall, session: RobotSession): String {
        delay(120)
        val ok = """{"accepted":true}"""
        return when (c) {
            is DuckCall.SystemInfo -> """{"name":"$name","serial":"1a2b3c4d","uptime_seconds":5321}"""
            is DuckCall.SystemSetName -> { name = c.name; """{"name":"${c.name}"}""" }
            is DuckCall.RobotHealth -> """{"healthy":true,"battery":{"volts":7.9,"percent":81},"motors":{"hottest":"left_knee","max_c":41.5,"mean_c":36.2},"cpu_temp_c":52.0,"bus":{"consecutive_errors":0,"startup_failures":0}}"""
            is DuckCall.NetStatus -> """{"state":"connected","ssid":"Home Wi-Fi","signal":72,"ip4":"192.168.1.42","ip6":null,"mac":null,"iface":"wlan0"}"""
            is DuckCall.NetScan -> { delay(600); """{"networks":[{"ssid":"Home Wi-Fi","signal":72,"security":"wpa_psk","saved":true},{"ssid":"Home Wi-Fi 5G","signal":64,"security":"wpa_psk","saved":false},{"ssid":"Phone hotspot","signal":45,"security":"wpa_psk","saved":false},{"ssid":"Neighbour","signal":20,"security":"wpa_psk","saved":false}]}""" }
            is DuckCall.NetConnect -> { delay(1500); """{"state":"connected","ssid":"Home Wi-Fi","signal":72,"ip4":"192.168.1.42","ip6":null,"mac":null,"iface":"wlan0"}""" }
            is DuckCall.RobotPolicies -> {
                val r = mode == "roller"
                """{"mode":"$mode","enabled":true,"homed":$homed,"sitting":$sitting,"skills":["kick_left","kick_right","roulade"],"slots":[
                {"slot":"walk","path":"/usr/share/microduck/policies/${if (r) "roller" else "velstand"}.onnx","origin":"official","overridden":false,"error":null},
                {"slot":"stand","path":null,"origin":null,"overridden":false,"error":null},
                {"slot":"sitstand","path":"/usr/share/microduck/policies/alpha_sitstand.onnx","origin":"official","overridden":false,"error":null},
                {"slot":"ground_pick","path":"/usr/share/microduck/policies/${if (r) "roller_crouch" else "alpha_ground_pick"}.onnx","origin":"official","overridden":false,"error":null}]}"""
            }
            is DuckCall.RobotSkills -> {
                fun s(n: String, d: Double, chain: Boolean) = """{"name":"$n","path":${if (n in disabledSkills) "\"none\"" else "null"},"duration":$d,"chain":$chain}"""
                """{"skills":[${s("kick_left", 1.6, false)},${s("kick_right", 1.6, false)},${s("roulade", 2.4, true)}],"built_in":["ground_pick","sit_toggle"]}"""
            }
            is DuckCall.RobotDisableSkill -> { disabledSkills += c.name; ok }
            is DuckCall.RobotAddSkill -> { disabledSkills -= c.name; ok }
            is DuckCall.PadBindings -> """{"bindings":[${listOf("a", "b", "x", "y", "lb", "rb").joinToString(",") { """{"button":"$it","skill":"${bindings[it]}","overridden":false}""" }}]}"""
            is DuckCall.PadBind -> {
                bindings[c.button] = when (val t = c.target) {
                    is PadTarget.Skill -> t.name
                    is PadTarget.Off -> ""
                    is PadTarget.Default -> mapOf("a" to "sit_toggle", "b" to "ground_pick")[c.button] ?: ""
                }
                ok
            }
            is DuckCall.RobotSetMode -> { delay(900); mode = if (c.mode == LocoMode.ROLLER) "roller" else "walk"; ok }
            // 与真机一致：策略接管后自己回零位、从座位起身。
            is DuckCall.RobotEnable -> { enabled = c.on; if (c.on) { homed = true; sitting = false }; ok }
            is DuckCall.RobotDo -> if (!enabled) """{"accepted":false,"reason":"press Start first"}""" else { if (c.skill == "sit_toggle") { if (sitting) { sitting = false; homed = true } else if (homed) sitting = true }; ok }
            is DuckCall.RobotRest, is DuckCall.RobotShutdown -> { enabled = false; sitting = false; homed = false; ok }
            is DuckCall.RobotInit -> { enabled = false; sitting = true; homed = true; ok }
            is DuckCall.RobotLoadPolicy -> { delay(1200); ok }
            is DuckCall.PolicyCheck -> "[]"
            is DuckCall.PolicySearch -> { delay(500); """{"models":[{"id":"pollen-robotics/microduck-bouncy-walk","origin":"official","likes":12,"downloads":340,"description":"A bouncier walk"},{"id":"someone/flamingo-cycle","origin":"community","likes":3,"downloads":41,"description":"Stands on one foot, switching sides"},{"id":"someone/bow","origin":"community","likes":5,"downloads":20,"description":"Bows from a two-foot stand and comes back up, 4 s"}]}""" }
            is DuckCall.PolicyFetch -> {
                delay(900)
                val leaf = c.repo.substringAfterLast('/')
                """{"path":"/var/lib/microduck/policies/$leaf.onnx","repo":"${c.repo}","revision":"main","commit":null,"file":"policy.onnx","origin":"community","name":"$leaf","description":null,"kind":null,"duration_s":4.0,"action_scale":null,"unwind_s":null,"idle":null,"encoding":null,"chain":false,"schema_version":1}"""
            }
            else -> ok
        }
    }
}
