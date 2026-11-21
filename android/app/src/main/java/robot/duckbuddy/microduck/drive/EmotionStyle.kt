package robot.duckbuddy.microduck.drive

import androidx.compose.ui.graphics.Color
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.design.Icon
import robot.duckbuddy.microduck.design.Palette
import uniffi.duck_core.Game

/** 情绪动作在托盘和手柄页上的样子。名字和顺序来自 core `shippedEmotions`，这里只管图标、颜色、文案。 */
object EmotionStyle {
    fun label(name: String): String = mapOf("yes" to L("yes"), "no" to L("no"), "excited" to L("excited"))[name] ?: L("emo_$name")

    fun icon(name: String): Icon = when (name) {
        "yes" -> Icon.CHECK
        "no" -> Icon.X
        "excited" -> Icon.EXCITED
        "laugh" -> Icon.EMO_LAUGH
        "curious" -> Icon.EMO_CURIOUS
        "mmh" -> Icon.EMO_MMH
        "sad" -> Icon.EMO_SAD
        "angry" -> Icon.EMO_ANGRY
        "impatient" -> Icon.EMO_IMPATIENT
        "defiant" -> Icon.EMO_DEFIANT
        "mock" -> Icon.EMO_MOCK
        "devastated" -> Icon.EMO_DEVASTATED
        "yes_fast" -> Icon.EMO_YES_FAST
        else -> Icon.EMOTION
    }

    fun color(name: String): Color = when (name) {
        "yes", "yes_fast", "curious" -> Palette.cyan
        "no", "angry", "defiant" -> Palette.pink
        "excited", "laugh", "impatient" -> Palette.orange
        "mock", "mmh" -> Palette.yellow
        else -> Palette.purple
    }
}

/** 玩法的图标和文案键。 */
object GameStyle {
    fun key(g: Game) = when (g) {
        Game.LASER -> "laser"
        Game.SOCCER -> "soccer"
        Game.AUTONOMOUS -> "autonomous"
    }

    fun icon(g: Game) = when (g) {
        Game.LASER -> Icon.GAME_LASER
        Game.SOCCER -> Icon.GAME_SOCCER
        Game.AUTONOMOUS -> Icon.GAME_AUTO
    }
}
