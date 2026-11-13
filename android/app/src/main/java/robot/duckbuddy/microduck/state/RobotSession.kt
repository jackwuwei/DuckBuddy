package robot.duckbuddy.microduck.state

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import robot.duckbuddy.microduck.L
import kotlinx.coroutines.*
import uniffi.duck_core.*

sealed class LinkState {
    object Idle : LinkState()
    object Connecting : LinkState()
    object Pairing : LinkState()
    object Authenticating : LinkState()
    object Ready : LinkState()
    object Reconnecting : LinkState()
    data class Failed(val message: String) : LinkState()
}

/** 机器人在 App 里的"电源"状态：放松 / 站着（有力矩、未驱动）/ 行走中（策略驱动）。 */
enum class Power { Off, Stiff, Walking }

class RobotError(message: String) : Exception(message)

/**
 * 会话层（技术方案 §3.1）：蓝牙断开后静默重连、重新认证、重新拉取；前台每 20 s 发只读请求续期；
 * 所有请求由 duck-core 生成，回复按 JSON-RPC id 匹配。与 iOS `RobotSession.swift` 一一对应。
 */
class RobotSession(ctx: Context, val isDemo: Boolean, private val scope: CoroutineScope) {
    var linkState by mutableStateOf<LinkState>(LinkState.Idle); private set
    var nearby by mutableStateOf<List<NearbyRobot>>(emptyList()); private set
    var robotID by mutableStateOf<String?>(null); private set
    var robotName by mutableStateOf("")
    var health by mutableStateOf<Health?>(null)
    var net by mutableStateOf<NetStatus?>(null)
    var policies by mutableStateOf<Policies?>(null)
    var skills by mutableStateOf<List<SkillInfo>>(emptyList())
    var bindings by mutableStateOf<List<PadBinding>>(emptyList())
    var state by mutableStateOf<DuckState?>(null)
    var power by mutableStateOf(Power.Off)
    var seated by mutableStateOf(false)
    /** 全局操作锁：加载策略、切换模式、配网期间。 */
    var busy by mutableStateOf(false)

    private val demo = if (isDemo) DemoRobot() else null
    private val ble = if (isDemo) null else BleCentral(ctx)
    val media: MediaLink = if (demo != null) DemoMediaLink(demo, scope) else WebRTCMediaLink()

    private var link: DuckLink? = null
    private var credential: SetupCode? = null
    private val pending = HashMap<ULong, CompletableDeferred<String>>()
    private var connectWaiter: CompletableDeferred<Unit>? = null
    private var leaseJob: Job? = null
    private var pruneJob: Job? = null
    private var wantConnected = false
    private var device: android.bluetooth.BluetoothDevice? = null

    init {
        media.onState = { state = it }
        demo?.let { nearby = it.nearby }
        ble?.onNearbyChange = { nearby = ble!!.nearby.values.sortedByDescending { it.rssi } }
        ble?.onReady = ::linkReady
        ble?.onData = ::receive
        ble?.onDisconnect = ::linkDropped
    }

    val bluetoothUsable get() = isDemo || ble?.isPoweredOn == true

    fun startScan() {
        ble ?: return
        ble.startScan()
        pruneJob?.cancel()
        pruneJob = scope.launch { while (isActive) { delay(2000); ble.prune() } }
    }

    fun stopScan() { ble?.stopScan(); pruneJob?.cancel() }

    /** 连接并认证。`credential` 为空时走 PIN 模式（出厂 PIN 静默发送）。 */
    suspend fun connect(id: String, credential: SetupCode?) {
        robotID = id
        this.credential = credential
        wantConnected = true
        if (demo != null) {
            linkState = LinkState.Connecting
            delay(500)
            robotName = demo.name(id)
            linkState = LinkState.Ready
            afterReady()
            return
        }
        val b = ble ?: return
        if (!b.isPoweredOn) throw RobotError(L("bleOff"))
        val dev = b.nearby[id]?.device ?: throw RobotError(L("notNearby"))
        device = dev
        link = DuckLink(credential)
        linkState = LinkState.Connecting
        val w = CompletableDeferred<Unit>()
        connectWaiter = w
        b.connect(dev)
        w.await()
    }

    fun disconnect() {
        wantConnected = false
        leaseJob?.cancel()
        media.close()
        link?.shutdown()
        ble?.disconnect()
        failPending(RobotError(L("linkLost")))
        linkState = LinkState.Idle
        power = Power.Off
        state = null
    }

    private fun linkReady(mtu: Int) {
        val l = link ?: return
        l.setMtu(mtu.toUShort())
        linkState = if (credential == null) LinkState.Authenticating else LinkState.Pairing
        runCatching { ble?.write(l.open()) }.onFailure { finishConnect(it as? Exception ?: RobotError(L("linkLost"))) }
    }

    private fun receive(data: ByteArray) {
        val l = link ?: return
        l.receive(data).forEach(::handle)
    }

    private fun handle(e: LinkEvent) {
        when (e) {
            is LinkEvent.Write -> ble?.write(e.chunks)
            is LinkEvent.Authenticated -> {
                linkState = LinkState.Ready
                finishConnect(null)
                scope.launch { afterReady() }
            }
            is LinkEvent.Reply -> pending.remove(e.id)?.complete(e.resultJson)
            is LinkEvent.Refused -> pending.remove(e.id)?.completeExceptionally(RobotError(e.message))
            is LinkEvent.State -> state = e.state
            is LinkEvent.Notification -> {}
            is LinkEvent.Failed -> {
                val msg = when (val f = e.failure) {
                    is LinkFailure.RobotTooOld -> L("robotTooOld", f.apiVersion, f.minimum)
                    is LinkFailure.WrongKey -> L("wrongKey")
                    is LinkFailure.PinRejected -> L("pinRejected")
                    else -> L("linkLost")
                }
                wantConnected = false
                ble?.disconnect()
                linkState = LinkState.Failed(msg)
                finishConnect(RobotError(msg))
            }
        }
    }

    private fun finishConnect(error: Exception?) {
        val w = connectWaiter ?: return
        connectWaiter = null
        if (error != null) w.completeExceptionally(error) else w.complete(Unit)
    }

    private fun linkDropped(error: Exception?) {
        val phase = link?.phase()
        link?.shutdown()
        failPending(RobotError(L("linkLost")))
        leaseJob?.cancel()
        if (connectWaiter != null) {
            // 握手阶段断开：安全模式多半是设置码不对（机器人直接断开），或用户取消了系统配对框。
            val msg = when {
                error is BleCentral.LinkError.PairingCancelled -> L("pairCancelled")
                phase == LinkPhase.HANDSHAKING -> L("wrongKey")
                else -> L("linkLost")
            }
            linkState = LinkState.Failed(msg)
            finishConnect(RobotError(msg))
            return
        }
        val dev = device
        if (!wantConnected || dev == null) { linkState = LinkState.Idle; return }
        // 静默重连：不弹窗，成功后重新认证并重新拉取。
        linkState = LinkState.Reconnecting
        scope.launch {
            delay(1000)
            if (!wantConnected) return@launch
            link = DuckLink(credential)
            ble?.connect(dev)
        }
    }

    private fun failPending(e: Exception) {
        val all = pending.values.toList()
        pending.clear()
        all.forEach { it.completeExceptionally(e) }
    }

    private suspend fun afterReady() {
        refreshAll()
        leaseJob?.cancel()
        leaseJob = scope.launch { while (isActive) { delay(20_000); refreshHealth() } }
        net?.ip4?.let { media.open(it, this) }
    }

    /** 发一个请求并等待回复 JSON。 */
    suspend fun call(c: DuckCall, timeoutMs: Long = 10_000): String {
        demo?.let { return it.answer(c, this) }
        if (c is DuckCall.RobotMove || c is DuckCall.RobotHead) { media.send(c); return "null" }
        val l = link
        if (l == null || linkState != LinkState.Ready) throw RobotError(L("linkLost"))
        val out = l.request(c)
        val d = CompletableDeferred<String>()
        pending[out.id] = d
        ble?.write(out.chunks)
        return try {
            withTimeout(timeoutMs) { d.await() }
        } catch (e: TimeoutCancellationException) {
            throw RobotError(L("linkLost"))
        } finally {
            pending.remove(out.id)
        }
    }

    /** 动作类请求：被拒绝时返回原因，成功返回 null。 */
    suspend fun intent(c: DuckCall): String? = try {
        val json = call(c)
        runCatching { decodeIntent(json) }.getOrNull()?.takeIf { !it.accepted }?.let { it.reason ?: "refused" }
    } catch (e: Exception) {
        e.message
    }

    suspend fun refreshAll() {
        refreshHealth()
        runCatching { net = decodeNetStatus(call(DuckCall.NetStatus)) }
        refreshPolicies()
        runCatching { bindings = decodePadBindings(call(DuckCall.PadBindings)) }
        runCatching { robotName = decodeSystemInfo(call(DuckCall.SystemInfo)).name }
    }

    suspend fun refreshHealth() { runCatching { health = decodeHealth(call(DuckCall.RobotHealth)) } }

    suspend fun refreshPolicies() {
        runCatching { decodePolicies(call(DuckCall.RobotPolicies)) }.getOrNull()?.let { p ->
            policies = p
            p.sitting?.let { seated = it }
        }
        runCatching { skills = decodeSkills(call(DuckCall.RobotSkills)) }
    }

    val batteryFraction: Double get() = health?.batteryPercent?.div(100) ?: health?.batteryVolts?.let { batteryFraction(it) } ?: 0.0
    val isRoller get() = policies?.mode == "roller"
}
