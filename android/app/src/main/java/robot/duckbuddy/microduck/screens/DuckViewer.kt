package robot.duckbuddy.microduck.screens

import android.annotation.SuppressLint
import android.content.Context
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.view.GestureDetector
import android.view.MotionEvent
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import uniffi.duck_core.Colourway
import uniffi.duck_core.DuckModel
import uniffi.duck_core.ModelPart
import uniffi.duck_core.viewParams
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.concurrent.thread

enum class SimState { Loading, Ready, Failed }

/**
 * 状态页 3D 机器人（OpenGL ES 3.0，`RENDERMODE_WHEN_DIRTY`）。模型解析与正向运动学在 duck-core（`DuckModel`），
 * 着色器移植自 duck-view.js / 设计稿：正交相机、按屏幕导数求面法线的平直着色。与 iOS Metal 版一致。
 */
@Composable
fun DuckViewer(joints: List<Double>, quat: List<Double>?, colourway: Colourway, resetToken: Int, onState: (SimState) -> Unit, modifier: Modifier) {
    AndroidView({ ctx -> DuckGLView(ctx, onState) }, modifier) { v ->
        v.setColourway(colourway)
        v.update(joints, quat)
        if (v.resetToken != resetToken) { v.resetToken = resetToken; v.resetView() }
    }
}

@SuppressLint("ClickableViewAccessibility", "ViewConstructor")
class DuckGLView(ctx: Context, private val onState: (SimState) -> Unit) : GLSurfaceView(ctx) {
    var resetToken = 0
    private val renderer = Renderer()
    private var lastFrame = 0L

    init {
        setEGLContextClientVersion(3)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        holder.setFormat(android.graphics.PixelFormat.TRANSLUCENT)
        setZOrderOnTop(false)
        setRenderer(renderer)
        renderMode = RENDERMODE_WHEN_DIRTY
        val detector = GestureDetector(ctx, object : GestureDetector.SimpleOnGestureListener() {
            override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
                val d = resources.displayMetrics.density
                renderer.azimuth -= dx / d * 0.012f
                renderer.elevation = (renderer.elevation + dy / d * 0.008f).coerceIn(0.05f, 0.82f)
                requestRender(); return true
            }
            override fun onDoubleTap(e: MotionEvent): Boolean { resetView(); return true }
            override fun onDown(e: MotionEvent) = true
        })
        setOnTouchListener { _, e -> detector.onTouchEvent(e) }
        onState(SimState.Loading)
        thread(name = "duck-model") {
            val model = runCatching { DuckModel.load(ctx.assets.open("duck-web-mouth-v2.bin").use { it.readBytes() }) }.getOrNull()
            if (model == null) { post { onState(SimState.Failed) }; return@thread }
            val meshes = (0u until model.meshCount()).map { i ->
                floats(model.meshVertices(i)) to ints(model.meshIndices(i))
            }
            queueEvent { renderer.install(model, meshes, model.parts()); post { onState(SimState.Ready) }; requestRender() }
        }
    }

    fun setColourway(c: Colourway) {
        if (renderer.colourway == c) return
        renderer.colourway = c
        requestRender()
    }

    fun resetView() { renderer.azimuth = -0.7f; renderer.elevation = 0.32f; requestRender() }

    /** 限 30 fps，空闲时不重绘。 */
    fun update(joints: List<Double>, quat: List<Double>?) {
        renderer.joints = joints
        renderer.quat = quat
        val now = System.currentTimeMillis()
        if (now - lastFrame >= 33) { lastFrame = now; requestRender() }
    }

    private fun floats(l: List<Float>) = ByteBuffer.allocateDirect(l.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { l.forEach { put(it) }; position(0) }
    private fun ints(l: List<UInt>) = ByteBuffer.allocateDirect(l.size * 4).order(ByteOrder.nativeOrder()).asIntBuffer().apply { l.forEach { put(it.toInt()) }; position(0) }

    private inner class Renderer : GLSurfaceView.Renderer {
        @Volatile var azimuth = -0.7f
        @Volatile var elevation = 0.32f
        @Volatile var joints: List<Double> = emptyList()
        @Volatile var quat: List<Double>? = null
        private var program = 0
        private var model: DuckModel? = null
        private var parts: List<ModelPart> = emptyList()
        /** 配色；渲染线程发现变了就向 core 重取每个部件的颜色（rgb 三个一组）。 */
        @Volatile var colourway: Colourway = Colourway.CREAM
        private var colours = FloatArray(0)
        private var coloursFor: Colourway? = null
        private val vaos = mutableListOf<Pair<Int, Int>>()
        private var grid = 0
        private var gridCount = 0
        private var w = 1; private var h = 1

        fun install(m: DuckModel, meshes: List<Pair<java.nio.FloatBuffer, java.nio.IntBuffer>>, p: List<ModelPart>) {
            meshes.forEach { (v, i) -> vaos += vao(v, i) to i.capacity() }
            parts = p
            model = m
        }

        private fun vao(v: java.nio.FloatBuffer, i: java.nio.IntBuffer?): Int {
            val ids = IntArray(1); GLES30.glGenVertexArrays(1, ids, 0); GLES30.glBindVertexArray(ids[0])
            val b = IntArray(2); GLES30.glGenBuffers(2, b, 0)
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, b[0])
            GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, v.capacity() * 4, v, GLES30.GL_STATIC_DRAW)
            GLES30.glEnableVertexAttribArray(0)
            GLES30.glVertexAttribPointer(0, 3, GLES30.GL_FLOAT, false, 12, 0)
            if (i != null) {
                GLES30.glBindBuffer(GLES30.GL_ELEMENT_ARRAY_BUFFER, b[1])
                GLES30.glBufferData(GLES30.GL_ELEMENT_ARRAY_BUFFER, i.capacity() * 4, i, GLES30.GL_STATIC_DRAW)
            }
            GLES30.glBindVertexArray(0)
            return ids[0]
        }

        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            program = link(VS, FS)
            val lines = ArrayList<Float>()
            var v = -0.30f
            while (v <= 0.30001f) { lines += listOf(v, -0.3f, 0f, v, 0.3f, 0f, -0.3f, v, 0f, 0.3f, v, 0f); v += 0.05f }
            gridCount = lines.size / 3
            grid = vao(floats(lines), null)
            GLES30.glClearColor(0f, 0f, 0f, 0f)
            GLES30.glEnable(GLES30.GL_DEPTH_TEST)
        }

        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) { w = width; h = height; GLES30.glViewport(0, 0, width, height) }

        override fun onDrawFrame(gl: GL10?) {
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT or GLES30.GL_DEPTH_BUFFER_BIT)
            val m = model ?: return
            val vp = viewParams(azimuth, elevation, w.toFloat(), h.toFloat())
            GLES30.glUseProgram(program)
            fun u(n: String) = GLES30.glGetUniformLocation(program, n)
            GLES30.glUniform3f(u("uRight"), vp.right[0], vp.right[1], vp.right[2])
            GLES30.glUniform3f(u("uUp"), vp.up[0], vp.up[1], vp.up[2])
            GLES30.glUniform3f(u("uForward"), vp.forward[0], vp.forward[1], vp.forward[2])
            GLES30.glUniform3f(u("uLight"), vp.light[0], vp.light[1], vp.light[2])
            GLES30.glUniform2f(u("uViewScale"), vp.scaleX, vp.scaleY)
            GLES30.glUniform1f(u("uLookAt"), vp.lookAt)
            val identity = floatArrayOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)
            GLES30.glUniformMatrix4fv(u("uModel"), 1, false, identity, 0)
            GLES30.glUniform1i(u("uLineMode"), 1)
            GLES30.glUniform4f(u("uColour"), 0.89f, 0.91f, 0.93f, 0.18f)
            GLES30.glBindVertexArray(grid)
            GLES30.glDrawArrays(GLES30.GL_LINES, 0, gridCount)
            GLES30.glUniform1i(u("uLineMode"), 0)
            if (coloursFor != colourway) { val c = colourway; colours = m.partColours(c).toFloatArray(); coloursFor = c }
            val mats = m.partMatrices(joints.ifEmpty { List(15) { 0.0 } }, quat).toFloatArray()
            parts.forEachIndexed { i, p ->
                if ((i + 1) * 16 > mats.size || (i + 1) * 3 > colours.size) return@forEachIndexed
                GLES30.glUniformMatrix4fv(u("uModel"), 1, false, mats, i * 16)
                GLES30.glUniform4f(u("uColour"), colours[i * 3], colours[i * 3 + 1], colours[i * 3 + 2], 1f)
                val (vao, count) = vaos[p.mesh.toInt()]
                GLES30.glBindVertexArray(vao)
                GLES30.glDrawElements(GLES30.GL_TRIANGLES, count, GLES30.GL_UNSIGNED_INT, 0)
            }
            GLES30.glBindVertexArray(0)
        }

        private fun link(vs: String, fs: String): Int {
            fun sh(t: Int, src: String) = GLES30.glCreateShader(t).also { GLES30.glShaderSource(it, src); GLES30.glCompileShader(it) }
            return GLES30.glCreateProgram().also { p ->
                GLES30.glAttachShader(p, sh(GLES30.GL_VERTEX_SHADER, vs))
                GLES30.glAttachShader(p, sh(GLES30.GL_FRAGMENT_SHADER, fs))
                GLES30.glLinkProgram(p)
            }
        }
    }

    companion object {
        const val VS = """#version 300 es
precision highp float;
layout(location = 0) in vec3 aPosition;
uniform mat4 uModel; uniform vec3 uRight; uniform vec3 uUp; uniform vec3 uForward; uniform vec2 uViewScale; uniform float uLookAt;
out vec3 vWorld;
void main() {
  vec3 world = (uModel * vec4(aPosition, 1.0)).xyz;
  vWorld = world;
  gl_Position = vec4(dot(world, uRight) * uViewScale.x, (dot(world, uUp) - uLookAt) * uViewScale.y, dot(world, uForward) * 2.0, 1.0);
}"""
        const val FS = """#version 300 es
precision highp float;
uniform vec4 uColour; uniform vec3 uLight; uniform bool uLineMode;
in vec3 vWorld; out vec4 outColour;
void main() {
  if (uLineMode) { outColour = vec4(uColour.rgb * uColour.a, uColour.a); return; }
  vec3 normal = normalize(cross(dFdx(vWorld), dFdy(vWorld)));
  if (!gl_FrontFacing) normal = -normal;
  float diffuse = max(dot(normal, normalize(uLight)), 0.0);
  float hemisphere = 0.5 + 0.5 * normal.z;
  outColour = vec4(uColour.rgb * (0.56 + 0.34 * diffuse + 0.10 * hemisphere), 1.0);
}"""
    }
}
