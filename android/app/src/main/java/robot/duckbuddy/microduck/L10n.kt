package robot.duckbuddy.microduck

import android.content.Context
import org.json.JSONObject

/** 全局语言。文案只有一份：`app/shared/i18n/strings.json`（两端共用，作为 asset 打包）。 */
enum class Lang { zh, en }

object L10n {
    private var table: Map<String, Map<String, String>> = emptyMap()
    @Volatile var lang: Lang = Lang.zh

    fun load(ctx: Context) {
        if (table.isNotEmpty()) return
        val json = JSONObject(ctx.assets.open("strings.json").bufferedReader().readText())
        table = json.keys().asSequence().associateWith { k ->
            val o = json.getJSONObject(k)
            o.keys().asSequence().associateWith { o.getString(it) }
        }
    }

    fun text(key: String): String = table[key]?.get(lang.name) ?: table[key]?.get("zh") ?: key
}

/** 取文案；`args` 依次替换 `{0}`、`{1}`… */
fun L(key: String, vararg args: Any?): String {
    var s = L10n.text(key)
    args.forEachIndexed { i, a -> s = s.replace("{$i}", a.toString()) }
    return s
}
