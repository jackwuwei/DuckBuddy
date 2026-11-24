import AVFoundation
import CoreImage
import Photos
import WebRTC

/// 机器人画面的拍照（JPEG）和录像（H.264 + AAC 的 MP4）。
///
/// 机器人的 `mediad` 只发视频、不发音频，所以 AAC 音轨录的是手机麦克风；没有麦克风权限时写静音 AAC，
/// 文件格式不变。画面按机器人报的相机安装角度转正：照片直接转像素，视频写进 MP4 的轨道矩阵（不重编码旋转）。
///
/// 它本身就是一个 `RTCVideoRenderer`，挂在视频轨上和屏幕视图并列取帧；演示通道用 `push` 喂 GIF 的帧。
/// 帧、音频和写文件都在自己的串行队列上，不占主线程。
final class VideoCapture: NSObject, RTCVideoRenderer, @unchecked Sendable {
    enum Failure: Error { case noFrame, writer }

    private let queue = DispatchQueue(label: "robot.duckbuddy.capture")
    private let ci = CIContext()
    /// 机器人相机的安装角度（顺时针，度），由 `media.video` 更新。
    private let lock = NSLock()
    private var _mount = 0
    private var _shown = CGSize.zero
    /// 转正后的画面尺寸变了（第一帧、换分辨率、换安装角度）时在主线程回调，供界面按真实比例排版。
    @MainActor var onShownSize: ((CGSize) -> Void)?
    var mountRotation: Int {
        get { lock.withLock { _mount } }
        set { lock.withLock { _mount = newValue } }
    }

    // 以下只在 `queue` 上读写。
    private enum Frame { case rtc(RTCVideoFrameBuffer), pixel(CVPixelBuffer) }
    private var latest: (frame: Frame, rotation: Int)?
    private var writer: Mp4Writer?
    private var mic: MicTap?

    // MARK: RTCVideoRenderer（WebRTC 解码线程调用）

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let rotation = (Int(frame.rotation.rawValue) + mountRotation) % 360
        let buffer = frame.buffer
        let turned = rotation % 180 == 0 ? CGSize(width: Int(frame.width), height: Int(frame.height))
                                         : CGSize(width: Int(frame.height), height: Int(frame.width))
        let changed: Bool = lock.withLock { defer { _shown = turned }; return _shown != turned }
        if changed { Task { @MainActor in self.onShownSize?(turned) } }
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            self.latest = (.rtc(buffer), rotation)
            guard let w = self.writer, let pb = Self.pixelBuffer(.rtc(buffer)) else { return }
            w.append(video: pb, at: t, rotation: rotation)
        }
    }

    /// 演示通道喂帧（已转正的画面，rotation 为 0）。
    func push(_ pixelBuffer: CVPixelBuffer) {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            self.latest = (.pixel(pixelBuffer), 0)
            self.writer?.append(video: pixelBuffer, at: t, rotation: 0)
        }
    }

    // MARK: 拍照

    /// 最新一帧，转正后编码成 JPEG。
    func photo() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                guard let (frame, rotation) = self.latest, let pb = Self.pixelBuffer(frame) else {
                    return c.resume(throwing: Failure.noFrame)
                }
                let image = CIImage(cvPixelBuffer: pb).oriented(Self.orientation(rotation))
                let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let data = self.ci.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                            options: [key: 0.92]) else {
                    return c.resume(throwing: Failure.writer)
                }
                c.resume(returning: data)
            }
        }
    }

    // MARK: 录像

    var isRecording: Bool { queue.sync { writer != nil } }

    /// 开始录像。`withMic` 为 false（没有麦克风权限）时写静音音轨。
    func startRecording(withMic: Bool) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuckBuddy-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        let w = try Mp4Writer(url: url)
        let tap = withMic ? MicTap { [weak self] sample in
            self?.queue.async { self?.writer?.append(audio: sample) }
        } : nil
        queue.sync { writer = w; mic = tap }
        tap?.start()
    }

    /// 停止并收好文件；一帧都没录到时返回 nil。
    func stopRecording() async -> URL? {
        let (w, tap) = queue.sync { () -> (Mp4Writer?, MicTap?) in
            defer { writer = nil; mic = nil }
            return (writer, mic)
        }
        tap?.stop()
        guard let w else { return nil }
        return await withCheckedContinuation { c in
            queue.async { w.finish { c.resume(returning: $0) } }
        }
    }

    // MARK: 帧格式

    /// libwebrtc 的帧 → CVPixelBuffer：硬解出来的 NV12 直接用，其他（I420、带裁剪）转成 NV12。
    private static func pixelBuffer(_ frame: Frame) -> CVPixelBuffer? {
        let b: RTCVideoFrameBuffer
        switch frame {
        case .pixel(let pb): return pb
        case .rtc(let buffer): b = buffer
        }
        if let cv = b as? RTCCVPixelBuffer, cv.cropX == 0, cv.cropY == 0,
           cv.cropWidth == CVPixelBufferGetWidth(cv.pixelBuffer), cv.cropHeight == CVPixelBufferGetHeight(cv.pixelBuffer) {
            return cv.pixelBuffer
        }
        let i420 = b.toI420()
        let w = Int(i420.width), h = Int(i420.height)
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for row in 0..<h { memcpy(y + row * yStride, i420.dataY + row * Int(i420.strideY), w) }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = Int(i420.chromaWidth), ch = Int(i420.chromaHeight)
        for row in 0..<ch {
            let u = i420.dataU + row * Int(i420.strideU), v = i420.dataV + row * Int(i420.strideV)
            let dst = uv + row * uvStride
            for x in 0..<cw { dst[2 * x] = u[x]; dst[2 * x + 1] = v[x] }
        }
        return pb
    }

    /// 顺时针转 `rotation` 度才正的画面。
    private static func orientation(_ rotation: Int) -> CGImagePropertyOrientation {
        switch rotation { case 90: .right; case 180: .down; case 270: .left; default: .up }
    }
}

/// 一个 MP4 文件：H.264 视频轨 + AAC 音轨。只在 `VideoCapture` 的队列上用。
private final class Mp4Writer: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    let url: URL
    private let writer: AVAssetWriter
    private let audioIn: AVAssetWriterInput
    private var videoIn: AVAssetWriterInputPixelBufferAdaptor?
    private var start: CMTime?
    private var lastVideo = CMTime.invalid
    /// 音轨已写到的时刻。麦克风没给数据（没权限、被语音键占着、出错）时用静音补上，AAC 音轨始终和视频一样长。
    private var audioEnd = CMTime.invalid

    init(url: URL) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        audioIn.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioIn) else { throw VideoCapture.Failure.writer }
        writer.add(audioIn)
    }

    /// 第一帧决定画面尺寸和旋转，然后开始写。
    func append(video pb: CVPixelBuffer, at t: CMTime, rotation: Int) {
        if videoIn == nil {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(w * h * 4, 1_000_000),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            input.transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
            guard writer.canAdd(input) else { return }
            writer.add(input)
            videoIn = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: t)
            start = t
            audioEnd = t
        }
        // 时间戳必须严格递增，否则 AVAssetWriter 整个失败。
        guard writer.status == .writing, let adaptor = videoIn, start != nil, !lastVideo.isValid || t > lastVideo else { return }
        if adaptor.assetWriterInput.isReadyForMoreMediaData, adaptor.append(pb, withPresentationTime: t) { lastVideo = t }
        // 麦克风超过 0.3 s 没来数据：静音补到这一帧。
        if (t - audioEnd).seconds > 0.3 { appendSilence(until: t) }
    }

    func append(audio sample: MicTap.Sample) {
        guard writer.status == .writing, audioEnd.isValid else { return }
        let duration = CMTime(value: CMTimeValue(sample.buffer.frameLength), timescale: Int32(Self.sampleRate))
        // 和已写的音频（含补的静音）重叠的就丢掉，时间戳必须往前走。
        guard sample.time >= audioEnd, audioIn.isReadyForMoreMediaData,
              let sb = Self.sampleBuffer(sample.buffer, at: sample.time) else { return }
        if audioIn.append(sb) { audioEnd = sample.time + duration }
    }

    private func appendSilence(until t: CMTime) {
        while audioEnd < t, audioIn.isReadyForMoreMediaData {
            let n = AVAudioFrameCount(min(1024, max(1, Int64((t - audioEnd).seconds * Self.sampleRate))))
            guard let buf = AVAudioPCMBuffer(pcmFormat: Self.pcm, frameCapacity: n) else { return }
            buf.frameLength = n
            memset(buf.int16ChannelData![0], 0, Int(n) * 2)
            guard let sb = Self.sampleBuffer(buf, at: audioEnd), audioIn.append(sb) else { return }
            audioEnd = audioEnd + CMTime(value: CMTimeValue(n), timescale: Int32(Self.sampleRate))
        }
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard writer.status == .writing, lastVideo.isValid else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return done(nil)
        }
        appendSilence(until: lastVideo)
        audioIn.markAsFinished()
        videoIn?.assetWriterInput.markAsFinished()
        writer.finishWriting { [writer, url] in done(writer.status == .completed ? url : nil) }
    }

    /// 48 kHz 单声道 s16 的 PCM → 交给 AAC 编码器的 CMSampleBuffer。
    static func sampleBuffer(_ buf: AVAudioPCMBuffer, at t: CMTime) -> CMSampleBuffer? {
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: buf.format.streamDescription, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &fmt) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(buf.format.sampleRate)),
                                        presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: fmt, sampleCount: CMItemCount(buf.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
              let sb,
              CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: buf.audioBufferList) == noErr
        else { return nil }
        return sb
    }
}

/// 录像用的麦克风：自己的 AVAudioEngine，转成 48 kHz 单声道 s16，时间戳用主机时钟（和视频帧同一个钟）。
private final class MicTap: @unchecked Sendable {
    struct Sample { let buffer: AVAudioPCMBuffer; let time: CMTime }

    private let engine = AVAudioEngine()
    private let onSample: (Sample) -> Void

    init(onSample: @escaping (Sample) -> Void) { self.onSample = onSample }

    func start() {
        let s = AVAudioSession.sharedInstance()
        // 与语音键同一套设置，两边轮流用麦克风时不会互相改掉。
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
        try? s.setActive(true)
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, let converter = AVAudioConverter(from: hw, to: Mp4Writer.pcm) else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [onSample] buffer, when in
            let ratio = Mp4Writer.sampleRate / buffer.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: Mp4Writer.pcm,
                                             frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard out.frameLength > 0, when.isHostTimeValid else { return }
            onSample(Sample(buffer: out, time: CMClockMakeHostTimeFromSystemUnits(when.hostTime)))
        }
        // 起不来（没有输入设备、被占用）就不给数据，写入端自己补静音。
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// 存进系统相册（只要“添加”权限）。
enum PhotoLibrary {
    enum Failure: Error { case denied }

    static func save(photo data: Data) async throws {
        try await authorize()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    static func save(video url: URL) async throws {
        try await authorize()
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    private static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
    }
}
