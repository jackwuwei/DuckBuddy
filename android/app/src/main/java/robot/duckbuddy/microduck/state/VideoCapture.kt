package robot.duckbuddy.microduck.state

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.EglBase
import org.webrtc.GlRectDrawer
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import org.webrtc.VideoFrameDrawer
import org.webrtc.YuvHelper
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger

/**
 * 机器人画面的拍照（JPEG）和录像（H.264 + AAC 的 MP4）。与 iOS `VideoCapture.swift` 对应。
 *
 * 机器人的 `mediad` 只发视频、不发音频，所以 AAC 音轨录的是手机麦克风；没有麦克风权限或麦克风起不来时写静音 AAC，
 * 文件格式不变。帧在进来时已带上相机安装角度（[WebRTCMediaLink] 的 sink 里合进 rotation），
 * 照片用 libyuv 转正，视频用 GL 画成转正后的尺寸再交给编码器。
 *
 * [onFrame] 在 WebRTC 解码线程上调用；编码、写文件在自己的线程上。
 */
class VideoCapture(private val app: Context, private val eglContext: () -> EglBase.Context?) {
    class NoFrame : Exception()

    @Volatile private var photoWanted: CompletableDeferred<ByteArray>? = null
    @Volatile private var recorder: Mp4Recorder? = null

    /** 每一帧（rotation 已含安装角度）。 */
    fun onFrame(frame: VideoFrame) {
        photoWanted?.let { want ->
            photoWanted = null
            want.complete(runCatching { jpeg(frame) }.getOrElse { ByteArray(0) })
        }
        recorder?.offer(frame)
    }

    /** 下一帧转正后编码成 JPEG；2 s 内没有帧抛 [NoFrame]。 */
    suspend fun photo(): ByteArray {
        val want = CompletableDeferred<ByteArray>()
        photoWanted = want
        val bytes = withTimeoutOrNull(2000) { want.await() }
        photoWanted = null
        if (bytes == null || bytes.isEmpty()) throw NoFrame()
        return bytes
    }

    val isRecording get() = recorder != null
    /** 有人在等帧（拍照或录像中）：演示通道只在这时才解 GIF。 */
    val wantsFrames get() = photoWanted != null || recorder != null

    /** 开始录像；有 RECORD_AUDIO 权限才录麦克风，否则静音。 */
    fun startRecording(): Boolean {
        if (recorder != null) return true
        val mic = ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val file = File(app.cacheDir, "DuckBuddy-${System.currentTimeMillis()}.mp4")
        recorder = runCatching { Mp4Recorder(file, eglContext(), mic) }.getOrNull()
        return recorder != null
    }

    /** 停止并收好文件（阻塞到写完，放在后台线程调用）；一帧都没录到时返回 null。 */
    fun stopRecording(): File? {
        val r = recorder ?: return null
        recorder = null
        return r.finish()
    }

    private fun jpeg(frame: VideoFrame): ByteArray {
        val i420 = frame.buffer.toI420() ?: throw NoFrame()
        try {
            val rot = ((frame.rotation % 360) + 360) % 360
            val w = if (rot % 180 == 0) i420.width else i420.height
            val h = if (rot % 180 == 0) i420.height else i420.width
            val cw = (w + 1) / 2; val ch = (h + 1) / 2
            val y = ByteBuffer.allocateDirect(w * h)
            val u = ByteBuffer.allocateDirect(cw * ch)
            val v = ByteBuffer.allocateDirect(cw * ch)
            YuvHelper.I420Rotate(i420.dataY, i420.strideY, i420.dataU, i420.strideU, i420.dataV, i420.strideV,
                y, w, u, cw, v, cw, i420.width, i420.height, rot)
            // NV21：Y 平面 + VU 交错。
            val nv21 = ByteArray(w * h + 2 * cw * ch)
            y.get(nv21, 0, w * h)
            var o = w * h
            for (i in 0 until cw * ch) { nv21[o++] = v.get(i); nv21[o++] = u.get(i) }
            val out = ByteArrayOutputStream()
            YuvImage(nv21, ImageFormat.NV21, w, h, intArrayOf(w, w)).compressToJpeg(Rect(0, 0, w and 1.inv(), h and 1.inv()), 92, out)
            return out.toByteArray()
        } finally {
            i420.release()
        }
    }

    companion object {
        /** 演示画面：Bitmap → I420 帧。 */
        fun frameOf(bitmap: Bitmap, timestampNs: Long): VideoFrame {
            // 宽高取 16 的倍数：色度平面宽是奇数时，有的 GL 实现上传纹理会卡住（模拟器实测）；编码器也更喜欢对齐的尺寸。
            val w = (bitmap.width + 15) / 16 * 16; val h = (bitmap.height + 15) / 16 * 16
            val argb = if (bitmap.config == Bitmap.Config.ARGB_8888 && bitmap.width == w && bitmap.height == h) bitmap
                else Bitmap.createScaledBitmap(bitmap, w, h, true).copy(Bitmap.Config.ARGB_8888, false)
            val rgba = ByteBuffer.allocateDirect(w * h * 4)
            argb.copyPixelsToBuffer(rgba)
            rgba.rewind()
            val buf = JavaI420Buffer.allocate(w, h)
            // libyuv 的 ABGR 就是内存里 R,G,B,A 的顺序，正是 Android ARGB_8888 的字节序。
            YuvHelper.ABGRToI420(rgba, w * 4, buf.dataY, buf.strideY, buf.dataU, buf.strideU, buf.dataV, buf.strideV, w, h)
            return VideoFrame(buf, 0, timestampNs)
        }
    }
}

/**
 * 一个 MP4：H.264 视频（GL 画进编码器的输入 Surface）+ AAC 音频（48 kHz 单声道），MediaMuxer 合成。
 * 两路编码器都给出格式后才启动 muxer，之前的输出先排队。
 */
private class Mp4Recorder(private val file: File, sharedContext: EglBase.Context?, mic: Boolean) {
    private val thread = HandlerThread("capture-video").apply { start() }
    private val handler = Handler(thread.looper)
    private val inFlight = AtomicInteger(0)
    private val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val lock = Object()
    private var videoTrack = -1
    private var audioTrack = -1
    private var muxing = false
    /** finish 之后：两路线程晚到的输出一律丢掉，不再碰 muxer。 */
    private var closed = false
    private val queued = ArrayList<Triple<Boolean, ByteBuffer, MediaCodec.BufferInfo>>()
    private var videoSamples = 0
    private val startNs = System.nanoTime()

    // 视频（只在 thread 上用）
    private val shared = sharedContext
    private var egl: EglBase? = null
    private var encoder: MediaCodec? = null
    private val drawer by lazy { GlRectDrawer() }
    private val frameDrawer by lazy { VideoFrameDrawer() }
    private var width = 0
    private var height = 0
    private var lastPtsUs = -1L

    // 音频
    private val audio = AudioPump(mic)

    fun offer(frame: VideoFrame) {
        if (inFlight.get() >= 2) return   // 编码跟不上就丢帧，不攒延迟
        val now = System.nanoTime()
        frame.retain()
        inFlight.incrementAndGet()
        handler.post {
            try { draw(frame, (now - startNs) / 1000) } catch (_: Throwable) {} finally { frame.release(); inFlight.decrementAndGet() }
        }
    }

    private fun draw(frame: VideoFrame, ptsUs: Long) {
        if (encoder == null) {
            width = frame.rotatedWidth and 1.inv(); height = frame.rotatedHeight and 1.inv()
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, maxOf(width * height * 4, 1_000_000))
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = codec.createInputSurface()
            codec.start()
            encoder = codec
            egl = EglBase.create(shared, EglBase.CONFIG_RECORDABLE).apply { createSurface(surface); makeCurrent() }
        }
        if (ptsUs <= lastPtsUs) return
        lastPtsUs = ptsUs
        val egl = egl ?: return
        egl.makeCurrent()
        android.opengl.GLES20.glClearColor(0f, 0f, 0f, 1f)
        android.opengl.GLES20.glClear(android.opengl.GLES20.GL_COLOR_BUFFER_BIT)
        frameDrawer.drawFrame(frame, drawer, null, 0, 0, width, height)
        egl.swapBuffers(ptsUs * 1000)
        drainVideo(false)
    }

    private fun drainVideo(eos: Boolean) {
        val codec = encoder ?: return
        val info = MediaCodec.BufferInfo()
        val deadline = System.nanoTime() + 2_000_000_000L
        while (true) {
            val i = codec.dequeueOutputBuffer(info, if (eos) 10_000 else 0)
            when {
                i == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!eos || System.nanoTime() > deadline) return
                i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(true, codec.outputFormat)
                i >= 0 -> {
                    val buf = codec.getOutputBuffer(i)
                    if (buf != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) write(true, buf, info)
                    codec.releaseOutputBuffer(i, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    private fun addTrack(video: Boolean, format: MediaFormat) = synchronized(lock) {
        if (closed) return@synchronized
        if (video) videoTrack = muxer.addTrack(format) else audioTrack = muxer.addTrack(format)
        if (videoTrack >= 0 && audioTrack >= 0 && !muxing) {
            muxer.start()
            muxing = true
            queued.forEach { (v, b, i) -> muxer.writeSampleData(if (v) videoTrack else audioTrack, b, i) }
            queued.clear()
        }
    }

    private fun write(video: Boolean, buf: ByteBuffer, info: MediaCodec.BufferInfo) = synchronized(lock) {
        if (closed) return@synchronized
        buf.position(info.offset); buf.limit(info.offset + info.size)
        if (video) videoSamples++
        if (muxing) muxer.writeSampleData(if (video) videoTrack else audioTrack, buf, info)
        else {
            val copy = ByteBuffer.allocateDirect(info.size).put(buf).also { it.flip() }
            queued += Triple(video, copy, MediaCodec.BufferInfo().apply { set(0, info.size, info.presentationTimeUs, info.flags) })
        }
    }

    /** 收尾：两路编码器送 EOS、排空，关 muxer。 */
    fun finish(): File? {
        val done = java.util.concurrent.CountDownLatch(1)
        handler.post {
            runCatching { encoder?.signalEndOfInputStream(); drainVideo(true) }
            runCatching { encoder?.stop(); encoder?.release() }
            if (egl != null) runCatching { frameDrawer.release(); drawer.release(); egl?.release() }
            done.countDown()
        }
        done.await(5, java.util.concurrent.TimeUnit.SECONDS)
        thread.quitSafely()
        audio.stop()
        val ok = synchronized(lock) {
            closed = true
            val stopped = runCatching { if (muxing) muxer.stop() }.isSuccess
            runCatching { muxer.release() }
            stopped && muxing && videoSamples > 0
        }
        if (!ok) { file.delete(); return null }
        return file
    }

    /** 麦克风（或静音）→ AAC 编码器，自己一个线程。时间戳按已编码的采样数推进，起点和视频同一个 startNs。 */
    private inner class AudioPump(private val mic: Boolean) {
        private val rate = 48_000
        private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 96_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
            }, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        @Volatile private var running = true
        private val worker = Thread({ runCatching { run() } }, "capture-audio").apply { start() }

        @SuppressLint("MissingPermission")
        private fun openMic(): AudioRecord? {
            if (!mic) return null
            return runCatching {
                val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                AudioRecord(MediaRecorder.AudioSource.CAMCORDER, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(min, 8192)).takeIf { it.state == AudioRecord.STATE_INITIALIZED }?.apply { startRecording() }
            }.getOrNull()
        }

        private fun run() {
            var rec = openMic()
            val chunk = ShortArray(1024)
            var samples = 0L
            val silence = ShortArray(1024)
            while (running) {
                // 不阻塞地读：有的设备（模拟器没声卡）read 会一卡好几秒。
                val n = rec?.read(chunk, 0, chunk.size, AudioRecord.READ_NON_BLOCKING) ?: 0
                if (n < 0) { runCatching { rec?.stop(); rec?.release() }; rec = null }
                if (n > 0) {
                    encode(chunk, n, samples * 1_000_000L / rate, false)
                    samples += n
                    continue
                }
                // 麦克风没数据（没权限、读失败、被别的录音占着）落后墙钟 0.3 s 以上：补静音，音轨不比视频短。
                val behind = (System.nanoTime() - startNs) * rate / 1_000_000_000L - samples
                if (behind > (if (rec != null) rate * 3L / 10 else silence.size.toLong())) {
                    encode(silence, silence.size, samples * 1_000_000L / rate, false)
                    samples += silence.size
                } else Thread.sleep(10)
            }
            runCatching { rec?.stop(); rec?.release() }
            encode(chunk, 0, samples * 1_000_000L / rate, true)
            runCatching { codec.stop(); codec.release() }
        }

        private fun encode(pcm: ShortArray, n: Int, ptsUs: Long, eos: Boolean) {
            // 等到有空的输入缓冲（期间把输出取走），不丢 PCM：丢了时间戳就会有洞。
            val until = System.nanoTime() + 500_000_000L
            while (System.nanoTime() < until) {
                val i = codec.dequeueInputBuffer(5_000)
                if (i >= 0) {
                    val buf = codec.getInputBuffer(i)!!
                    buf.clear()
                    buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(pcm, 0, n)
                    codec.queueInputBuffer(i, 0, n * 2, ptsUs, if (eos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                    break
                }
                drainAudio(false)
            }
            drainAudio(eos)
        }

        private fun drainAudio(eos: Boolean) {
            val info = MediaCodec.BufferInfo()
            val deadline = System.nanoTime() + 2_000_000_000L
            while (true) {
                val o = codec.dequeueOutputBuffer(info, if (eos) 10_000 else 0)
                when {
                    o == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!eos || System.nanoTime() > deadline) return
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(false, codec.outputFormat)
                    o >= 0 -> {
                        val out = codec.getOutputBuffer(o)
                        if (out != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) write(false, out, info)
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        fun stop() {
            running = false
            worker.join(3000)
        }
    }
}

/** 存进系统相册：Android 10 起走 MediaStore（Pictures/DuckBuddy、Movies/DuckBuddy，不需要权限）；更早的写公共目录再扫描。 */
object Gallery {
    /** Android 9 及以下需要 WRITE_EXTERNAL_STORAGE。 */
    fun needsPermission(ctx: Context) = Build.VERSION.SDK_INT < 29 &&
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED

    fun savePhoto(ctx: Context, jpeg: ByteArray) =
        save(ctx, "DuckBuddy-${System.currentTimeMillis()}.jpg", "image/jpeg", Environment.DIRECTORY_PICTURES,
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI) { it.write(jpeg) }

    fun saveVideo(ctx: Context, file: File) {
        try {
            save(ctx, file.name, "video/mp4", Environment.DIRECTORY_MOVIES, MediaStore.Video.Media.EXTERNAL_CONTENT_URI) { out ->
                FileInputStream(file).use { it.copyTo(out) }
            }
        } finally {
            file.delete()
        }
    }

    private fun save(ctx: Context, name: String, mime: String, dir: String, collection: android.net.Uri,
                     write: (java.io.OutputStream) -> Unit) {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = ctx.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/DuckBuddy")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values) ?: error("insert")
            try {
                resolver.openOutputStream(uri)!!.use(write)
                resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            } catch (e: Throwable) {
                resolver.delete(uri, null, null)
                throw e
            }
        } else {
            if (needsPermission(ctx)) throw SecurityException("WRITE_EXTERNAL_STORAGE")
            @Suppress("DEPRECATION")
            val folder = File(Environment.getExternalStoragePublicDirectory(dir), "DuckBuddy").apply { mkdirs() }
            val out = File(folder, name)
            out.outputStream().use(write)
            MediaScannerConnection.scanFile(ctx, arrayOf(out.absolutePath), arrayOf(mime), null)
        }
    }
}
