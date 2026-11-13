package robot.duckbuddy.microduck.design

import android.app.Activity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

/**
 * 布局类别：只看**当前窗口的实际尺寸**（与 iOS `Adaptive.swift` 同一套阈值），覆盖手机横竖屏、平板、
 * 分屏 / 自由窗口，以及折叠屏（Galaxy Z Fold、Pixel Fold、Surface Duo）合上 / 展开。
 */
enum class LayoutClass {
    /** 窄竖屏：手机竖屏、折叠屏外屏、平板窄分屏。 */
    PhonePortrait,
    /** 矮横屏：手机横屏（高 < 500）。 */
    PhoneLandscape,
    /** 接近正方形的大屏：折叠屏展开、平板竖屏分屏一半。两栏等分 / 以铰链为界。 */
    Dual,
    /** 宽大屏：平板全屏 / 宽窗口。 */
    Expanded;

    val isWide get() = this == Dual || this == Expanded

    companion object {
        fun of(size: DpSize): LayoutClass {
            val w = size.width.value
            val h = size.height.value
            if (w <= 0 || h <= 0) return PhonePortrait
            if (w < 600) return if (h < 500 && w > h) PhoneLandscape else PhonePortrait
            if (h < 500) return PhoneLandscape
            return if (w / h < 1.3f) Dual else Expanded
        }
    }
}

/**
 * 折叠屏铰链（Jetpack WindowManager `FoldingFeature`），坐标为窗口内 dp。
 * - 竖直铰链（书本姿态、Surface Duo 双屏）：两栏以铰链为界，任何控件都不跨铰链；
 * - 水平铰链且半开（桌面姿态）：驾驶页视频在上半屏、摇杆在下半屏。
 */
data class Hinge(val left: Dp, val top: Dp, val right: Dp, val bottom: Dp, val vertical: Boolean, val tabletop: Boolean, val separating: Boolean)

val LocalLayout = compositionLocalOf { LayoutClass.PhonePortrait }
val LocalWindowSize = compositionLocalOf { DpSize(390.dp, 844.dp) }
val LocalHinge = compositionLocalOf<Hinge?> { null }

@Composable
fun AdaptiveRoot(content: @Composable () -> Unit) {
    val ctx = LocalContext.current
    val density = LocalDensity.current
    val activity = ctx as Activity
    val fold by remember(activity) {
        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity)
    }.collectAsState(initial = null)

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val size = DpSize(maxWidth, maxHeight)
        val feature = fold?.displayFeatures?.filterIsInstance<FoldingFeature>()?.firstOrNull()
        val hinge = feature?.let { f ->
            with(density) {
                Hinge(
                    f.bounds.left.toDp(), f.bounds.top.toDp(), f.bounds.right.toDp(), f.bounds.bottom.toDp(),
                    vertical = f.orientation == FoldingFeature.Orientation.VERTICAL,
                    tabletop = f.orientation == FoldingFeature.Orientation.HORIZONTAL && f.state == FoldingFeature.State.HALF_OPENED,
                    separating = f.isSeparating,
                )
            }
        }
        var layout = LayoutClass.of(size)
        // 竖直折痕 / 铰链（展平时 isSeparating 为 false，但折痕仍在）：一律按两栏处理，以折痕为界。
        if (hinge?.vertical == true && layout != LayoutClass.PhoneLandscape) layout = LayoutClass.Dual
        CompositionLocalProvider(LocalLayout provides layout, LocalWindowSize provides size, LocalHinge provides hinge) {
            content()
        }
    }
}

/**
 * 两栏：宽布局左右并排；有竖直铰链时以铰链为界（左栏正好止于铰链左缘，右栏从铰链右缘开始）；
 * 窄布局上下堆叠。
 */
@Composable
fun TwoPane(primaryFraction: Float = 0.58f, modifier: Modifier = Modifier,
            primary: @Composable () -> Unit, secondary: @Composable () -> Unit) {
    val layout = LocalLayout.current
    val hinge = LocalHinge.current
    when (layout) {
        LayoutClass.Dual, LayoutClass.Expanded -> BoxWithConstraints(modifier) {
            // 页面有左右内边距：用窗口坐标换算铰链在本容器里的位置（近似：容器水平居中）。
            val window = LocalWindowSize.current.width
            val pad = (window - maxWidth) / 2
            if (hinge != null && hinge.vertical) {
                val leftW = (hinge.left - pad).coerceIn(0.dp, maxWidth)
                val gap = (hinge.right - hinge.left).coerceAtLeast(24.dp)
                Row {
                    Box(Modifier.width(leftW - 12.dp)) { primary() }
                    Spacer(Modifier.width(gap + 24.dp))
                    Box(Modifier.weight(1f)) { secondary() }
                }
            } else {
                val f = if (layout == LayoutClass.Dual) 0.5f else primaryFraction
                val gap = if (layout == LayoutClass.Dual) 24.dp else 20.dp
                val primaryW = (maxWidth - gap) * f
                Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                    Box(Modifier.width(primaryW)) { primary() }
                    Box(Modifier.weight(1f)) { secondary() }
                }
            }
        }
        LayoutClass.PhoneLandscape -> Row(modifier, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.weight(1f)) { primary() }
            Box(Modifier.weight(1f)) { secondary() }
        }
        LayoutClass.PhonePortrait -> Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            primary()
            secondary()
        }
    }
}
