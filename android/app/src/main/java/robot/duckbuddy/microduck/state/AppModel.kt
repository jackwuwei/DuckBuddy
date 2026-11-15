package robot.duckbuddy.microduck.state

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.L10n
import robot.duckbuddy.microduck.Lang
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import uniffi.duck_core.Colourway
import uniffi.duck_core.DoubaoCredential
import uniffi.duck_core.SetupCode
import uniffi.duck_core.colourwayFromKey
import uniffi.duck_core.colourwayKey
import uniffi.duck_core.parseSetupCode

enum class Route { Setup, Drive, Status, Policy, Gamepad, Settings }

/** 豆包密钥（只存安全存储，界面只回显末 4 位）。 */
data class DoubaoKey(val apiKey: Boolean, val key: String, val appID: String?) {
    val credential: DoubaoCredential get() = if (apiKey) DoubaoCredential.ApiKey(key) else DoubaoCredential.AppToken(appID ?: "", key)
    val masked get() = "••••••" + key.takeLast(4)
}

/**
 * App 全局状态（ViewModel）：跨旋转、折叠 / 展开、分屏改变尺寸时保持，所以折叠屏开合不打断驾驶。
 * 与 iOS `AppModel.swift` 一一对应。
 */
class AppModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val secure = SecureStore(app)
    private val store = RobotStore(app)

    var demo = false; private set
    lateinit var session: RobotSession; private set
    val path = mutableStateListOf<Route>()
    var robots by mutableStateOf<List<KnownRobot>>(emptyList())
    var selectedID by mutableStateOf<String?>(null)
    var toast by mutableStateOf<Pair<String, Boolean>?>(null)
    var lang by mutableStateOf(Lang.zh); private set
    var doubaoKey by mutableStateOf<DoubaoKey?>(null); private set
    var doubaoInvalid by mutableStateOf(false)
    var speakReplies by mutableStateOf(prefs.getBoolean("speakReplies", true)); private set
    var voiceConsent by mutableStateOf(prefs.getBoolean("voiceConsent", false)); private set
    var allowCommunity by mutableStateOf(false)
    private var toastJob: Job? = null
    private var started = false

    fun start(demo: Boolean) {
        if (started) return
        started = true
        this.demo = demo
        L10n.load(getApplication())
        lang = runCatching { Lang.valueOf(prefs.getString("lang", "zh")!!) }.getOrDefault(Lang.zh)
        L10n.lang = lang
        session = RobotSession(getApplication(), demo, viewModelScope)
        robots = if (demo) listOf(
            KnownRobot("duck-1a2b", "duck-1a2b", "192.168.1.42", 7.9),
            KnownRobot("duck-7c90", "duck-7c90", null, 7.4, lastUsed = System.currentTimeMillis() - 60_000),
        ) else store.load()
        selectedID = robots.firstOrNull()?.id
        secure.get(SecureStore.DOUBAO)?.let { s ->
            runCatching { val o = JSONObject(s); doubaoKey = DoubaoKey(o.getBoolean("apiKey"), o.getString("key"), o.optString("appID").ifEmpty { null }) }
        }
    }

    fun setLanguage(l: Lang) { lang = l; L10n.lang = l; prefs.edit().putString("lang", l.name).apply() }
    fun setSpeak(on: Boolean) { speakReplies = on; prefs.edit().putBoolean("speakReplies", on).apply() }
    fun consent() { voiceConsent = true; prefs.edit().putBoolean("voiceConsent", true).apply() }

    fun say(text: String, warn: Boolean = false) {
        toast = text to warn
        toastJob?.cancel()
        toastJob = viewModelScope.launch { delay(1600); toast = null }
    }

    fun push(r: Route) { path.add(r) }
    fun pop() { if (path.isNotEmpty()) path.removeAt(path.lastIndex) }

    fun remember(r: KnownRobot) {
        robots = listOf(r) + robots.filter { it.id != r.id }
        if (!demo) store.save(robots)
    }

    fun touch(id: String) {
        robots = robots.map {
            if (it.id != id) it else it.copy(lastUsed = System.currentTimeMillis(),
                lastVolts = session.health?.batteryVolts ?: it.lastVolts, lastIPv4 = session.net?.ip4 ?: it.lastIPv4)
        }.sortedByDescending { it.lastUsed }
        if (!demo) store.save(robots)
    }

    /** 当前机器人（已连上的，否则是选中的）的配色，按机器人保存。 */
    val colourway: Colourway
        get() {
            val id = session.robotID ?: selectedID
            return colourwayFromKey(robots.firstOrNull { it.id == id }?.colourway)
        }

    fun setColourway(c: Colourway) {
        val id = session.robotID ?: selectedID ?: return
        robots = robots.map { if (it.id == id) it.copy(colourway = colourwayKey(c)) else it }
        if (!demo) store.save(robots)
    }

    fun saveDoubaoKey(k: DoubaoKey?) {
        doubaoKey = k
        doubaoInvalid = false
        if (k == null) secure.remove(SecureStore.DOUBAO)
        else secure.set(SecureStore.DOUBAO, JSONObject().put("apiKey", k.apiKey).put("key", k.key).put("appID", k.appID ?: "").toString())
    }

    fun saveSetupCode(id: String, text: String) = secure.set(SecureStore.setupCodeKey(id), text)
    fun clearSetupCode(id: String) = secure.remove(SecureStore.setupCodeKey(id))
    fun savedPin(id: String): String? = secure.get(SecureStore.pinKey(id))
    fun savePin(id: String, pin: String?) = if (pin == null) secure.remove(SecureStore.pinKey(id)) else secure.set(SecureStore.pinKey(id), pin)
    fun setupCode(id: String): SetupCode? = secure.get(SecureStore.setupCodeKey(id))?.let { runCatching { parseSetupCode(it) }.getOrNull() }

    /** 连接选中的机器人并进入驾驶页。 */
    fun connectSelected(onDone: () -> Unit = {}) {
        viewModelScope.launch { connectNow(); onDone() }
    }

    suspend fun connectNow() {
        val id = selectedID ?: return
        try {
            session.connect(id, setupCode(id), savedPin(id))
            touch(id)
            path.clear(); path.add(Route.Drive)
        } catch (e: Exception) {
            say(e.message ?: L("linkLost"), true)
        }
    }

    override fun onCleared() {
        if (started) session.disconnect()
    }
}
