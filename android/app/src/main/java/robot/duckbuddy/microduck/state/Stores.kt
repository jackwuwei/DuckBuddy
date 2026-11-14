package robot.duckbuddy.microduck.state

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 系统安全存储：Android Keystore 生成的 AES-GCM 密钥加密后存 `secure.xml`；
 * 该文件在 data_extraction_rules / backup_rules 中排除，不进云备份、不随设备迁移（技术方案 3.3.4）。
 */
class SecureStore(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("secure", Context.MODE_PRIVATE)
    private val alias = "duckbuddy-secure"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return gen.generateKey()
    }

    fun set(account: String, value: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val blob = c.iv + c.doFinal(value.toByteArray())
        prefs.edit().putString(account, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    fun get(account: String): String? = runCatching {
        val blob = Base64.decode(prefs.getString(account, null) ?: return null, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, 12)) }
        String(c.doFinal(blob, 12, blob.size - 12))
    }.getOrNull()

    fun remove(account: String) = prefs.edit().remove(account).apply()

    companion object {
        fun setupCodeKey(id: String) = "setup-code:$id"
        const val DOUBAO = "doubao-credential"
    }
}

/** 已添加过的机器人：按首名（SoC 序列号派生）识别，蓝牙地址只作缓存；不保存设置码。 */
data class KnownRobot(val id: String, val displayName: String, val lastIPv4: String?, val lastVolts: Double?,
                      val address: String? = null, val lastUsed: Long = System.currentTimeMillis(),
                      /** 官方配色（`colourwayKey`），用户在状态页选；空则为默认 Cream。 */
                      val colourway: String? = null)

class RobotStore(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("robots", Context.MODE_PRIVATE)

    fun load(): List<KnownRobot> = runCatching {
        val a = JSONArray(prefs.getString("robots", "[]"))
        (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            KnownRobot(o.getString("id"), o.getString("displayName"), o.optString("lastIPv4").ifEmpty { null },
                if (o.has("lastVolts")) o.getDouble("lastVolts") else null, o.optString("address").ifEmpty { null }, o.getLong("lastUsed"),
                o.optString("colourway").ifEmpty { null })
        }.sortedByDescending { it.lastUsed }
    }.getOrDefault(emptyList())

    fun save(list: List<KnownRobot>) {
        val a = JSONArray()
        list.forEach { r ->
            a.put(JSONObject().put("id", r.id).put("displayName", r.displayName).put("lastIPv4", r.lastIPv4 ?: "")
                .apply { r.lastVolts?.let { put("lastVolts", it) } }.put("address", r.address ?: "").put("lastUsed", r.lastUsed)
                .put("colourway", r.colourway ?: ""))
        }
        prefs.edit().putString("robots", a.toString()).apply()
    }
}
