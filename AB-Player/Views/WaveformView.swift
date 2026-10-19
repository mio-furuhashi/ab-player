import SwiftUI
import AppKit

// MARK: - WaveformNSView

final class WaveformNSView: NSView {

    static let zoomMax: Float = 200
    private static let scrollbarHeight: CGFloat = 6
    private static let minimumThumbWidth: CGFloat = 24

    // MARK: data & appearance

    var peaks: PeakData = .empty {
        didSet { if peaks.binCount != oldValue.binCount { needsDisplay = true } }
    }
    /// Depth of the vertical axis below full scale, in dB (-12 … -96).
    /// The centre line sits at `floorDB`, the top and bottom edges at 0 dBFS.
    var floorDB: Double = -30 { didSet { needsDisplay = true } }
    /// 这一轨的时间偏移（秒）。包络永远按文件时间存着，画的时候才换算成
    /// 轨内时间：正偏移在头部空出这一段（那里没有样本，画平线），负偏移从文件里
    /// |trim| 秒处起画、尾巴跟着缩短。
    var trimSeconds: Double = 0 { didSet { needsDisplay = true } }
    var splitStereo: Bool = false { didSet { needsDisplay = true } }
    var followPlayhead: Bool = false {
        didSet { if followPlayhead != oldValue { applyFollow(animate: false) } }
    }
    var scrollInverted = false
    /// One wheel notch pans 1/divisor of the visible width.
    var panNotchDivisor: Double = 4
    /// 这一轨在不在播。缓动是给播放用的：位置一秒只到 20 次，摊到显示刷新率上才不阶梯。
    /// 停着的时候这一套反过来碍事 —— 拖进度条、点波形归位都是「指哪儿该是哪儿」，
    /// 让播放头再花约 0.09 s 追上去就成了「不跟手」。所以停着不走缓动，当场吸附。
    var lanePlaying: Bool = true {
        didSet {
            guard lanePlaying != oldValue, !lanePlaying else { return }
            // 暂停那一拍可能还有一段缓动在路上，当场收尾。
            #if DEBUG
            if Self.phLog {
                FileHandle.standardError.write(String(format:
                    "PH 停：画=%.4f 还差=%.3fs 当场吸附\n", Double(shownPlayhead),
                    Double(targetPlayhead - shownPlayhead) * laneSpan).data(using: .utf8)!)
            }
            #endif
            shownPlayhead = targetPlayhead
            applyFollow(animate: false)
            positionPlayhead()
        }
    }
    var tintColor: NSColor = .abGreen { didSet { needsDisplay = true } }

    var onZoomChange: ((Float) -> Void)?
    var onFloorChange: ((Double) -> Void)?

    /// 这一轨在刻度上的跨度（秒）：播放头传进来的是这个长度上的比值，缓动阈值按它换算。
    private var laneSpan: TimeInterval { max(0.0001, peaks.duration + trimSeconds) }

    var playheadPosition: CGFloat = 0 {
        // 位置一秒只到 20 次（走带栏那颗显示定时器），这是「跟随+缩放后播放，动画卡顿、
        // 帧率低」的根：播放头和跟随的视野每 50 ms 硬挪一次，一屏才走 1/3 的像素。
        // 所以小步（播放推进 = 一格 0.05 s）交给 tick 铺成显示刷新率上的斜坡；大步
        // （点击跳转、拖进度条、区间循环回跳）照旧指哪儿是哪儿，不排队、不缓动 ——
        // 「未播放时跳转迅速」这一条没动。
        didSet {
            #if DEBUG
            WaveformNSView.perfPlayheadSets += 1
            #endif
            targetPlayhead = playheadPosition
            // 0.25 s = 五格：掉几拍定时器（开插件窗口那种卡顿）还能靠缓动补回来，
            // 而点击跳转、拖进度条、循环回跳都在秒级，照旧硬切。
            // 停着的那一轨不走缓动：见 `lanePlaying`。
            let chase = lanePlaying && !peaks.isEmpty
                && abs(playheadPosition - shownPlayhead) * laneSpan <= 0.25
            #if DEBUG
            if Self.phLog {
                FileHandle.standardError.write(String(format:
                    "PH 到=%.4f 画=%.4f 差=%+.3fs 播=%d 走=%@\n",
                    Double(playheadPosition), Double(shownPlayhead),
                    Double(playheadPosition - shownPlayhead) * laneSpan, lanePlaying ? 1 : 0,
                    chase ? "缓动" : "吸附").data(using: .utf8)!)
            }
            #endif
            if chase {
                #if DEBUG
                WaveformNSView.perfChases += 1
                #endif
                startTick()
                return
            }
            #if DEBUG
            WaveformNSView.perfSnaps += 1
            #endif
            shownPlayhead = playheadPosition
            applyFollow(animate: false)
            positionPlayhead()
        }
    }

    /// 真正画出去的播放头：`playheadPosition` 是 20 Hz 的台阶，这个由 tick 以 τ 追上去。
    private var shownPlayhead: CGFloat = 0
    private var targetPlayhead: CGFloat = 0

    // MARK: zoom / pan state
    // Log2 space: one wheel notch is the same perceptual step at 1× as at 180×.

    private var zoomLog: Double = 0
    private var targetZoomLog: Double = 0
    private var startRatio: CGFloat = 0
    private var targetStartRatio: CGFloat = 0
    private var barAlpha: CGFloat = 0

    #if DEBUG
    /// 指针探针（AB_POINTER_CHECK）只读这一份视野，量「双指左右 = 画面跟着手指」那一条。
    /// 滚轮翻页那一路只动 target（缓动交给 tick），触控板那一路是手指直给、两个一起动，
    /// 所以两个都要能读到，否则鼠标那一条会被量成「没反应」。
    var debugStartRatio: CGFloat { startRatio }
    var debugTargetStartRatio: CGFloat { targetStartRatio }
    var debugTargetZoomLog: Double { targetZoomLog }
    /// 探针把缓动一步推到目标：滚轮翻页那一路只改 target，交给 timer 才动 start，
    /// 而同一次函数调用里 timer 不会走拍 —— 不推这一步，鼠标那条会被量成「没反应」。
    func debugSnapToTarget() { zoomLog = targetZoomLog; startRatio = targetStartRatio }
    #endif

    /// Screen fraction pinned by the current zoom gesture and the content position
    /// underneath it. While a zoom animates, the start is *derived* from these
    /// rather than interpolated: the anchor then stays exact at every frame and
    /// the `1 - 1/z` clamp never has to fight an eased value (that fight was the
    /// snap you see when zooming in from 1×).
    private var anchorFrac: CGFloat?
    private var anchorContent: CGFloat?

    var horizontalZoom: Float { Float(exp2(zoomLog)) }
    var targetHorizontalZoom: Float { Float(exp2(targetZoomLog)) }

    // MARK: animation

    private var displayTimer: Timer?
    private var lastTick: TimeInterval = 0
    /// Seconds. Each tick closes a fraction of the remaining gap based on elapsed
    /// time, so 60 Hz and 120 Hz screens animate at the same perceived speed.
    /// 0.055 → 0.03：跳到目标点要的时间从 ~0.17 s 缩到 ~0.09 s（95% 收敛 = 3τ），
    /// 播放头跟画面不再拖在后面，但仍有缓冲不至于每下一格都硬切。
    private let tau: Double = 0.03

    private var upperY: [CGFloat] = []
    private var lowerY: [CGFloat] = []

    private var isPanning = false
    private var isDraggingThumb = false
    private var thumbGrabDelta: CGFloat = 0
    /// 捏合起点记在 log2 轴上，识别器的增量直接加在它上面。
    private var pinchStartLog: Double = 0
    private let pinchHandler = PinchHandler()

    private var playheadLayer: CALayer?
    /// 上一拍真正画出去时的视野几何。tick 拿它比对：这一拍视野没动就不标脏，
    /// 免得空转的动画把整幅包络重算一边（Debug 下那是每帧十几毫秒的主线程活）。
    private var drawnStart: CGFloat?
    private var drawnZoom: CGFloat = 1
    private var drawnBar: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let l = CALayer()
        l.backgroundColor = NSColor.barPlayhead.cgColor
        l.isHidden = true
        // 自己加的 sublayer 改 frame 会走 CALayer 默认的 0.25 s 隐式动画。实测 20 Hz 推
        // 位置：模型层已经到 160 px，呈现层才走到 96 px —— 播放头永远差着大半拍，这就是
        // 「波形上的播放头不流畅」。动作表清空，向进度条那根直接画出来的播放头看齐。
        l.actions = [:]
        layer?.addSublayer(l)
        playheadLayer = l
        // 触控板捏合 = 水平缩放。滚轮事件里没有捏合这一路，只能挂识别器。
        let pinch = NSMagnificationGestureRecognizer(target: pinchHandler,
                                                      action: #selector(PinchHandler.handle(_:)))
        pinchHandler.view = self
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { displayTimer?.invalidate() }

    override func layout() {
        super.layout()
        positionPlayhead()
    }

    private func clamped(_ s: CGFloat, zoom z: CGFloat) -> CGFloat {
        min(max(s, 0), max(0, 1 - 1 / z))
    }

    // MARK: zoom

    /// `anchor` is the position across the view (0…1) that must stay put —
    /// normally the cursor, so zooming feels like "zoom toward where I point".
    func setZoom(target: Float, anchor: CGFloat?) {
        let newLog = log2(Double(min(max(target, 1), Self.zoomMax)))
        guard abs(newLog - targetZoomLog) > 0.0001 else { return }
        let curZ = CGFloat(exp2(zoomLog))
        let a = anchor ?? 0.5
        // Pin whatever is under the cursor *right now*, so notches fired mid
        // animation compose instead of jumping back to the previous gesture.
        let content = clamped(startRatio, zoom: curZ) + a / curZ
        anchorFrac = a
        anchorContent = content
        targetZoomLog = newLog
        targetStartRatio = clamped(content - a / CGFloat(exp2(newLog)), zoom: CGFloat(exp2(newLog)))
        startTick()
    }

    private func cancelAnchor() {
        anchorFrac = nil
        anchorContent = nil
    }

    private func startTick() {
        if displayTimer == nil {
            let fps = Double(window?.screen?.maximumFramesPerSecond ?? 60)
            let t = Timer(timeInterval: 1 / max(fps, 30), repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            displayTimer = t
            lastTick = Date.timeIntervalSinceReferenceDate
        }
        #if DEBUG
        // 一次动画的账：起点时刻 + 起点到目标还差多少，收尾时好量「到达目标点」用了多久。
        if Self.followCheckPath != nil, followCheckStart == nil {
            followCheckStart = lastTick
            followCheckGap = abs(targetStartRatio - startRatio)
            followCheckTicks = 0
            FileHandle.standardError.write(String(format: "FOLLOW: 起动画 gap=%.4f 跟随=%d zoom=%.2f\n",
                                                 followCheckGap, followPlayhead ? 1 : 0,
                                                 horizontalZoom).data(using: .utf8)!)
        }
        #endif
    }

    private func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        let dt = max(0.0001, min(0.1, now - lastTick))
        lastTick = now
        let k = CGFloat(1 - exp(-dt / tau))
        #if DEBUG
        WaveformNSView.perfTicks += 1
        #endif

        // 播放头先追：20 Hz 的台阶铺成斜坡之后，跟随的那截视野和那一根线才都是连续的。
        // 这一轨停了就不再追：暂停时缓动可能还剩一截在路上（上面那一步只处理新到的位置），
        // 这里当场收尾，免得定时器那一拍又把播放头往前挪一丝。
        if lanePlaying {
            shownPlayhead += (targetPlayhead - shownPlayhead) * k
            if abs(targetPlayhead - shownPlayhead) < 0.0000005 { shownPlayhead = targetPlayhead }
        } else {
            shownPlayhead = targetPlayhead
        }
        if followPlayhead { applyFollow(animate: false) }
        positionPlayhead()

        zoomLog += (targetZoomLog - zoomLog) * Double(k)
        if let a = anchorFrac, let c = anchorContent {
            let z = CGFloat(exp2(zoomLog))
            startRatio = clamped(c - a / z, zoom: z)
        } else {
            startRatio += (targetStartRatio - startRatio) * k
        }
        let wantBar: CGFloat = targetZoomLog > 0.0001 ? 1 : 0
        barAlpha += (wantBar - barAlpha) * k

        if abs(targetZoomLog - zoomLog) < 0.0005 {
            zoomLog = targetZoomLog
            cancelAnchor()
        }
        if abs(targetStartRatio - startRatio) < 0.00002 { startRatio = targetStartRatio }
        if abs(wantBar - barAlpha) < 0.01 { barAlpha = wantBar }

        // 视野真的动了才重画。以前每一拍都无脑 needsDisplay：顶到边上、或者动画已经收敛
        // 只是定时器还没停的那几拍，也在把整幅包络重算一遍（Debug 下一帧十几毫秒），
        // 播放时两轨一起画就稳不住 60 fps —— 「动画不流畅」的另一半是这里。
        let z = CGFloat(exp2(zoomLog))
        let s = clamped(startRatio, zoom: z)
        let drawNeeded = drawnStart != s || drawnZoom != z || drawnBar != barAlpha
        needsDisplay = drawNeeded
        #if DEBUG
        if followCheckStart != nil { followCheckTicks += 1 }
        if drawNeeded { WaveformNSView.perfND += 1 }
        #endif
        if zoomLog == targetZoomLog, startRatio == targetStartRatio, barAlpha == wantBar,
           shownPlayhead == targetPlayhead {
            displayTimer?.invalidate()
            displayTimer = nil
            #if DEBUG
            if let started = followCheckStart {
                followCheckStart = nil
                let ms = (now - started) * 1000
                appendFollowCheck(String(format: "跨 %.3f 宽的视野：%.0f ms 收敛（%d 拍）\n",
                                         followCheckGap, ms, followCheckTicks))
            }
            #endif
        }
    }

    #if DEBUG
    /// AB_FOLLOW_CHECK=<路径>：把每一次跟随动画的收敛耗时追加到 <路径>.follow。
    /// 探针（同一个环境变量触发）拉 8× 缩放再跳一大段，量的是「播放头到达目标点」
    /// 有多快；平时不开，编译期就没了。
    static var followCheckPath: String? {
        guard let base = ProcessInfo.processInfo.environment["AB_FOLLOW_CHECK"] else { return nil }
        return (base == "1" ? "/tmp/follow" : base) + ".follow"
    }

    private var followCheckStart: TimeInterval?
    private var followCheckGap: CGFloat = 0
    private var followCheckTicks = 0

    private func appendFollowCheck(_ line: String) {
        guard let path = Self.followCheckPath, let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// AB_PLAYHEAD_PERF=<路径>：「跟随 + 水平缩放后播放，动画卡顿、帧率低」这句话里能拿
    /// 数字说的只有三件 —— 一秒画几帧、一帧按住主线程多少毫秒、播放头的值一秒到几次。
    /// 两轨各一枚视图，账记在类上合起来算（同一拍里两帧，主线程付的是两份钱）。
    static var perfPath: String? {
        guard let base = ProcessInfo.processInfo.environment["AB_PLAYHEAD_PERF"] else { return nil }
        return (base == "1" ? "/tmp/playhead" : base) + ".perf"
    }
    static var perfFrames = 0
    static var perfMsSum = 0.0
    static var perfMsMax = 0.0
    static var perfPlayheadSets = 0
    static var perfTicks = 0
    static var perfChases = 0
    static var perfSnaps = 0
    static var perfND = 0
    static var perfLastFollow = -1
    static var perfLastZoom: CGFloat = 0
    static var perfLastStart: CGFloat = -1
    static var perfLastShown: CGFloat = -1
    static var perfLastWidth: CGFloat = 0
    static var perfLastVisible = -1

    /// AB_PEAKLOG：波形「播得响却画不出来」时用的账。装载那一头记峰有没有生成，
    /// 这一头记到了 draw() 还剩多高，两行一对就知道断在哪一环。
    static let peakLog = ProcessInfo.processInfo.environment["AB_PEAKLOG"] != nil

    /// AB_PHLOG：播放头每一拍到几次、每一次走的是缓动还是吸附。
    /// 「暂停后归位不跟手」这句话里没有数字，只有这两条路 —— 量出来才知道断在哪。
    static let phLog = ProcessInfo.processInfo.environment["AB_PHLOG"] != nil

    static func perfReset() {
        perfFrames = 0; perfMsSum = 0; perfMsMax = 0
        perfPlayheadSets = 0; perfTicks = 0; perfChases = 0; perfSnaps = 0; perfND = 0
    }

    static func perfLineAndReset(label: String) -> String {
        let n = perfFrames, sum = perfMsSum, mx = perfMsMax, ph = perfPlayheadSets
        let tk = perfTicks, ch = perfChases, sn = perfSnaps, nd = perfND
        perfReset()
        // 全部走插值，不走 String(format:)：这一支的数字一旦错位就自相矛盾，
        // 而它唯一的用途就是给数字。pid 写在每行上，免得两个进程往同一个文件里抄账。
        return "\(label)[pid \(getpid())]：画 \(n) 帧 · 平均 \(String(format: "%.2f", n > 0 ? sum / Double(n) : 0)) ms/帧"
             + " · 最慢 \(String(format: "%.2f", mx)) ms · 播放头值 \(ph) 次（小步进 \(ch) / 硬跳 \(sn)）"
             + " · tick \(tk) 拍 · 标脏 \(nd) 次 · 上一帧 跟随=\(perfLastFollow) 缩放=\(String(format: "%.2f", perfLastZoom))"
             + " 视野起点=\(String(format: "%.5f", perfLastStart)) 播放头=\(String(format: "%.5f", perfLastShown))"
             + " 宽=\(String(format: "%.0f", perfLastWidth)) 在屏=\(perfLastVisible)\n"
    }
    #endif

    private func applyFollow(animate: Bool) {
        guard followPlayhead else { return }
        let z = CGFloat(exp2(targetZoomLog))
        guard z > 1 else { return }
        let vis = 1 / z
        let margin = vis * 0.08
        let ph = shownPlayhead
        var s = targetStartRatio
        if ph > s + vis - margin { s = ph - vis + margin }
        if ph < s { s = ph }
        s = clamped(s, zoom: z)
        guard s != targetStartRatio else { return }
        cancelAnchor()
        targetStartRatio = s
        if animate { startTick() } else { startRatio = s; needsDisplay = true }
    }

    // MARK: axis transform

    /// Signed sample amplitude → fraction of the lane's half height, on a dB axis.
    private func normalized(_ v: Float) -> CGFloat {
        let a = abs(v)
        guard a > 0 else { return 0 }
        // Values above full scale flatten out, so clipping reads as a flat ceiling.
        let db = 20 * log10(min(Double(a), 1.0))
        let f = max(-96.0, min(-12.0, floorDB))
        return CGFloat(max(0, min(1, (db - f) / -f)))
    }

    /// The view is non-flipped (y grows upward), so the top lane is the one at larger y.
    private func laneChannelRanges() -> [(channels: Range<Int>, rect: NSRect)] {
        let ch = peaks.channelCount
        if splitStereo && ch == 2 {
            let h = bounds.height / 2
            return [(0..<1, NSRect(x: 0, y: h, width: bounds.width, height: h)),
                    (1..<2, NSRect(x: 0, y: 0, width: bounds.width, height: h))]
        }
        return [(0..<max(1, ch), bounds)]
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        // 播放头帧率探针（AB_PLAYHEAD_PERF）：这一帧在主线程按住多久，只有它自己知道。
        let perfT0 = Date.timeIntervalSinceReferenceDate
        defer {
            let ms = (Date.timeIntervalSinceReferenceDate - perfT0) * 1000
            WaveformNSView.perfFrames += 1
            WaveformNSView.perfMsSum += ms
            if ms > WaveformNSView.perfMsMax { WaveformNSView.perfMsMax = ms }
            // 只有真正画得出东西的那一帧才留快照：SwiftUI 新建视图时先来一帧宽 0 的，
            // 拿它当「画那一帧时的状态」会把账带歪。
            if bounds.width > 1 {
                WaveformNSView.perfLastFollow = followPlayhead ? 1 : 0
                WaveformNSView.perfLastZoom = CGFloat(exp2(zoomLog))
                WaveformNSView.perfLastStart = startRatio
                WaveformNSView.perfLastShown = shownPlayhead
                WaveformNSView.perfLastWidth = bounds.width
                WaveformNSView.perfLastVisible = (window?.occlusionState.contains(.visible) ?? false) ? 1 : 0
            }
        }
        #endif
        super.draw(dirtyRect)
        NSColor.barWaveform.setFill()
        NSBezierPath.fill(bounds)
        guard !peaks.isEmpty, bounds.width > 1 else { return }

        let z = CGFloat(exp2(zoomLog))
        let s = clamped(startRatio, zoom: z)
        drawnStart = s
        drawnZoom = z
        drawnBar = barAlpha
        let binCount = peaks.binCount
        let width = Int(bounds.width)
        guard width > 0 else { return }

        if upperY.count != width {
            upperY = [CGFloat](repeating: 0, count: width)
            lowerY = [CGFloat](repeating: 0, count: width)
        }

        // 轨内比值 → 文件比值的两个数：scale = 刻度长 / 文件长，head = 头部空出来的那段
        // 占刻度的比值。trim 为 0 时 scale=1、head=0，和从前一模一样。
        let fileSpan = max(0.0001, peaks.duration)
        let scale = CGFloat((fileSpan + CGFloat(trimSeconds)) / fileSpan)
        let head = CGFloat(trimSeconds / fileSpan)
        let firstBin = (s * scale - head) * CGFloat(binCount)
        let binsPerPixel = scale / z * CGFloat(binCount) / bounds.width

        for (channelRange, rect) in laneChannelRanges() {
            let midY = rect.midY
            let half = rect.height / 2
            #if DEBUG
            var logLevel: Float = 0
            #endif

            for x in 0..<width {
                let raw0 = floor(firstBin + CGFloat(x) * binsPerPixel)
                let raw1 = ceil(firstBin + CGFloat(x + 1) * binsPerPixel)
                // 整列落在文件之外（正偏移空出来的头部，或负偏移之外的尾巴）：画中线，
                // 不能让第 0 格或最后一格的包络横向摊过去填白。
                if raw1 <= 0 || raw0 >= CGFloat(binCount) {
                    upperY[x] = midY
                    lowerY[x] = midY
                    continue
                }
                let b0 = min(max(Int(raw0), 0), binCount - 1)
                let b1 = min(max(Int(raw1), b0 + 1), binCount)

                var colMin: Float = 1
                var colMax: Float = -1
                for ch in channelRange where ch < peaks.minEnv.count {
                    let lo = peaks.minEnv[ch]
                    let hi = peaks.maxEnv[ch]
                    var mn: Float = 1
                    var mx: Float = -1
                    // 整条包络一帧要过几百万个格子。平时这不是事（实测 Release 播放时主线程
                    // 99% 在等事件），但 Debug 构建里 `lo[i]` 和 `for i in a..<b` 每次都走
                    // 一遍带分配的泛型下标，一帧就成了 600 ms —— 主线程被按住的这 600 ms
                    // 里电平表和光标全部饿死。换成裸指针 + while，两相都只多这一层。
                    lo.withUnsafeBufferPointer { loB in
                        hi.withUnsafeBufferPointer { hiB in
                            var i = b0
                            while i < b1 {
                                if loB[i] < mn { mn = loB[i] }
                                if hiB[i] > mx { mx = hiB[i] }
                                i += 1
                            }
                        }
                    }
                    if mn < colMin { colMin = mn }
                    if mx > colMax { colMax = mx }
                }
                #if DEBUG
                if abs(colMax) > logLevel { logLevel = abs(colMax) }
                if abs(colMin) > logLevel { logLevel = abs(colMin) }
                #endif

                upperY[x] = midY + normalized(max(0, colMax)) * half
                lowerY[x] = midY - normalized(min(0, colMin)) * half
            }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: upperY[0]))
            for x in 1..<width { path.line(to: NSPoint(x: CGFloat(x), y: upperY[x])) }
            for x in stride(from: width - 1, through: 0, by: -1) {
                path.line(to: NSPoint(x: CGFloat(x), y: lowerY[x]))
            }
            path.close()
            tintColor.withAlphaComponent(0.6).setFill()
            path.fill()
            #if DEBUG
            // AB_PEAKLOG 的第二本账：包络到了这一层还剩多高。画不出东西时用它分清
            // 「没收到峰」「收到了但全被 dB 轴压成 0」「在但没上色」。
            if Self.peakLog {
                FileHandle.standardError.write(String(format: "DRAW w=%.0f h=%.0f bins=%d ch=%d 道=%d 最高=%.4f dB底=%.0f → %.4f\n",
                                                      bounds.width, bounds.height, peaks.binCount,
                                                      peaks.channelCount, channelRange.count,
                                                      logLevel, floorDB, normalized(logLevel)).data(using: .utf8)!)
            }
            #endif
        }

        if barAlpha > 0.01 { drawScrollbar(zoom: z, start: s) }
        positionPlayhead()
    }

    private func thumbRect(zoom z: CGFloat, start s: CGFloat) -> NSRect {
        let h = Self.scrollbarHeight
        let thumbW = max(Self.minimumThumbWidth, bounds.width / z)
        let limit = max(0, bounds.width - thumbW)
        return NSRect(x: min(max(s * bounds.width, 0), limit), y: 1, width: thumbW, height: h - 2)
    }

    private func drawScrollbar(zoom z: CGFloat, start s: CGFloat) {
        let h = Self.scrollbarHeight
        let track = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        NSColor(white: 1, alpha: 0.07 * barAlpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()

        let thumb = thumbRect(zoom: z, start: s)
        NSColor(white: 1, alpha: 0.38 * barAlpha).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: (h - 2) / 2, yRadius: (h - 2) / 2).fill()
    }

    /// 播放头落在哪一像素：用的是和 draw() 同一组视野参数，所以它永远贴在画出来的那一份上，
    /// 不会像以前那样拿「上一次画完」的值去对「已经在动的位置」，看着就是慢半拍。
    private func positionPlayhead() {
        guard let l = playheadLayer else { return }
        let z = CGFloat(exp2(zoomLog))
        let s = clamped(startRatio, zoom: z)
        let px: CGFloat = peaks.isEmpty
            ? shownPlayhead * bounds.width
            : (shownPlayhead - s) * z * bounds.width
        l.isHidden = px < -2 || px > bounds.width + 2
        l.frame = NSRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height)
    }

    // MARK: gestures

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags
        let sign: CGFloat = scrollInverted ? -1 : 1
        // 触控板那一路竖向反一次（「都反」）：两指往上 = 缩放加、深度加。
        let up = PointerInput.up(event) * sign > 0

        if mods.contains([.option, .command]) {
            setZoom(target: Float(exp2(targetZoomLog + (up ? 0.2 : -0.2))), anchor: cursorFraction())
            onZoomChange?(targetHorizontalZoom)
        } else if mods.contains(.command) {
            let depth = max(12, min(96, -floorDB * (up ? 1.15 : 1 / 1.15)))
            onFloorChange?(-depth)
        } else if PointerInput.detect(event) == .trackpad {
            // 触控板：滚轮那套「一格翻 1/divisor」整个让掉，改成双指
            // 左右滑 = 画面跟着手指走，和浏览器里的行为一致。
            guard targetHorizontalZoom > 1.001 else { return }
            let dx = event.scrollingDeltaX * sign
            guard abs(dx) > 0.001 else { return }
            cancelAnchor()
            let z = CGFloat(exp2(targetZoomLog))
            targetStartRatio = clamped(targetStartRatio - dx / (z * max(bounds.width, 1)), zoom: z)
            startRatio = targetStartRatio
            needsDisplay = true
        } else if horizontalZoom > 1.001 {
            // One notch = 1/divisor of the visible width; scrolling up looks toward the end.
            let step = CGFloat(1 / (panNotchDivisor * exp2(targetZoomLog)))
            cancelAnchor()
            targetStartRatio = clamped(targetStartRatio + (up ? step : -step),
                                       zoom: CGFloat(exp2(targetZoomLog)))
            startTick()
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// 捏合的锚点：手指中心落在视图的哪一分（0…1），缩放时那一点钉住不动。
    private func pinchAnchor(_ gesture: NSGestureRecognizer) -> CGFloat {
        let p = gesture.location(in: self)
        return min(max(p.x / max(bounds.width, 1), 0), 1)
    }

    fileprivate func applyPinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartLog = targetZoomLog
        case .changed:
            // AppKit 给的量是「相对起点的放大率」，1.0 = 张到两倍。它落在 log2 轴上正好是
            // 每张开一倍，和滚轮那套等倍率手感同一把尺。
            setZoom(target: Float(exp2(pinchStartLog + Double(gesture.magnification))),
                    anchor: pinchAnchor(gesture))
            onZoomChange?(targetHorizontalZoom)
        default:
            break
        }
    }

    private func cursorFraction() -> CGFloat {
        guard let w = window else { return 0.5 }
        let local = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        return min(max(local.x / max(bounds.width, 1), 0), 1)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let z = CGFloat(exp2(zoomLog))
        if barAlpha > 0.3, p.y <= Self.scrollbarHeight {
            let t = thumbRect(zoom: z, start: clamped(startRatio, zoom: z))
            if t.contains(p) {
                isDraggingThumb = true
                thumbGrabDelta = p.x - t.minX
            } else {
                // Click on the gutter: slide the thumb so its centre lands there.
                cancelAnchor()
                targetStartRatio = clamped((p.x - t.width / 2) / max(bounds.width, 1), zoom: z)
                startTick()
            }
            return
        }
        guard horizontalZoom > 1 else { return }
        isPanning = true
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let z = CGFloat(exp2(targetZoomLog))
        cancelAnchor()
        if isDraggingThumb {
            let p = convert(event.locationInWindow, from: nil)
            let t = thumbRect(zoom: z, start: clamped(targetStartRatio, zoom: z))
            let limit = max(0, bounds.width - t.width)
            targetStartRatio = clamped(min(max(p.x - thumbGrabDelta, 0), limit) / max(bounds.width, 1), zoom: z)
            startRatio = targetStartRatio
            needsDisplay = true
            return
        }
        guard isPanning else { return }
        // Image follows the pointer exactly: screen x = (content - start) * z * width
        let s = startRatio - CGFloat(event.deltaX) / (z * max(bounds.width, 1))
        startRatio = clamped(s, zoom: z)
        targetStartRatio = startRatio
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            NSCursor.pop()
        }
        isDraggingThumb = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if horizontalZoom > 1 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func resetView() {
        zoomLog = 0
        targetZoomLog = 0
        startRatio = 0
        targetStartRatio = 0
        barAlpha = 0
        cancelAnchor()
        needsDisplay = true
    }
}

// MARK: - WaveformView (SwiftUI wrapper)

/// 捏合手势的靶子。AppKit 的识别器只认 target-action，而识别器由视图自己持有 ——
/// 拿视图当目标就成了「视图 → 识别器 → 视图」一圈强引用，所以隔一层弱引用。
final class PinchHandler: NSObject {
    weak var view: WaveformNSView?
    @objc func handle(_ gesture: NSMagnificationGestureRecognizer) { view?.applyPinch(gesture) }
}

struct WaveformView: NSViewRepresentable {
    let peaks: PeakData
    let floorDB: Double
    let horizontalZoom: Float
    let playheadPosition: CGFloat
    let tintColor: NSColor
    var splitStereo = false
    var followPlayhead = false
    var scrollInverted = false
    var panNotchDivisor: Double = 4
    var lanePlaying: Bool = true
    var trimSeconds: Double = 0
    var onZoomChange: ((Float) -> Void)?
    var onFloorChange: ((Double) -> Void)?

    func makeNSView(context: Context) -> WaveformNSView {
        let view = WaveformNSView()
        view.peaks = peaks
        view.floorDB = floorDB
        view.trimSeconds = trimSeconds
        view.splitStereo = splitStereo
        view.followPlayhead = followPlayhead
        view.scrollInverted = scrollInverted
        view.panNotchDivisor = panNotchDivisor
        view.lanePlaying = lanePlaying
        view.tintColor = tintColor
        view.onZoomChange = onZoomChange
        view.onFloorChange = onFloorChange
        if horizontalZoom != 1 { view.setZoom(target: horizontalZoom, anchor: nil) }
        return view
    }

    func updateNSView(_ nsView: WaveformNSView, context: Context) {
        let changedContent = nsView.peaks.binCount != peaks.binCount
        nsView.peaks = peaks
        // 这一层每 20 Hz 被 SwiftUI 走一遍，而 `floorDB/splitStereo/tintColor` 的观察器
        // 只要被赋值就标脏（值没变也标）——于是波形一秒重画 20 整幅包络，Debug 实测
        // 8 ms/帧、白付 16% 主线程。先比值再赋，把这一笔抹掉。
        if nsView.floorDB != floorDB { nsView.floorDB = floorDB }
        if nsView.trimSeconds != trimSeconds { nsView.trimSeconds = trimSeconds }
        if nsView.splitStereo != splitStereo { nsView.splitStereo = splitStereo }
        nsView.followPlayhead = followPlayhead
        nsView.scrollInverted = scrollInverted
        nsView.panNotchDivisor = panNotchDivisor
        if nsView.lanePlaying != lanePlaying { nsView.lanePlaying = lanePlaying }
        if nsView.tintColor != tintColor { nsView.tintColor = tintColor }
        nsView.onZoomChange = onZoomChange
        nsView.onFloorChange = onFloorChange
        if changedContent { nsView.resetView() }
        if abs(Double(horizontalZoom) - Double(nsView.targetHorizontalZoom)) > 0.01 {
            nsView.setZoom(target: horizontalZoom, anchor: nil)
        }
        nsView.playheadPosition = playheadPosition
        if nsView.horizontalZoom <= 1 {
            nsView.window?.invalidateCursorRects(for: nsView)
        }
    }
}
