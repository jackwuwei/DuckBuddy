package robot.duckbuddy.microduck.design

import android.graphics.BitmapFactory
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import robot.duckbuddy.microduck.L
import robot.duckbuddy.microduck.R
import uniffi.duck_core.Origin

/** 设计 Token，数值逐一取自设计画布（与 iOS `Design/Theme.swift` 一一对应）。 */
object Palette {
    val bg = Color(0xFF08080C)
    val card = Color(0xFF101018)
    val inset = Color(0xFF1D1D29)
    val orange = Color(0xFFFF7A2F)
    val yellow = Color(0xFFFFD23F)
    val pink = Color(0xFFFF2FA8)
    val cyan = Color(0xFF2FF0E6)
    val purple = Color(0xFF9D87E8)
    val text = Color.White
    val light = Color(0xFFDCD7CC)
    val dim = Color(0xFFA19FA9)
    val muted = Color(0xFF8E8C96)
    val disabled = Color(0xFF6E6C78)
    val hairline = Color.White.copy(alpha = 0.09f)
    val field = Color.White.copy(alpha = 0.22f)
    val dashed = Color.White.copy(alpha = 0.35f)
    val video = Color(0xFF13131B)
    val panel = Color(0xFF0D0D14)
    val stick = Color(0xFF111119)
    val result = Color(0xFF15151F)

    fun origin(o: Origin?): Color = when (o) {
        is Origin.Official -> orange
        is Origin.Community -> purple
        is Origin.Local -> light
        else -> disabled
    }
}

object Typo {
    val anton = FontFamily(Font(R.font.anton))
    val dmSans = FontFamily(Font(R.font.dm_sans, FontWeight.Normal), Font(R.font.dm_sans, FontWeight.SemiBold),
        Font(R.font.dm_sans, FontWeight.Bold), Font(R.font.dm_sans, FontWeight.ExtraBold))

    fun body(size: Float = 15f, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontFamily = dmSans, fontSize = size.sp, fontWeight = weight, color = Palette.text,
            fontFeatureSettings = "tnum")
}

/**
 * Anton 标题：拉丁字符 Anton 全大写，中文用系统黑体最粗字重（设计稿 `Anton, 'Noto Sans SC'` 900），字距 0.02em。
 */
fun titleText(s: String, size: Float, tracking: Float = 0.02f): AnnotatedString = buildAnnotatedString {
    var run = StringBuilder()
    var cjk: Boolean? = null
    fun flush() {
        val c = cjk ?: return
        if (run.isEmpty()) return
        val style = if (c) SpanStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Black, fontSize = (size * 0.92f).sp,
            letterSpacing = (size * tracking).sp)
        else SpanStyle(fontFamily = Typo.anton, fontSize = size.sp, letterSpacing = (size * tracking).sp)
        withStyle(style) { append(if (c) run.toString() else run.toString().uppercase()) }
        run = StringBuilder()
    }
    for (ch in s) {
        val isCjk = ch.code >= 0x2E80
        if (cjk != isCjk) { flush(); cjk = isCjk }
        run.append(ch)
    }
    flush()
}

@Composable
fun Title(s: String, size: Float, modifier: Modifier = Modifier, color: Color = Palette.text, tracking: Float = 0.02f) {
    androidx.compose.foundation.text.BasicText(titleText(s, size, tracking), modifier, style = TextStyle(color = color),
        maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
fun T(s: String, size: Float, modifier: Modifier = Modifier, color: Color = Palette.text, weight: FontWeight = FontWeight.Normal,
      maxLines: Int = Int.MAX_VALUE, lineHeight: Float? = null, strike: Boolean = false) {
    androidx.compose.foundation.text.BasicText(s, modifier,
        style = Typo.body(size, weight).copy(color = color, lineHeight = lineHeight?.sp ?: TextUnit.Unspecified,
            textDecoration = if (strike) TextDecoration.LineThrough else null),
        maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

// ── 硬投影 / 选中态 / 卡片 ──────────────────────────────────────────────

/** CSS `box-shadow: 4px 4px 0`：内容下方偏移 (4,4) 的实色块，无模糊。 */
fun Modifier.hardShadow(color: Color, offset: Dp = 4.dp, shape: Shape = RectangleShape): Modifier = drawBehind {
    if (color.alpha == 0f) return@drawBehind
    val o = offset.toPx()
    translate(o, o) {
        drawOutline(shape.createOutline(size, layoutDirection, this), color)
    }
}

/** 统一选中态：2dp 橙描边 + 4dp 橙硬投影。 */
fun Modifier.selectable(on: Boolean): Modifier =
    hardShadow(if (on) Palette.orange else Color.Transparent)
        .border(2.dp, if (on) Palette.orange else Color.Transparent)
        .semantics { selected = on }

fun Modifier.card(fill: Color = Palette.card): Modifier = background(fill).border(1.dp, Palette.hairline)

/** 按下向右下平移 2dp（设计稿 button:active）。 */
@Composable
fun Modifier.press(enabled: Boolean = true, role: Role = Role.Button, label: String? = null, onClick: () -> Unit): Modifier {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    return this.offset(if (pressed) 2.dp else 0.dp, if (pressed) 2.dp else 0.dp)
        .clickable(src, null, enabled, role = role, onClickLabel = label, onClick = onClick)
}

// ── 图标 ──────────────────────────────────────────────────────────────

private val pathCache = HashMap<String, Path>()

@Composable
fun IconView(icon: Icon, size: Dp = 24.dp, color: Color = Palette.text, weight: Float = 1.9f, modifier: Modifier = Modifier) {
    val path = remember(icon) { pathCache.getOrPut(icon.path) { PathParser().parsePathString(icon.path).toPath() } }
    Canvas(modifier.size(size)) {
        val s = this.size.width / 24f
        scale(s, s, pivot = Offset.Zero) {
            drawPath(path, color, style = Stroke(width = weight, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
    }
}

// ── 组件 ──────────────────────────────────────────────────────────────

@Composable
fun PrimaryButton(title: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 50.dp,
                  fontSize: Float = 18f, progress: Float? = null, onClick: () -> Unit) {
    Box(
        modifier.fillMaxWidth().height(height)
            .hardShadow(if (enabled) Palette.yellow else Color.Transparent)
            .background(if (enabled) Palette.orange else Palette.inset)
            .border(2.dp, if (enabled) Palette.bg else Color.Transparent)
            .press(enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (progress != null) Box(Modifier.align(Alignment.CenterStart).fillMaxHeight().fillMaxWidth(progress).background(Color.White.copy(alpha = 0.35f)))
        Title(title, fontSize, color = if (enabled) Palette.bg else Palette.disabled)
    }
}

@Composable
fun CircleIconButton(icon: Icon, label: String, size: Dp = 36.dp, tint: Color = Palette.text, fill: Color = Palette.card,
                     modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.size(size).background(fill, CircleShape).border(1.dp, Palette.hairline, CircleShape)
            .press(label = label, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { IconView(icon, size * 0.5f, tint, if (icon == Icon.BACK) 2.2f else 1.9f) }
}

@Composable
fun SquareAction(icon: Icon, title: String, tint: Color = Palette.text, fill: Color = Palette.card, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier.height(36.dp).background(fill).border(1.dp, Palette.hairline).press(enabled, onClick = onClick)
            .padding(start = 10.dp, end = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        IconView(icon, 18.dp, tint)
        T(title, 12f, color = tint, weight = FontWeight.Bold, maxLines = 1)
    }
}

@Composable
fun TitleBar(title: String, onBack: (() -> Unit)?, trailing: @Composable RowScope.() -> Unit = {}) {
    val layout = LocalLayout.current
    Row(Modifier.fillMaxWidth().height(36.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (onBack != null) CircleIconButton(Icon.BACK, L("back"), onClick = onBack)
        Title(title, if (layout == LayoutClass.PhoneLandscape) 24f else 26f, Modifier.weight(1f))
        trailing()
    }
}

@Composable
fun Dot(color: Color, size: Dp = 8.dp) = Box(Modifier.size(size).background(color, CircleShape))

@Composable
fun <K> ChoiceChips(options: List<Triple<K, String, Icon?>>, selection: K, badge: (K) -> Boolean = { false }, onPick: (K) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { (value, label, icon) ->
            val on = selection == value
            Row(
                Modifier.height(34.dp).selectable(on).background(if (on) Palette.inset else Palette.card)
                    .press(role = Role.Tab) { onPick(value) }.padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (icon != null) IconView(icon, 16.dp)
                T(label, 13f, weight = FontWeight.Bold)
                if (badge(value)) Dot(Palette.pink, 7.dp)
            }
        }
    }
}

@Composable
fun FieldBox(icon: Icon? = null, error: Boolean = false, height: Dp = 44.dp, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier.fillMaxWidth().height(height).background(Palette.bg).border(1.dp, if (error) Palette.pink else Palette.field)
            .padding(start = 12.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (icon != null) IconView(icon, 18.dp, Palette.dim)
        content()
    }
}

@Composable
fun RowScope.InputText(value: String, onChange: (String) -> Unit, placeholder: String, secret: Boolean = false,
                       mono: Boolean = false, size: Float = 14f, weight: FontWeight = FontWeight.Normal, enabled: Boolean = true,
                       label: String = placeholder, numeric: Boolean = false) {
    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
        if (value.isEmpty()) T(placeholder, size, color = Palette.disabled)
        BasicTextField(
            value, onChange, Modifier.fillMaxWidth().semantics { contentDescription = label }, enabled = enabled, singleLine = true,
            textStyle = Typo.body(size, weight).copy(fontFamily = if (mono) FontFamily.Monospace else Typo.dmSans),
            cursorBrush = SolidColor(Palette.orange),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = if (numeric) androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.NumberPassword)
                else androidx.compose.foundation.text.KeyboardOptions.Default,
        )
    }
}

@Composable
fun RowScope.SecretInput(value: String, onChange: (String) -> Unit, placeholder: String, mono: Boolean = false, enabled: Boolean = true) {
    var shown by remember { mutableStateOf(false) }
    InputText(value, onChange, placeholder, secret = !shown, mono = mono, enabled = enabled)
    Box(Modifier.size(36.dp).press(label = L("showPw")) { shown = !shown }, contentAlignment = Alignment.Center) {
        IconView(Icon.EYE, 18.dp, Palette.dim)
    }
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) =
    androidx.compose.foundation.text.BasicText(text, modifier, style = Typo.body(11f, FontWeight.Bold).copy(color = Palette.dim, letterSpacing = 0.44.sp))

@Composable
fun SignalBars(level: Int) {
    Row(Modifier.height(14.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (b in 1..3) Box(Modifier.width(4.dp).height((4 + b * 3).dp).background(if (b <= level) Palette.cyan else Color.White.copy(alpha = 0.18f)))
    }
}

@Composable
fun BatteryGlyph(fraction: Double, color: Color = Palette.text) {
    Canvas(Modifier.size(20.dp, 14.dp)) {
        val s = size.width / 26f
        drawRoundRect(color, Offset(1 * s, 2 * s), Size(21 * s, 12 * s), CornerRadius(3 * s), style = Stroke(1.6f * s))
        drawLine(color, Offset(24.5f * s, 6 * s), Offset(24.5f * s, 10 * s), 1.6f * s, StrokeCap.Round)
        val w = fraction.coerceIn(0.0, 1.0).toFloat() * 16
        if (w > 0) drawRoundRect(Palette.cyan, Offset(3.5f * s, 4.5f * s), Size(w * s, 7 * s), CornerRadius(1.5f * s))
    }
}

private val bitmapCache = HashMap<String, ImageBitmap>()

@Composable
fun DuckImage(modifier: Modifier = Modifier, quacking: Boolean = false) {
    val ctx = LocalContext.current
    val name = if (quacking) "duck_quack.png" else "duck.png"
    val bmp = remember(name) { bitmapCache.getOrPut(name) { ctx.assets.open(name).use { BitmapFactory.decodeStream(it).asImageBitmap() } } }
    Image(bmp, null, modifier)
}

/** 虚线框（设计稿 1.5px dashed）。 */
fun Modifier.dashedBorder(color: Color = Palette.dashed, width: Dp = 1.5.dp, shape: Shape = RectangleShape): Modifier = drawBehind {
    val w = width.toPx()
    drawOutline(shape.createOutline(size, layoutDirection, this), color,
        style = Stroke(w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))))
}

@Suppress("unused")
val NoBorder = BorderStroke(0.dp, Color.Transparent)
