import AVFoundation
import AudioToolbox

// MARK: 渲染导出
//
// 「渲染，应用插件效果」这条路不借 ffmpeg：ffmpeg 只会把文件里的样本原样搬过去，
// 插件算出来的东西它一个字节也拿不到。所以这里自己搭一台离线的 AVAudioEngine：
// 源文件读一段进来 → pre-gain → 插件链 → 声道推子 → 声像 → 写出文件。
// 走的是 engine.enableManualRenderingMode(.offline) + renderOffline：引擎不碰输出
// 设备，渲染快过实时，也完全不动正在监听的那台（实测：44.1 kHz 立体声 2 s 素材，
// 16/24/32 bit 三档写出来的峰值与延迟位置一致；pre-gain −6 dB、推子 −3 dB 落在
// 0.5 的脉冲上是 0.1774，跟算出来的一样；AUDelay 0.25 s 的回声落在 0.350 s）。

/// 位深。只给这三档。
enum ExportBitDepth: Int, CaseIterable, Identifiable {
    case s16 = 16
    case s24 = 24
    case f32 = 32

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .s16: return "16 bit"
        case .s24: return "24 bit"
        case .f32: return "32 bit float"
        }
    }
    var isFloat: Bool { self == .f32 }
    /// AVAudioFile 的 commonFormat：24 bit 走的是 32 位容器里装 24 位有效位。
    var commonFormat: AVAudioCommonFormat {
        switch self {
        case .s16: return .pcmFormatInt16
        case .s24: return .pcmFormatInt32
        case .f32: return .pcmFormatFloat32
        }
    }
}

enum RenderExportError: LocalizedError {
    case emptyRange
    case nothingToRead
    case noFormat
    case pluginUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyRange: return "范围为空，未能渲染。"
        case .nothingToRead: return "所选范围已越过文件末尾。"
        case .noFormat: return "该音轨采样格式未能建立渲染所用缓冲区。"
        case .pluginUnavailable(let name):
            return "\(name) 未能装载，导出停止。请将其旁通，再渲染导出。"
        }
    }
}

enum RenderExportService {
    /// 一次渲染的全部输入。通道条的数值在这里定格：渲染期间再拧旋钮，已经写出去
    /// 的那一半不受影响 —— 这跟 Logic 的导出一样。
    struct Request {
        var sourceURL: URL
        var start: TimeInterval
        var end: TimeInterval
        var preGainDB: Double
        var faderDB: Double
        var panTicks: Int
        var slots: [SlotSnapshot?]
        var laneBypass: Bool
        var bitDepth: ExportBitDepth
        var outputURL: URL
    }

    private static let renderBlock: AVAudioFrameCount = 4096

    /// 后台队列上跑完整段渲染，进度和结果都回主线程（对话框的进度栏是 @Published，
    /// 在渲染线程上直接改它，SwiftUI 就等着报「从后台线程发布变更」）。
    static func run(_ request: Request,
                    progress: @escaping (Double) -> Void,
                    completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result<URL, Error> {
                try renderNow(request, progress: { fraction in
                    DispatchQueue.main.async { progress(fraction) }
                })
            }
            DispatchQueue.main.async {
                if case .success = outcome {
                    progress(1)          // 落盘了就报满，别让进度条停在最后一格的半途
                    FFmpegService.playCue()
                }
                completion(outcome)
            }
        }
    }

    /// 按给定顺序把几段渲染串起来：前一轨落盘才开始下一轨。两轨同时渲染只会抢
    /// CPU，进度条也看不出走到哪。上报的是总进度。
    static func run(_ requests: [Request],
                    progress: @escaping (Double) -> Void,
                    completion: @escaping (Result<[URL], Error>) -> Void) {
        var done: [URL] = []
        func next(_ index: Int) {
            guard index < requests.count else {
                DispatchQueue.main.async { completion(.success(done)) }
                return
            }
            run(requests[index],
                progress: { fraction in
                    progress((Double(index) + fraction) / Double(requests.count))
                },
                completion: { result in
                    switch result {
                    case .failure(let error): DispatchQueue.main.async { completion(.failure(error)) }
                    case .success(let url):
                        done.append(url)
                        next(index + 1)
                    }
                })
        }
        next(0)
    }

    // MARK: - 命名与容器

    /// 默认文件名：`reMix_原名.扩展名`。
    static func defaultRenderName(sourceURL: URL, bitDepth: ExportBitDepth) -> String {
        "\(defaultStem(sourceURL: sourceURL)).\(containerExtension(for: sourceURL, bitDepth: bitDepth))"
    }

    /// 容器跟着源走，但只在它装得下这个位深的时候：32 bit float 塞不进 AIFF，
    /// mp3/m4a 这类有损容器更留不下插件算出来的样本，一律换成 wav。
    static func containerExtension(for sourceURL: URL, bitDepth: ExportBitDepth) -> String {
        let ext = sourceURL.pathExtension.lowercased()
        switch bitDepth {
        case .f32: return ["wav", "wave", "caf"].contains(ext) ? ext : "wav"
        default: return ["wav", "wave", "aif", "aifc", "aiff", "caf"].contains(ext) ? ext : "wav"
        }
    }

    /// 名字栏填的是「叫什么」，不是「写成什么格式」：路径只取最后一段，扩展名
    /// 由源文件和位深重新决定。两轨同名时给 B 挂个 [B]，不至于互相覆盖。
    static func outputURL(typedName: String,
                          sourceURL: URL,
                          bitDepth: ExportBitDepth,
                          directory: URL,
                          laneTag: String? = nil) -> URL {
        let typed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "/").last ?? ""
        let stem = typed.components(separatedBy: ".").first ?? ""
        let name = stem.isEmpty ? defaultStem(sourceURL: sourceURL) : stem
        let tagged = laneTag.map { "\(name) [\($0)]" } ?? name
        return directory.appendingPathComponent(
            "\(tagged).\(containerExtension(for: sourceURL, bitDepth: bitDepth))")
    }

    private static func defaultStem(sourceURL: URL) -> String {
        "reMix_\(sourceURL.deletingPathExtension().lastPathComponent)"
    }

    // MARK: - 渲染

    private static func renderNow(_ request: Request,
                                  progress: @escaping (Double) -> Void) throws -> URL {
        // 声音取解码好的那份（ogg/opus 这类原容器 AVAudioFile 开不了）；缓存要是刚被
        // 「清除缓存」抹掉，这里就地转回来 —— 这一行本来就在后台队列上，等得起。
        // 命名和容器仍旧按 request.sourceURL 走，见下面的 outputURL。
        let inFile = try AVAudioFile(forReading: AudioFormatCache.resolve(request.sourceURL))
        let inFormat = inFile.processingFormat
        let rate = inFormat.sampleRate
        guard rate > 0 else { throw RenderExportError.noFormat }

        let firstFrame = max(0, AVAudioFramePosition(request.start * rate))
        guard AVAudioFrameCount(max(0, (request.end - request.start) * rate)) > 0 else {
            throw RenderExportError.emptyRange
        }
        let wanted = AVAudioFrameCount(max(0, (request.end - request.start) * rate))
        guard firstFrame < inFile.length else { throw RenderExportError.nothingToRead }
        let frames = min(wanted, AVAudioFrameCount(inFile.length - firstFrame))

        // 读进来的样本按文件自己的格式，再换成渲染格式：AU 只认 float。
        guard let raw = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw RenderExportError.noFormat
        }
        inFile.framePosition = firstFrame
        try inFile.read(into: raw, frameCount: frames)

        guard let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate,
                                               channels: inFormat.channelCount,
                                               interleaved: false) else {
            throw RenderExportError.noFormat
        }
        let fed = try convert(raw, to: renderFormat)

        let chain = try instantiate(request.slots, laneBypass: request.laneBypass)
        let engine = AVAudioEngine()
        // 手动渲染要在碰 mainMixerNode/outputNode 之前打开（Apple 的告诫），
        // 所以创建完就开，接线全在开完以后做。
        try engine.enableManualRenderingMode(.offline, format: renderFormat,
                                             maximumFrameCount: renderBlock)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let pre = AVAudioMixerNode(), fader = AVAudioMixerNode(), pan = AVAudioMixerNode()
        engine.attach(pre); engine.attach(fader); engine.attach(pan)
        pre.outputVolume = AudioEngine.linear(Float(request.preGainDB))
        fader.outputVolume = AudioEngine.linear(max(AudioEngine.laneFaderMinDB,
                                                    min(AudioEngine.laneFaderMaxDB,
                                                        Float(request.faderDB))))
        pan.pan = AudioEngine.panPosition(request.panTicks)

        var tail: AVAudioNode = pre
        for unit in chain {
            engine.attach(unit)
            engine.connect(tail, to: unit, format: renderFormat)
            tail = unit
        }
        engine.connect(player, to: pre, format: renderFormat)
        engine.connect(tail, to: fader, format: renderFormat)
        engine.connect(fader, to: pan, format: renderFormat)
        engine.connect(pan, to: engine.mainMixerNode, format: renderFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: renderFormat)

        let outFile = try makeOutputFile(request: request, rate: rate,
                                         channels: inFormat.channelCount)
        guard let toFile = AVAudioConverter(from: renderFormat, to: outFile.processingFormat)
        else { throw RenderExportError.noFormat }

        player.scheduleBuffer(fed, at: nil, options: [], completionHandler: nil)
        try engine.start()
        player.play()

        guard let chunk = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: renderBlock),
              let encoded = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat,
                                             frameCapacity: renderBlock) else {
            throw RenderExportError.noFormat
        }

        // 插件会留下尾巴（延迟、混响），所以写完这一段再多要 1 秒；尾巴见底就停，
        // 免得给一个干净的导出挂上一秒静音。
        let tailLimit = frames + AVAudioFrameCount(rate)
        var written: AVAudioFrameCount = 0
        while written < tailLimit {
            try engine.renderOffline(renderBlock, to: chunk)
            if chunk.frameLength == 0 { break }
            var provided = false
            var convertError: NSError?
            encoded.frameLength = 0
            let status = toFile.convert(to: encoded, error: &convertError) { _, inputStatus in
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return chunk
            }
            guard status != .error, convertError == nil else {
                throw convertError ?? RenderExportError.noFormat
            }
            try outFile.write(from: encoded)
            written += encoded.frameLength
            progress(min(1.0, Double(written) / Double(tailLimit)))
            if written >= frames, isSilent(chunk) { break }
        }
        player.stop()
        engine.stop()
        engine.disableManualRenderingMode()
        return request.outputURL
    }

    private static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            let values = UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
            for value in values where abs(value) > 1e-6 { return false }
        }
        return true
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format.isEqual(format) { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw RenderExportError.noFormat
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RenderExportError.noFormat
        }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if provided { inputStatus.pointee = .noDataNow; return nil }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { throw error ?? RenderExportError.noFormat }
        return out
    }

    /// 渲染链上的插件按快照重新实例化。引擎里那一台正在监听，同一个节点不能同时
    /// 挂在两台引擎上，所以这里另建一套；参数靠 fullState 搬过来（实测：
    /// AUDelay 183 B，写进去的值取得出来）。
    private static func instantiate(_ slots: [SlotSnapshot?],
                                    laneBypass: Bool) throws -> [AVAudioUnitEffect] {
        var units: [AVAudioUnitEffect] = []
        for case let snapshot? in slots {
            guard let plugin = snapshot.plugin else { continue }
            let semaphore = DispatchSemaphore(value: 0)
            var created: AVAudioUnitEffect?
            switch plugin.kind {
            case .effect:
                AVAudioUnit.instantiate(with: plugin.component, options: []) { unit, _ in
                    created = unit as? AVAudioUnitEffect
                    semaphore.signal()
                }
            case .musicEffect:
                // 与引擎那条路一致：aumf 交给 instantiate 回来的是乐器形状，直接拿描述子
                // 造 AVAudioUnitEffect 才是效果器（实测 Pro-Q 3 两种形状电平都过）。
                created = AVAudioUnitEffect(audioComponentDescription: plugin.component)
                semaphore.signal()
            }
            semaphore.wait()
            guard let unit = created else {
                throw RenderExportError.pluginUnavailable(plugin.name)
            }
            AudioEngine.applyState(snapshot.state, to: unit)
            unit.bypass = laneBypass || snapshot.bypass
            units.append(unit)
        }
        return units
    }

    private static func makeOutputFile(request: Request,
                                       rate: Double,
                                       channels: AVAudioChannelCount) throws -> AVAudioFile {
        try AVAudioFile(forWriting: request.outputURL,
                        settings: [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: rate,
                            AVNumberOfChannelsKey: Int(channels),
                            AVLinearPCMBitDepthKey: request.bitDepth.rawValue,
                            AVLinearPCMIsFloatKey: request.bitDepth.isFloat,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false,
                        ],
                        commonFormat: request.bitDepth.commonFormat,
                        interleaved: true)
    }
}
