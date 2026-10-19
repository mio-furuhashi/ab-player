import AppKit
import AVFoundation
import CoreMedia
import Combine

// MARK: 视频窗口
//
// 2.2.0 只做单画面：一扇独立窗口（照混音器那一套 utility panel，主窗口照常能用），
// 里面摆当前那一轨的画面。A/B 各一台静音 AVPlayer，按 F 换轨只换画面、不动时钟；
// 画面直接跳变，不做淡入淡出。同步靠两件事：半帧以内算追平；半帧到 0.25 s 只拿 ±3% 以内的
// 调速追（播中 seek 有自己的 0.1 s 代价，见 `correctDrift`），超过 0.25 s 才落一次 seek；
// 播放头被拖走（20 Hz 那一拍量出不连续跳变）或这一轨停了就当场吸附。编辑模式与 ABX 整块无效。
//
// 加了一档「无缝切换视频轨」（设置里，默认开）：黑帧的来路不是「只开了一条流」
// —— 两台播放器、两支 item 本来就各活各的，黑的是换轨那一下 `align()` 的零容差 seek，一台
// 从没渲染过帧的暂停播放器在 seek 落地前 layer 上没帧可画。所以这一档把画面改成两层常驻
// （`VideoSurface`），看不见那一轨也挂着自己的播放器、由 `warm` 那一拍（0.25 s）提前摆准，
// 换轨只把它的层提到上头，摆着那一轨一个 seek 都不落（实测两次换轨各 0 次，帧距 −0.5…+1.3 帧；
// 老办法同样两下各落 1…2 次 seek，暂停中那一档帧距 +49 帧）。
// 养的参照不是引擎报的那个数而是「观众刚看到的那一张」（`mirrored`）：一次播中 seek 自己会把
// 那一轨甩到引擎后面约 0.1 s，那一截两轨是共同的，拿引擎当尺子就会在换轨这一下再落一次 seek。
// 代价是两台解码器同时干活 —— 那句话写在设置里。

// MARK: 视频参数

/// 信息面板「视频」那一列要的五格，外加「这文件有没有画面」；帧率和宽高另存一份数值，
/// 同步那套要拿半帧当容差，不能去解析显示字符串。
/// 和 codecNames 同一类旁账：不进轨道、不进撤销快照、不写工程文件，谁要显示谁现读。
struct VideoFacts: Equatable {
    var hasVideo = false
    /// 画面和声音在同一个文件里，所以这一格和音频那一列的「容器」是同一个值 ——
    /// 表按栏目立两列，各报各的，不去猜要不要省。
    var container = "—"
    /// fourcc 认出来的显示名（H.264 / HEVC / ProRes …），认不出原样吐四个字母。
    var codec = "—"
    var bitrate = "—"
    /// 同一个文件里那条音轨自己的码率。带画面的容器不能用「文件字节数 ÷ 时长」报音频码率
    /// —— 那把视频那 1.8 Mbps 也算进去了（实测 1stclip.mp4 音频轨 137 kbps，按容器算是 2014）。
    /// 只有读了视频轨才有这一格，读不到就还是按容器那本账。
    var audioBitrate: String?
    var frameRate = "—"
    var colour = "—"
    var fps: Double = 0
    var width: Double = 0
    var height: Double = 0
}

enum VideoProbe {
    /// 一次 `AVURLAsset` 数轨。没有视频轨就回 `hasVideo = false` 的那一份（值类型，
    /// 调用方按 hasVideo 判，不必管剩下几格）。
    static func read(from url: URL) -> VideoFacts {
        let asset = AVURLAsset(url: url)
        guard let video = asset.tracks(withMediaType: .video).first,
              let desc = (video.formatDescriptions as? [CMFormatDescription])?.first else {
            return VideoFacts()
        }
        var facts = VideoFacts(hasVideo: true)
        facts.container = "." + url.pathExtension.lowercased()
        facts.codec = codecName(CMFormatDescriptionGetMediaSubType(desc))
        facts.colour = colourName(desc)
        // 帧率：`nominalFrameRate` 是 23.976 这种带零头的标称值。可变帧率它给平均，
        // 这一版不区分（QuickTime 家族里 VFR 少见，真撞上再补 totalFrameRate）。
        let fps = Double(video.nominalFrameRate)
        if fps > 0 {
            facts.fps = fps
            facts.frameRate = "\(trim(fps)) fps"
        }
        let rate = video.estimatedDataRate
        if rate > 0 { facts.bitrate = "\(Int((rate / 1000).rounded())) kbps" }
        // 音频那一格的码率：同一次数轨顺手读，不再另开一份 asset。
        if let audio = asset.tracks(withMediaType: .audio).first, audio.estimatedDataRate > 0 {
            facts.audioBitrate = "\(Int((audio.estimatedDataRate / 1000).rounded())) kbps"
        }
        // 竖拍带旋转的文件：naturalSize 是旋转前的，窗口按转过来那一版摆。
        let raw = video.naturalSize
        let angle = atan2(video.preferredTransform.b, video.preferredTransform.a)
        if abs(abs(angle) - .pi / 2) < 0.01 {
            facts.width = raw.height
            facts.height = raw.width
        } else {
            facts.width = raw.width
            facts.height = raw.height
        }
        return facts
    }

    /// 视频编码的显示名走行业写法（大写加点），和音频那一格 `codecName` 不是一套口径。
    static func codecName(_ subType: OSType) -> String {
        let raw = PluginCatalog.string(subType).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        switch raw {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco", "pro4": return "ProRes"
        case "jpeg": return "JPEG"
        default: return raw.isEmpty ? "—" : raw
        }
    }

    /// 色域问格式描述的扩展字典。文件写明了 primaries（colr 那一箱）就用它；没写就退一步
    /// 看 YCbCr 矩阵 —— 实测 QuickTime 导出的 1080p 十有八九只写矩阵：primaries 是 nil、
    /// 矩阵是 "ITU_R_709_2"（ffprobe 那行 `color_space=bt709` 说的就是它，IINA 报的 BT.709
    /// 也是它）。这一档矩阵在这批容器里对应的就是那一档原色，报出来；两样都没有才是「—」。
    static func colourName(_ desc: CMFormatDescription) -> String {
        for key in [kCMFormatDescriptionExtension_ColorPrimaries as CFString,
                    kCMFormatDescriptionExtension_YCbCrMatrix as CFString] {
            if let value = CMFormatDescriptionGetExtension(desc, extensionKey: key),
               let raw = value as? String, !raw.isEmpty { return colourShortName(raw) }
        }
        return "—"
    }

    /// 系统给的是 "ITU_R_709_2" 这一串，面板那一格只有 80 pt，留短名。
    private static func colourShortName(_ raw: String) -> String {
        if raw.contains("709") { return "bt709" }
        if raw.contains("2020") { return "bt2020" }
        if raw.contains("601") || raw.contains("625") || raw.contains("525") { return "bt601" }
        if raw.lowercased().contains("p3") { return "Display P3" }
        guard let open = raw.firstIndex(of: "(") else { return raw }
        return String(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)])
    }

    /// 23.976 留三位、24/25 不带小数：先写三位，再砍尾巴上的 0。
    private static func trim(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text = String(text.dropLast()) }
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}

// MARK: 画面那一格

/// 只干一件事：在视图自己的 layer 上挂两层 `AVPlayerLayer`，A/B 各一层。`resizeAspect`
/// 自带信箱，窗口怎么拉都不变形。没画面那一轨由 `VideoEmptyView` 盖在上面，不画在这层里。
/// 这里是挂 sublayer 而不是 UIKit 那句 `override class var layerClass` —— AppKit 的
/// `NSView` 没有这个覆写点（SDK 头文件里查不到 layerClass），只能自己加一层、自己跟帧。
///
/// 是两层不是一层：无缝换轨的办法是「看不见那一轨也照常出帧」，换轨只把
/// 它的层提到上头，所以两台播放器各占一层、都常驻。中间垫一层不透明黑（`occluder`）——
/// `resizeAspect` 只把画面画在等宽等高的那块矩形里，信箱那两条是**透明**的，不垫这一层，
/// 上面那轨的黑边里会透出下面那轨的画面。谁在上头用 `zPosition` 说：2 = 摆着的那一轨，
/// 1 = 黑垫，0 = 看不见的那一轨。
private final class VideoSurface: NSView {
    private let layerA = AVPlayerLayer()
    private let layerB = AVPlayerLayer()
    private let occluder = CALayer()
    /// 眼下摆的是哪一轨（nil = 两层都压在黑垫底下，摆占位那一档）。
    private(set) var shown: TrackSide?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        occluder.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(occluder)
        for (side, playerLayer) in [(TrackSide.a, layerA), (.b, layerB)] {
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
            playerLayer.zPosition = side == .a ? 2 : 0
        }
        occluder.zPosition = 1
        shown = .a
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func playerLayer(_ side: TrackSide) -> AVPlayerLayer { side == .a ? layerA : layerB }

    /// 提到上头。整块放在一个关动作的事务里：`zPosition` 默认有 0.25 s 的隐式动画，
    /// 让它走成动画就是一次「淡入」，不是要的（规格说画面直接跳变、不做淡入淡出）。
    ///
    /// 试过给压在底下那一层再加一道 `isHidden`（理由是「Core Animation 照样每帧把
    /// 它那一份 3840×2160 合成进窗口」）：实测没有这一说的钱 —— 同一条流那三趟
    /// （合流时两层挂同一台播放器） hides/不 hides 都是 实时率 1.06…1.08、硬 seek 6 次/10 s；
    /// 两份不同文件（两台解码器）那两趟更是对不上口径（按下不表那一趟反而 0.95）。
    /// 没有证据的开销不进代码，这一条回到只有 `zPosition` 的样子。
    func show(_ side: TrackSide?) {
        shown = side
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerA.zPosition = side == .a ? 2 : 0
        layerB.zPosition = side == .b ? 2 : 0
        occluder.zPosition = side == nil ? 2 : 1
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let bounds = layer?.bounds ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for playerLayer in [layerA, layerB] { playerLayer.frame = bounds }
        occluder.frame = bounds
        CATransaction.commit()
    }
}

/// 黑底 + 中间一行灰字（「这一轨没有画面」那一档）。
private final class VideoEmptyView: NSView {
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor.secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String) { label.stringValue = text }
}

// MARK: 窗口与同步

final class VideoPanelController: NSObject {
    static let shared = VideoPanelController()
    private(set) var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    /// 两台静音播放器各绑一轨，从头到尾活着（关窗才拆）：换轨只是换 layer 上的 player，
    /// 所以 F 下去没有「等它起来」那一下，画面直接跳变。
    private let playerA = VideoPanelController.makePlayer()
    private let playerB = VideoPanelController.makePlayer()
    private weak var vm: PlayerViewModel?
    private var surface: VideoSurface?
    private var empty: VideoEmptyView?
    private var cancellables: Set<AnyCancellable> = []
    private var driftTimer: Timer?
    /// 无缝那一档下养看不见那一轨的那一拍（0.25 s，见 `warmTick`）。
    private var warmTimer: Timer?
    /// 已经挂过 item 的那份地址，用来认出「这一轨换曲了」。
    private var boundURL: [TrackSide: URL] = [:]
    /// 20 Hz 那一拍留下的上一次的轨内位置，用来认播放头被拖走。
    private var lastLane: [TrackSide: TimeInterval] = [:]
    /// 上一拍的播放状态：只用来认出「起播那一下」，那一下要额外吸附一次。
    private var wasPlaying: [TrackSide: Bool] = [:]
    /// 最近一次硬 seek 把它摆去了哪儿、什么时候摆的。无缝那一档要拿它当「观众此刻看到的
    /// 那一张帧」—— 刚落下去的 seek 还没轮到播放器上报，`currentTime()` 读回来的是上一秒
    /// 那个过期值，照着它去摆看不见那一轨，换轨就跳一大截（实测 −0.28 s ≈ −6.7 帧）。
    private var lastPlaced: [TrackSide: Double] = [:]
    /// 上一份画面的像素宽高：换轨时的尺子。「窗口 = 画面大小」只在第一次有画面那一趟
    /// 成立，之后窗口的大小归用户，换到另一份画面只照这一份相对上一份的差别去调
    /// （见 `fitWindow`）。重启后它从记忆里读回来，所以关机再开也是「调」而不是「重摆」。
    private var lastPicture: NSSize?
    /// 已经按哪一份文件摆过一次了，用来认出「这一轨换曲了」——同一份文件再摆会把用户
    /// 手动拖好的尺寸抹掉。
    private var fittedFor: String?
    /// 这一轨刚挂上的新 item 还没报状态 —— 挂着它的这段时间里这一轨谁都不能碰：摆位、
    /// 追差、跟播放状态全跳过（见 `align` / `reconcile` / `followPlayState` / `mirrored`）。
    /// 对一支没就绪的 item 落 seek，摆上去的就是黑的，那一趟还追不完。
    private var pendingItem: [TrackSide: AVPlayerItem] = [:]
    /// 上面那份的装载回话（KVO）。换曲抢了先要把这一眼关掉，不然旧的回调会来摆新曲的画面。
    private var pendingWatch: [TrackSide: NSKeyValueObservation] = [:]
    /// 两轨是不是正在走同一条流（同一份文件、位置又对得上）。「是」的时候两层画面都出自
    /// A 那一台播放器，B 那一台闲着（见 `player(_:)`）。
    ///
    /// 重负载量的账：这台机器同时解两条 4K60 只能跑到约 0.66 倍速 —— 无缝开着实测
    /// 22 次硬 seek/10 s、摆着那一轨 10/40 拍表停住；同一份材料只跑一条是 3 次/0 拍。
    /// 追差的三档无论怎么定档都在这两者之间挑（追得紧 = 一堆硬 seek = 一顿一顿，追得松 =
    /// 摆着那一轨长期落后半秒以上）。而两轨画的本来就是同一张：省掉那一台多余的解码器，
    /// 摆着的那一轨回到跑得动的档位，换轨更是没什么可换 —— 所谓「无缝」在这一档是白送的。
    private var sharing = false
    /// 进这一档的线，和退出的线分开设（迟滞）：两轨的位置本来就在几毫秒里晃，一条线会来回抖，
    /// 抖一次就是两层换一次手、B 那一台歇了又起。进 ≤ 0.034 s（60 fps 两帧、30 fps 一帧），
    /// 出 > 0.10 s（6 帧）—— 真被拖开了才收摊。
    private static let shareEnter = 0.034
    private static let shareExit = 0.10
    /// 差过这个数才硬落一次 seek（画面要愣 0.05…0.15 s，见 `correctDrift`）。
    private static let hardSeekTolerance = 0.25
    #if DEBUG
    /// 量档子用的临时口子（`AB_SEEK_BAND=0.5`）：重负载下那一次 seek 自己吃 0.22…0.38 s，
    /// 比触发它的那条线还长，追差就成了自激。量完把定下来的数落回上一行，这一条删掉。
    #endif
    private static let seekBand: Double = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["AB_SEEK_BAND"], let value = Double(raw) {
            return value
        }
        #endif
        return hardSeekTolerance
    }()
    /// 小差靠调速追：速率偏差 = 差 / 这个常数，上下封 3%。差 0.09 s 就是 3%，两三秒追平。
    private static let catchUpTimeConstant = 3.0
    private static let catchUpRateLimit = 0.03
    /// 看不见那一轨（无缝那一档）追帧距用的档子：那一层压在黑垫底下，速率临时偏 20% 谁也
    /// 看不见，而 ±3% 追 0.13 s 要四秒多 —— F 落在这几秒里就照样跳帧。0.6 s 的常数配上
    /// 0.25 s 那一拍（见 `warmTimer`），一两秒内把一帧以内的差收掉，环益 0.25/0.6 < 1 不至于振铃。
    private static let warmTimeConstant = 0.6
    private static let warmRateLimit = 0.20
    /// `warmTick` 的间隔。环益 = 间隔 / `warmTimeConstant`，必须小于 1 才不会振铃。
    private static let warmCadence = 0.25
    #if DEBUG
    /// 落硬 seek 的次数，探针要读它（播中稳着走时该一次都没有）。
    private var alignCount = 0
    /// 每一笔是从哪一路来的 —— 第一版量到换轨那一下落 3 次，光看次数判不出是谁落的，
    /// 所以次数旁边再记一条来路（只留最近 24 笔）。
    private var alignLog: [String] = []
    #endif

    private static func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = false
        return player
    }

    /// 这一轨自己那台播放器。只有「挂 item」那一趟用它（`rebind` / `finishLoad`），
    /// 别处一律走下面那个 `player(_:)`。
    private func ownPlayer(_ side: TrackSide) -> AVPlayer { side == .a ? playerA : playerB }

    /// 这一轨的画面实际由哪一台播放器出：两轨走同一条流的时候，B 那一侧也出自 A 那台，
    /// B 自己的播放器闲着（一台解码器）。摆了位、追了差、读了表，全都跟着这个数走，
    /// 就不用在每一路里各写一遍「共享时别碰 B」的判断。
    private func player(_ side: TrackSide) -> AVPlayer {
        side == .b && sharing ? playerA : ownPlayer(side)
    }

    /// 读播放器那一台的表 —— 就是这一笔会在主线程上陷进 MediaToolbox 的锁。生产链路只有两笔
    /// 用它：`reconcile`（对差）、`lastFrame`（观众现在那张帧）；探针那一头一律走影子账
    /// （见 `ShadowClock`），一趟同步读都不发。
    /// DEBUG 下顺带量这一笔花多久 —— 见 `clockLedgerForCheck`。
    private func clock(_ site: String, _ side: TrackSide) -> Double {
        #if DEBUG
        let p = player(side)
        let t0 = ProcessInfo.processInfo.systemUptime
        let value = p.currentTime().seconds
        clockRecord(site, side: side, ms: (ProcessInfo.processInfo.systemUptime - t0) * 1000, on: p.currentItem)
        return value
        #else
        return player(side).currentTime().seconds
        #endif
    }

    /// 生产那两笔读表各自的笔数、单笔最长，以及「慢笔」（超过 5 ms —— 一拍才 50 ms，
    /// 单笔吃掉十分之一以上就是看得见的顿）有几笔、其中几笔读的是还欠第一帧的那份 item。
    /// 重载风暴五次跑有四次整进程冻死，栈尖全尖在探针自己那一笔 `currentTime()` 上
    /// （主线程 sync 进 item 的 accessor 队列，那一队卡在 CoreMedia 的锁里），而轻账（探针
    /// 一笔不碰表）二十轮都不冻。界面本来就读同一笔，所以「会不会冻」得看这一本：
    /// 实测单笔最长 81.9 ms —— 冻是极端，顿是常态。
    /// 「慢笔是不是都落在换曲那一下（item 还没就绪）」如果成立，生产就有一条能走的避开路。
    #if DEBUG
    private struct ClockLedger { var count = 0; var maxMs = 0.0; var slow = 0; var slowMaxMs = 0.0; var slowPending = 0 }
    private var clockLedger: [String: ClockLedger] = [:]
    private func clockRecord(_ site: String, side: TrackSide, ms: Double, on item: AVPlayerItem?) {
        let key = "\(site)\(side == .a ? "A" : "B")"
        var row = clockLedger[key] ?? ClockLedger()
        row.count += 1
        row.maxMs = max(row.maxMs, ms)
        if ms > 5 {
            row.slow += 1
            row.slowMaxMs = max(row.slowMaxMs, ms)
            if pendingItem[.a] === item || pendingItem[.b] === item { row.slowPending += 1 }
        }
        clockLedger[key] = row
    }
    var clockLedgerForCheck: String {
        clockLedger.keys.sorted().map { k in
            let r = clockLedger[k]!
            return "\(r.count)笔/\(k) 最长\(String(format: "%.1f", r.maxMs))ms"
                + (r.slow > 0 ? " 慢\(r.slow)笔(欠帧\(r.slowPending)) 慢最长\(String(format: "%.1f", r.slowMaxMs))ms" : "")
        }.joined(separator: " ")
    }
    func clearClockLedgerForCheck() { clockLedger.removeAll() }

    /// 探针那一头的表：由播放器自己的定时上报喂，读它一笔都不碰 `currentTime()`。
    ///
    /// 为什么要另开一份 —— 全账的重载风暴两趟都整进程冻死（s14 第 2 轮、s15 第 7 轮），
    /// 栈尖都在探针那一笔 `feedForCheck → currentTime`，主线程等在一把 MediaToolbox 的锁上，
    /// 同一时刻还有 6 条队（accessor、player.async、URLAsset 通知、videomediaconverter…）
    /// 等在同一把锁上。探针每一拍读 4 笔、20 Hz 那一拍还读，把撞锁的机会提了一个量级；
    /// 轻账（一笔不碰表）20 轮不冻。所以量「放没放、走了多少」不需要那一下同步读：
    /// 上报值 + 上报以来流逝的时间 × 速率，比同步读还准（同步读回来的是上一拍的过期值）。
    /// 生产那两笔（对表、观众帧）照旧现读 —— 这本账量的就是界面自己会不会被按住。
    private final class ShadowClock {
        var token: Any?
        var kvo: [NSKeyValueObservation] = []
        /// 上报那一刻的表值与那一刻的钟。
        var time = 0.0
        var at = 0.0
        /// 上报那一刻的速率。`rate` 会被调速追差随时改，所以它一变就得重新起算。
        var rate = 0.0
    }
    private var shadowClocks: [ObjectIdentifier: ShadowClock] = [:]

    /// 给两台播放器各装一份影子表。挂 item 之前就能装，装一次用一辈子（关窗不摘）。
    private func installShadowClocks() {
        for player in [playerA, playerB] {
            let key = ObjectIdentifier(player)
            guard shadowClocks[key] == nil else { continue }
            let sh = ShadowClock()
            sh.time = player.currentTime().seconds
            sh.at = ProcessInfo.processInfo.systemUptime
            sh.rate = Double(player.rate)
            sh.token = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 60), queue: .main
            ) { [weak player] value in
                sh.time = max(0, value.seconds)
                sh.at = ProcessInfo.processInfo.systemUptime
                sh.rate = Double(player?.rate ?? 0)
            }
            sh.kvo = [player.observe(\.rate, options: [.new]) { seen, _ in
                // 速率改了：先把上一段按旧速率摊完，再从这一刻起按新速率摊。
                DispatchQueue.main.async {
                    let now = ProcessInfo.processInfo.systemUptime
                    sh.time += (now - sh.at) * sh.rate
                    sh.at = now
                    sh.rate = Double(seen.rate)
                }
            }]
            shadowClocks[key] = sh
        }
    }

    /// 影子表此刻的读数（表值 + 上报以来流逝 × 那一刻的速率）。
    private func shadowTime(_ side: TrackSide) -> Double {
        guard let clock = shadowClocks[ObjectIdentifier(player(side))] else {
            return player(side).currentTime().seconds
        }
        return clock.time + (ProcessInfo.processInfo.systemUptime - clock.at) * clock.rate
    }
    #endif

    /// 重新算一次「是不是同一条流」。`present()`、0.25 s 那一拍都走它。
    /// 合流的代价是零、好处是省一台解码器，但 B 那一轨的新 item 还在装载时不能合：
    /// 合了就没有人再拿它当回事，就绪那一喊回来才发现画面一直是上一份的。
    private func updateSharing() {
        guard let vm, let urlA = boundURL[.a], boundURL[.b] == urlA,
              vm.videoFacts[urlA.path]?.hasVideo == true,
              pendingItem[.a] == nil, pendingItem[.b] == nil else {
            sharing = false
            return
        }
        let gap = abs(engineTarget(.a) - engineTarget(.b))
        if sharing {
            if gap > Self.shareExit { sharing = false }        // 真被拖开了：各解各的，摆位那一趟自会把 B 接回去
        } else if gap <= Self.shareEnter {
            sharing = true
            #if DEBUG
            notePic(.b, "按停", "进共享")
            #endif
            ownPlayer(.b).pause()                             // 这一台从这一刻起不干活，别让它空转
        }
    }

    /// 计时那一拍的合流/分家：一旦变了就重走一遍 `present()`，回 false 表示没变、该干嘛干嘛。
    /// 非要不重摆不可，是因为「哪一层挂哪台播放器」只在 `present()` 里落：分家之后要是没人
    /// 重新挂，B 那一层还指着对面那台，`warm` 追的是一张没人看的旧表。
    /// `present()` 自己那一趟不走这里（它正在挂，再喊自己是死循环）。
    @discardableResult
    private func reconsiderSharing() -> Bool {
        let was = sharing
        updateSharing()
        guard was != sharing else { return false }
        #if DEBUG
        tracePreload(.b, sharing ? "合流" : "分家")
        #endif
        present()
        return true
    }

    // MARK: 开关

    func toggle(vm: PlayerViewModel) {
        if isVisible { close() } else { open(vm: vm) }
    }

    func open(vm: PlayerViewModel) {
        self.vm = vm
        if panel == nil { build() }
        #if DEBUG
        installShadowClocks()
        #endif
        observe(vm)
        panel?.makeKeyAndOrderFront(nil)
        rebind()
        startTimer()
    }

    func close() {
        rememberFrame()
        panel?.orderOut(nil)
        driftTimer?.invalidate()
        driftTimer = nil
        warmTimer?.invalidate()
        warmTimer = nil
        cancellables.removeAll()
        lastLane.removeAll()
        wasPlaying.removeAll()
        lastPlaced.removeAll()
        // 窗关了就不该还在解码：两台一起停，item 留着，下次开窗立刻有画面。
        #if DEBUG
        notePic(.a, "按停", "关窗"); notePic(.b, "按停", "关窗")
        #endif
        playerA.pause()
        playerB.pause()
    }

    /// 进编辑模式 / 开 ABX：画面整块无效，跟着收（和混音器退模式同一套）。
    func videoInvalidated() {
        if isVisible { close() }
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "视频"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // 整块画面都能拖（以前只有标题栏那一条能拖）。标题栏留着：关闭按钮和
        // 「视频 · A」那一行还要看。
        p.isMovableByWindowBackground = true
        p.contentMinSize = NSSize(width: 240, height: 135)
        // 尺寸、位置的记忆要听这两下：用户自己拖完边、或者把窗挪走，才算「这一版定下来了」。
        p.delegate = self
        let surface = VideoSurface()
        p.contentView = surface
        self.surface = surface
        panel = p
        // 上一次那扇窗什么样，这次就什么样；没有上一版（第一次用这扇窗）才摆到正中起手。
        if !restoreMemory() { center(on: hostScreen()) }
        // 比例锁一出生是 (0,0)，而 (0,0) 那一档在 AppKit 的拖边路线上会当场
        // `Illegal instruction: 4`（两份用户崩溃报告 + Debug 复现两份，见 `present()`
        // 里占位那一段）。参数读回来之前 `present()` 整趟要退回去（拿一份 0×0 的画面去
        // `fitWindow` 更糟），所以这一档在开窗那一刻就先锁上，不等第一份画面参数 ——
        // 实测两轨纯音频、开窗以后 5 s 里参数还是「未读」，那 5 s 窗口就站在 (0,0) 上。
        // 有上一份画面就照它的比例（和 `restoreMemory` 那把尺同源），没有才 16:9（同下限 240×135）。
        p.contentAspectRatio = lastPicture ?? NSSize(width: 16, height: 9)
    }

    /// 这块屏该按谁的：主窗口在的那一块。`NSApp.mainWindow` 在程序没拿到焦点时是 nil
    /// （真用户手里没事，探针启动里必中），所以 Debug 里先读 `MainWindow` 那本账；再退
    /// 不成才用 `NSScreen.main` —— 那是「当前有焦点那块」，双屏时会量到别的软件那块屏。
    private func hostScreen() -> NSScreen {
        #if DEBUG
        if let s = MainWindow.windowForCheck?.screen { return s }
        #endif
        return NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    /// 在这块屏的可见框里摆正中（横向居中、纵向留三分之一在上头，和 `center()` 一个口味）。
    private func center(on screen: NSScreen) {
        guard let panel else { return }
        panel.setFrameOrigin(centeredOrigin(panel.frame.size, on: screen))
    }

    /// 这个窗口尺寸在该屏上的「正中」落点（横向居中、纵向留三分之一在上头）。
    private func centeredOrigin(_ size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX - size.width / 2,
                       y: visible.minY + (visible.height - size.height) * 2 / 3)
    }

    // MARK: 大小与位置的记忆

    /// 两本账：窗口框（屏幕坐标、左下角原点）和上一次拿它当尺子的那份画面的像素宽高。
    /// 只存窗口尺寸不够 —— 「分辨率不同则缩放至相应大小」要按上一份的缩放比走，那个比值
    /// 得连画面尺寸一起存才还得回来。存法照主窗口 `savedWindowSize` 那一套（数组存 Double）。
    private enum MemoryKey {
        static let frame = "videoPanelWindowFrame"
        static let picture = "videoPanelPictureSize"
    }

    /// 摆窗那一趟有没有上一版可照：有就恢复，没有留给调用方摆正中起手。
    /// 换过显示器时存的那块屏可能已经不在，按窗口中点找屏，找不着退回主窗口那块，
    /// 尺寸和位置再夹进那块屏（`frameSize` 整幅缩、`clampOrigin` 挪回来）。
    private func restoreMemory() -> Bool {
        guard let panel else { return false }
        let defaults = UserDefaults.standard
        guard let raw = defaults.array(forKey: MemoryKey.frame) as? [Double], raw.count == 4,
              raw[2] > 1, raw[3] > 1,
              let pic = defaults.array(forKey: MemoryKey.picture) as? [Double], pic.count == 2,
              pic[0] > 1, pic[1] > 1 else { return false }
        let stored = NSRect(x: raw[0], y: raw[1], width: raw[2], height: raw[3])
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: stored.midX, y: stored.midY)) }
            ?? hostScreen()
        lastPicture = NSSize(width: pic[0], height: pic[1])
        let size = frameSize(forContent: panel.contentRect(forFrameRect: stored).size, on: screen)
        panel.setFrame(clampOrigin(NSRect(origin: stored.origin, size: size), on: screen), display: false)
        return true
    }

    /// 记下这一版。画面还没读出来时不记（`lastPicture` 是空的），免得把一扇没有尺子的窗
    /// 存进去 —— 下一次就没法算「这一份相对上一份该放大还是缩小」。
    private func rememberFrame() {
        guard let panel, let picture = lastPicture, panel.frame.width > 1 else { return }
        let defaults = UserDefaults.standard
        defaults.set([panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
                     forKey: MemoryKey.frame)
        defaults.set([picture.width, picture.height], forKey: MemoryKey.picture)
    }

    /// 内容尺寸（不含标题栏）→ 窗口框尺寸，顺带夹在那块屏里：比例锁着，摆不下只能整幅缩，
    /// 不能只压一条边。上下限都在这一步管住，调用方只管算该摆多大。
    private func frameSize(forContent content: NSSize, on screen: NSScreen) -> NSSize {
        guard let panel else { return content }
        let visible = screen.visibleFrame
        let cap = min(1, (visible.width - 40) / content.width, (visible.height - 40) / content.height)
        let lower = panel.contentMinSize
        let fitted = NSSize(width: max((content.width * cap).rounded(), lower.width),
                            height: max((content.height * cap).rounded(), lower.height))
        return panel.frameRect(forContentRect: NSRect(origin: .zero, size: fitted)).size
    }

    /// 原点夹在可见框里（尺寸已经夹过了，这一条只挪）。
    private func clampOrigin(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var out = frame
        out.origin.x = min(max(out.minX, visible.minX), max(visible.maxX - out.width, visible.minX))
        out.origin.y = min(max(out.minY, visible.minY), max(visible.maxY - out.height, visible.minY))
        return out
    }

    private func observe(_ vm: PlayerViewModel) {
        cancellables.removeAll()
        // `@Published` 是在 willSet 那一瞬间喊人的：同一拍里再去读那个属性，读到的还是
        // 旧值（实测 F 换轨后画面仍摆在 A —— `present()` 读到的 activeTrack 还没换过来）。
        // 所以全部转到下一拍再动手，读什么都是新值。
        // 换轨、换曲、参数读回来，三条都汇到 rebind / present。
        vm.$activeTrack.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebind() }.store(in: &cancellables)
        vm.$trackA.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebind() }.store(in: &cancellables)
        vm.$trackB.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebind() }.store(in: &cancellables)
        vm.$videoFacts.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.present() }.store(in: &cancellables)
        // 播放/暂停跟着引擎那一旗标，一按就到位：等 1.5 s 那一拍才跟上，画面要么白停、
        // 要么在已经暂停的轨道上继续放。
        vm.$sidePlayingA.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followPlayState(.a) }.store(in: &cancellables)
        vm.$sidePlayingB.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followPlayState(.b) }.store(in: &cancellables)
        // 时钟那一拍：正常推进一次 50 ms，被拖走是一次大跳。大跳当场吸附，
        // 不等 1.5 s 那拍，不然拖完播放头画面要愣在那里。
        vm.clock.$posA.receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.clockTicked(.a, value) }.store(in: &cancellables)
        vm.clock.$posB.receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.clockTicked(.b, value) }.store(in: &cancellables)
        // 设置里那枚开关在半路翻：重新走一遍 `present()` —— 它同时管两层挂不挂播放器、
        // 摆哪一层，并把刚放手的那一轨养起来（拨开）或让它歇着（关掉）。
        SettingsStore.shared.$seamlessVideoSwitch.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.present() }.store(in: &cancellables)
    }

    private func startTimer() {
        driftTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        // 播放期间主线程也有活要干，这一拍晚一点无妨，别卡界面。
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
        warmTimer?.invalidate()
        let warm = Timer(timeInterval: Self.warmCadence, repeats: true) { [weak self] _ in
            self?.warmTick()
        }
        RunLoop.main.add(warm, forMode: .common)
        warmTimer = warm
    }

    /// 摆着的那一轨按 `correctDrift` 的规矩（能追就不落 seek）。
    /// 看不见那一轨不归这一拍管 —— 它跟着 0.25 s 那一拍走（`warmTick`），1.5 s 太慢，
    /// 两拍之间画面那一轨已经走出好几帧了。
    private func tick() {
        guard let vm else { return }
        correctDrift(vm.activeTrack)
    }

    /// 无缝那一档专用的一拍（关着就什么都不做）：把看不见那一轨往摆着那一轨的画上追。
    private func warmTick() {
        guard let vm, seamlessSwitch else { return }
        // 两轨的时钟在这一拍上重新认一次：要是把没摆的那一轨拖开了，这一拍就该分家；
        // 拖回来了（或刚开这一档）就该合成一条流，省下一台解码器。
        if reconsiderSharing() { return }
        if sharing {
            // 没有「看不见的那一轨」可养 —— 两侧画的是同一台播放器。这一拍改为把这条共享
            // 的流按摆着那一轨的时钟对齐（±3% 调速，差过 0.25 s 才落 seek），不然它只按
            // 1.5 s 那一拍走，两拍之间能走出好几帧。
            reconcile(vm.activeTrack, target: engineTarget(vm.activeTrack))
            return
        }
        warm(vm.activeTrack == .a ? .b : .a)
    }

    // MARK: 画面

    /// 哪一轨换了曲就重新挂 item、重新问一次参数；摆哪一台播放器、标题、占位由
    /// `present()` 说。
    ///
    /// 重负载试过两种「先养后换」，都扔掉：
    /// ①再开一台不显示任何画面的播放器养新 item —— 在那台播放器上 `replaceCurrentItem(with:)`
    ///   会陷进同步等媒体服务的嵌套 run loop，定时器照走但 `DispatchQueue.main` 一块都不排，
    /// 整个程序冻在原地（实测：关掉那一路 40 拍走完，开着只走到第一拍）。裁定的「B 轨画面
    ///   卡死」就是这一档的样子，绝对不能留这一种写法。
    /// ②不开播放器、单独创建 `AVPlayerItem` 等它自己装载 —— 它不装。实测 15 s 过去 `status`
    ///   还停在 `.unknown`，两条轨全程 `无item`，黑的那一下没换来，画面倒是一直没有。
    ///   item 只有挂进播放器才真在装载。
    /// 所以现在是「立刻挂、挂上就等就绪」：换曲那一趟照旧停这一轨，新 item
    /// 当场挂上开始装载，`pendingItem` 记着这一轨还欠第一帧；就绪之前谁都不拿新曲的时钟去
    /// 摆它（那是「黑一下 + 一顿 seek 追不完」的来路），就绪那一喊回来再走 `present()`。
    private func rebind() {
        guard let vm else { return }
        for side in [TrackSide.a, .b] {
            let url = (side == .a ? vm.trackA : vm.trackB)?.url
            guard url != boundURL[side] else { continue }
            boundURL[side] = url
            // 换曲了这一轨就得自己算：共享那一条流的判断是上一份文件的账，先收回来，
            // 末尾 `present()` 里再重新认（`player(.b)` 在收回来之前绝不能指到 A 那台去）。
            sharing = false
            // 换曲 = 这一轨立刻停。`followPlayState` 只跟得动摆着那一轨
            // （看不见那一轨要无缝开关开着才跟），所以这一停不能等旗标那一喊：先把播放器
            // 按下，`wasPlaying` 跟着清账 —— 不然新 item 挂上来的那一刻，rate 还是 1，
            // 后台那条自己就放开了。
            #if DEBUG
            notePic(side, "按停", "换曲")
            #endif
            ownPlayer(side).pause()
            wasPlaying[side] = false
            // 换曲了，上一份文件那笔「摆在哪儿」的账跟着作废 —— 拿它去镜像会把新曲的
            // 看不见那一轨丢到旧曲的位置上。
            lastPlaced[side] = nil
            pendingWatch[side] = nil
            guard let url else {
                pendingItem[side] = nil
                ownPlayer(side).replaceCurrentItem(with: nil)
                continue
            }
            let item = AVPlayerItem(url: url)
            ownPlayer(side).replaceCurrentItem(with: item)
            pendingItem[side] = item
            #if DEBUG
            tracePreload(side, "挂上")
            #endif
            pendingWatch[side] = item.observe(\.status, options: [.initial, .new]) { [weak self] probe, _ in
                guard probe.status != .unknown else { return }
                // KVO 的回话落在哪条线程不保证，一律回主线程再动这一本的账。
                DispatchQueue.main.async { self?.finishLoad(url, side: side) }
            }
            Task { @MainActor in
                await vm.ensureVideoFacts(for: url)
                guard self.boundURL[side] == url else { return }
                // 参数回来才谈得上摆位（`present()` 拿的是 `videoFacts`）。
                self.present()
            }
        }
        present()
    }

    /// 这一轨的新 item 报了状态（就绪或失败都算 —— 失败一直挂着闸门就成了「卡死」），
    /// 撤账、补一次摆位、重摆。这一轨在这期间又被换了一次（`boundURL` 已经不是这一份）
    /// 就直接收手。
    @MainActor
    private func finishLoad(_ url: URL, side: TrackSide) {
        guard boundURL[side] == url, let item = pendingItem[side], item.status != .unknown else { return }
        pendingItem[side] = nil
        pendingWatch[side] = nil
        #if DEBUG
        tracePreload(side, "就绪(态=\(item.status.rawValue))")
        #endif
        // 参数说这一轨其实没画面（纯音频、或读失败）就把 item 摘干净，让占位上来。
        // 有画面的话这一趟什么都不用补：实测新 item 一到 ready，AVPlayer 自己就把 0 秒
        // 那一张画出来了（+0.5 s 那一拍 `亮=89.2%`），再落一笔 seek 纯属多花一次。
        if vm?.videoFacts[url.path]?.hasVideo == false { ownPlayer(side).replaceCurrentItem(with: nil) }
        present()
    }

    /// 把 layer 指向当前这一轨的播放器；这一轨没画面就盖占位。只换显示，不动时钟。
    ///
    /// 黑帧的来路不是「只开了一条流」—— 两台播放器、两支 item 早就各活各的，
    /// 黑的是换轨那一下 `align()` 的零容差 seek：一台从没渲染过帧的暂停播放器被摆到位之前，
    /// layer 上没有帧可画（实测播中 seek 完成还要再愣约 0.1 s）。所以无缝那一档开着时
    /// 两层都挂着播放器、看不见那一轨由 `warm` 提前摆准，换轨只是把它的层提到上头，
    /// 摆着这一轨的位置一动不动（走 `correctDrift`，追平就什么都不落）。
    /// 关着 = 老办法：只挂摆着那一台，换过去先 seek 一次，那一段是黑的。
    private func present() {
        guard let vm, let surface else { return }
        let lane = vm.activeTrack
        let other = lane == .a ? TrackSide.b : .a
        let path = (lane == .a ? vm.trackA : vm.trackB)?.url.path
        let facts = path.flatMap { vm.videoFacts[$0] }
        // 摆着这一轨的参数还没读回来，且**屏幕上此刻真有一张画**：这一趟什么都不动 ——
        // 拿 0×0 的宽高去 `fitWindow`、把正摆着的那一张撤下来换占位都是错的（换占位就是
        // 要消掉的「重新指派后黑一下」）。参数一回来那一喊会再走一遍这一趟。
        // 屏幕上本来就什么都没有（刚开窗那一趟）则不在这条里：那一趟往下走，把
        // 「该轨道无画面」那行灰字摆上来，别让人对着一块黑等参数 —— 纯音频那两轨实测
        // 参数要等好几秒（波形解码抢着后台），黑着等不好看。
        if path != nil, facts == nil, surface.shown != nil {
            #if DEBUG
            tracePreload(lane, "摆早退")
            #endif
            return
        }
        let shown = facts?.hasVideo ?? false
        let seamless = seamlessSwitch
        // 重新认一次同一条流：这一趟往下（挂哪台、摆位、养谁）都按这个数走。
        updateSharing()
        surface.playerLayer(.a).player = shown && (seamless || lane == .a) ? playerA : nil
        // 共享时 B 那一侧的画出自 A 那台 —— 挂载的条件一个字没改，只是换了源头，
        // 所以「无缝开着」和「刚换到 B」这两档拿的是同一张已经画好的帧，落不了 seek。
        surface.playerLayer(.b).player = shown && (seamless || lane == .b) ? (sharing ? playerA : playerB) : nil
        surface.show(shown ? lane : nil)
        if shown {
            empty?.isHidden = true
        } else {
            // 没画面不等于「比例该放开」。实测（两份用户崩溃报告 + Debug 里复现两份）：
            // 这一档一旦把 `contentAspectRatio` 落回 (0,0)，AppKit 就走「无约束拖边」那一条，
            // 第一个拖动事件在 `-[NSWindow _adjustNeedsDisplayRegionForNewFrame:]` 里拿着
            // +inf 去造 NSRegion，当场 `Illegal instruction: 4`（rax=rcx=0x7ff0000000000000）。
            // 只要锁着一个真实比例就走另一条受得住的路 —— 摘掉别的每一项（下限、上限、
            // 浮窗、utility、委托、定时、sublayer、占位视图、刷新显示区、窗口位置）都照崩。
            // 所以占位这一档锁的是上一份画面的比例，没读过画面就锁 16:9（和下限 240×135 同档）。
            panel?.contentAspectRatio = lastPicture ?? NSSize(width: 16, height: 9)
            if empty == nil { attachEmpty() }
            empty?.setText(path == nil ? "未选择轨道" : "该轨道无画面")
            empty?.isHidden = false
        }
        panel?.title = shown ? "视频 · \(lane == .a ? "A" : "B")" : "视频"
        if shown, let path { fitWindow(to: vm.videoFacts[path] ?? VideoFacts(), key: path) }
        lastLane[lane] = nil
        if seamless {
            // 摆着这一轨的位置不动它：`warm` 那一拍早把它养到「和刚才那一轨画在同一处」，
            // 这一趟再落一次零容差 seek 就是把黑的那一下请回来。走同一套三档（`reconcile`），
            // 参照是观众刚看到的那一张（`switchTarget`）而不是引擎报的那个数：真丢远了
            // （差过 0.25 s —— 开窗头一次、item 刚就绪把 seek 吃掉那一下）才落 seek，
            // 只差一点点就调速追。
            // 共享那一条流没有「刚才那一轨」和「现在这一轨」之分：两侧画的是同一台播放器，
            // 观众看到的那一张就是眼下这一张，一个像素都没动。这时候要对齐的是**摆着这一轨
            // 的时钟**（拿 `switchTarget` 会绕回自己的表上，差值恒等于两轨的时钟差，白调速），
            // 也绝不能再落 seek —— 往回倒退那一点点就是 seek 的 0.1 s 愣表。
            if sharing {
                reconcile(lane, target: engineTarget(lane), by: .switchLane)
            } else {
                reconcile(lane, target: switchTarget(lane), by: .switchLane)
                // 看不见那一轨当场先养起来：开窗头一次、换曲、以及设置里刚拨开这一档，
                // 都要在这一趟把它摆准，下一次 F 才有帧可接。
                warm(other)
            }
        } else if sharing {
            // 无缝关着的老办法是「换过去当场吸一次」，那一吸是替第二台播放器补位置用的；
            // 同一条流上两侧画的本就是同一张帧，补无可补，再吸一回就是把愣表请回来。
            reconcile(lane, target: engineTarget(lane), by: .legacySwitch)
        } else {
            align(lane, by: .legacySwitch)
        }
        followPlayState(lane)
    }

    /// 设置里那一枚开关（默认开）。
    private var seamlessSwitch: Bool { SettingsStore.shared.seamlessVideoSwitch }

    private func attachEmpty() {
        guard let root = panel?.contentView else { return }
        let view = VideoEmptyView()
        view.translatesAutoresizingMaskIntoConstraints = false
        // 那块黑垫（占位那一档 zPosition=2）是给信箱条用的，顺手把这一层的灰字也
        // 一起盖住了（实测：窗口全黑、字看不见）。占位视图本来就是最上面那一张，抬到黑垫上头。
        view.layer?.zPosition = 3
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        empty = view
    }

    /// 窗口 = 画面，但只在「这一份程序第一次见到画面」那一趟成立：那一趟一像素对一点
    /// （`frameSize` 里那块屏摆不下才整幅缩）。之后窗口的大小归用户，换轨换到另一份画面
    /// 时不重摆，只照这一份的差别调一条边（反馈 · 改）：
    /// · 高度和垂直位置一动不动，宽度按新画面的比例重算 —— 比例不同那一档就是这一条；
    /// · 只有分辨率不同（同一档比例里 1080p ↔ 4K）时窗口**一动不动**：先前那一支按
    /// 「缩放比照旧」把窗口跟着新画面等比缩放，裁定掉 —— 两条轨要比的是同一块画面，
    ///   换轨时窗口忽大忽小，量的就不是同一个尺子。多出来（或少掉）的像素由 `resizeAspect`
    ///   缩放吃掉，画面上是同一块位置、同一份大小。
    /// 两种都钉在「窗口水平中点 + 顶边」这个锚点上，换轨不会把窗挪到屏角去。
    /// 同时把比例锁死（`contentAspectRatio`）—— 用户再怎么拖边都只沿这一档比例走，
    /// `resizeAspect` 于是永远填满。黑框的来路只有两条：窗口比例和画面比例不一致时那两条边，
    /// 以及先按 640×360 起手再去凑那个比例。
    /// 同一份文件只摆一次（`fittedFor`），否则每次重画都会把用户手动拖好的尺寸抹掉。
    private func fitWindow(to facts: VideoFacts, key: String) {
        guard let panel, facts.width > 1, facts.height > 1 else { return }
        let picture = NSSize(width: facts.width, height: facts.height)
        panel.contentAspectRatio = picture
        guard fittedFor != key else { return }
        fittedFor = key
        // 摆哪块屏 = 拿哪块屏的可见框当尺子。先认窗口自己站的那块（`panel.screen` 要上屏
        // 之后才有效），站定不了才退回主窗口那块 —— `NSScreen.main` 是「当前有焦点那块」，
        // 程序在后台时它是别的软件的屏，量出来的尺子就把窗口丢到用户干活那块屏上。
        let screen = panel.screen ?? hostScreen()
        let hadPrevious = lastPicture != nil
        let content: NSSize
        if hadPrevious {
            let here = panel.contentRect(forFrameRect: panel.frame).size
            content = NSSize(width: here.height * (picture.width / picture.height),
                             height: here.height)
        } else {
            content = picture
        }
        let size = frameSize(forContent: content, on: screen)
        // 起手那一次摆正中；往后都跟着中点走。
        let origin = hadPrevious ? NSPoint(x: panel.frame.midX - size.width / 2,
                                           y: panel.frame.maxY - size.height)
            : centeredOrigin(size, on: screen)
        panel.setFrame(clampOrigin(NSRect(origin: origin, size: size), on: screen), display: true)
        lastPicture = picture
        rememberFrame()
    }

    /// 20 Hz 那一拍：只认「不连续」，漂移留给 1.5 s 那拍。
    /// 停了也要认 —— 拖播放头十有八九发生在暂停时，画面得跟着走。
    /// 无缝那一档下看不见那一轨的大跳也当场补（拖播放头常常落在没摆的那一轨上），
    /// 不然换过去先看到旧的那一帧 —— 那不是黑，是更坏的「错帧」。
    private func clockTicked(_ side: TrackSide, _ value: TimeInterval) {
        defer { lastLane[side] = value }
        guard side == vm?.activeTrack || seamlessSwitch, let previous = lastLane[side],
              abs(value - previous) > 0.3 else { return }
        // 播放头被人拖走了：先把共享的账重算一遍。合得上就继续走同一条流（这时候 `player(.b)`
        // 是 A 那台，没摆的那一轨再去按它等于把观众眼前这一条流拖走）；合不上已经分家，
        // 下面那一笔 seek 落在 B 自己那台上，正是该做的。
        if reconsiderSharing() { return }
        if sharing, side != vm?.activeTrack { return }
        align(side, by: .scrub)
    }

    /// 一套三档的追差规矩，摆着那一轨和看不见那一轨共用：
    /// · 差在半帧以内 → 什么都不落（在放就把表回 1；停着就别碰 rate —— 给它一个非 0 的
    ///   rate 等于把它放起来）。
    /// · 半帧到 0.25 s 之间、而且这一轨在放 → 只调速，不落 seek。理由是实测的：一次播中 seek
    ///   0.041…0.055 s 就报"完成"，可完成之后播放器的表还要再停约 0.1 s 才开始走（要先渲出
    ///   第一帧），这一段引擎照走 —— 探针账上：落地那一拍差 −0.002，下一拍就成了 −0.098，
    ///   之后稳在 −0.11。所以"过半帧就 seek"追的正是 seek 自己造出来的那一截：每 1.5 s 白愣
    ///   一下，愣完还是差 0.1 s。调速没有这个代价，播放器是静音的，±3% 的速率差在画面上
    ///   看不出来，两三秒把差吃掉（一次对照：起手 −0.144，4 s 收到 −0.061，全程一次 seek 不落）。
    /// · 停着的、或者差过 0.25 s → 硬落一次 seek。暂停时 seek 落地实测差 0.000，摆准了没代价。
    ///
    /// 末尾那两个参数是留给看不见那一轨的：它不在画面上，速率临时偏多大都看不出代价，
    /// 摆着那一轨才要守 ±3% 那一档。
    private func reconcile(_ side: TrackSide, target want: Double,
                           timeConstant: Double = VideoPanelController.catchUpTimeConstant,
                           rateLimit: Double = VideoPanelController.catchUpRateLimit,
                           by reason: AlignReason? = nil) {
        guard let vm, let url = boundURL[side],
              vm.videoFacts[url.path]?.hasVideo == true else { return }
        let player = self.player(side)
        guard player.currentItem != nil else { return }
        // 这一轨的新 item 还没报状态：摆上去就是黑的，那一趟 seek 也追不完。
        guard pendingItem[side] == nil else { return }
        let delta = clock("对表", side) - want
        guard delta.isFinite else { return }
        if abs(delta) <= halfFrame(side) {
            if sideIsPlaying(side), player.rate != 1 {
                #if DEBUG
                notePic(side, "放开", "追平补放")
                #endif
                player.play()
            }
            return
        }
        if !sideIsPlaying(side) || abs(delta) > Self.seekBand {
            align(side, to: want,
                  by: reason ?? (side == vm.activeTrack ? .shownLane : .hiddenLane))
            return
        }
        let nudge = min(max(-delta / timeConstant, -rateLimit), rateLimit)
        player.rate = Float(1 + nudge)
    }

    /// 摆着那一轨（1.5 s 那一拍）：目标是引擎报的那个数。
    private func correctDrift(_ side: TrackSide) {
        reconcile(side, target: engineTarget(side))
    }

    /// 看不见的那一轨（无缝那一档）：要它「换过来立刻接得上」。标准**不是**引擎报的那个数，
    /// 而是眼下这一轨实际画到的那个数（再按两轨各自的偏移平移）—— 见 `mirrored`。
    /// 追差用和摆着那一轨同一套三档（`reconcile`）：第一版在这里每拍无条件 `align` 一次，
    /// 于是每次都被 seek 自己的 0.1 s 代价砸回后面，实测两轨帧距 −0.111 s ≈ −2.7 帧，
    /// 换过来照样跳一格 —— 那一格正是要消掉的东西。
    /// 调速的档子和摆着那一轨不同（`warmTimeConstant` / `warmRateLimit`）：±3% 追 0.13 s
    /// 要四秒多，F 落在这几秒里照样跳帧；看不见的那一轨不在画面上，可以踩得狠得多。
    private func warm(_ side: TrackSide) {
        guard let vm else { return }
        reconcile(side, target: mirrored(from: vm.activeTrack, to: side) ?? engineTarget(side),
                  timeConstant: Self.warmTimeConstant, rateLimit: Self.warmRateLimit)
    }

    /// 换轨这一趟给摆出来的那一轨定的参照：观众最后看到的那一张帧在**对面**那一轨上，
    /// 所以要的是「照着刚放手那一轨的画接上去」，不是引擎报的那个数。
    /// 两轨常常整体都落后引擎一截（一次播中 seek 的 0.1 s 愣表），那一截是共同的，
    /// 消掉它才是无缝；拿引擎当尺子就会在换轨这一下落一次零容差 seek —— 黑帧的来路。
    private func switchTarget(_ side: TrackSide) -> Double {
        let other = side == .a ? TrackSide.b : .a
        return mirrored(from: other, to: side) ?? engineTarget(side)
    }

    /// 把 `ref` 那一轨眼下画到的那一张帧换算成 `side` 这一轨在文件里的位置
    /// （两轨各有各的偏移，那本账在 `fileTime` 里：整体偏移 = 引擎要的 − 实际画的）。
    /// `ref` 读不到可用的数（没画面 / 没挂 item / 差得离谱）就回 nil，调用方退回引擎那本账。
    private func mirrored(from ref: TrackSide, to side: TrackSide) -> Double? {
        guard let vm, ref != side,
              let url = boundURL[ref], vm.videoFacts[url.path]?.hasVideo == true,
              player(ref).currentItem != nil, pendingItem[ref] == nil,
              let frame = lastFrame(ref) else { return nil }
        let engine = engineTarget(ref)
        // 只在「那一轨还没落到别处去」的范围内认这个偏移：换曲 / seek 没落地时它能读出
        // 好几秒，跟着摆就把看不见那一轨丢到别的段落去。
        let offset = frame - engine
        guard offset > -1, offset < 1 else { return nil }
        return max(0, engineTarget(side) + offset)
    }

    /// 这一轨观众现在看到的那一张帧在文件里的位置：读播放器自己的表；
    /// 但刚给它落过 seek 时表还没跟上（`currentTime()` 还是过期值），那一段时间要认摆过去的
    /// 那个数 —— 摆完画的就是那一张。作废的时机不是「过了几秒」，是**表读数越过去**的那一刻：
    /// 播中 seek 落地实测 0.041…0.055 s 报完成、表随后照走，越过去就是画已经在动了的凭据；
    /// 反过来 item 还没就绪时那一下 seek 会被整个吃掉（表读数停在摆之前的旧位置好几秒），
    /// 靠时间窗判过期就会把看不见那一轨丢回那个过期读数上去 —— 实测帧距 −0.28 s ≈ −6.7 帧。
    /// 表读数比摆过去的数还小一截（多于半秒）说明有别的东西把它挪走了（不是我们落的 seek），
    /// 那种情况听表的。
    private func lastFrame(_ side: TrackSide) -> Double? {
        let actual: Double? = {
            guard let vm, let url = boundURL[side], vm.videoFacts[url.path]?.hasVideo == true,
                  player(side).currentItem != nil else { return nil }
            let value = clock("观众帧", side)
            return value >= 0 ? value : nil
        }()
        guard let placed = lastPlaced[side] else { return actual }
        if let actual {
            if actual > placed { return actual }
            if actual < placed - 0.5 { return actual }
        }
        return placed
    }

    /// 引擎报的那个数换算成文件里的位置（time trim 那本账在 `fileTime` 里）。
    private func engineTarget(_ side: TrackSide) -> Double {
        guard let vm else { return 0 }
        return max(0, vm.fileTime(vm.position(of: side), side: side))
    }

    /// 落这一笔 seek 的是哪一路。做成枚举而不是字符串，是因为这些话只给 DEBUG 的账本看：
    /// 字符串直接当参数传，Release 二进制里就会躺着「换轨这一趟」这类死字（实测各一份 ×2 切片）。
    private enum AlignReason {
        case scrub, start, switchLane, legacySwitch, shownLane, hiddenLane

        #if DEBUG
        var label: String {
            switch self {
            case .scrub: return "播放头被拖走"
            case .start: return "起播那一下"
            case .switchLane: return "换轨这一趟·丢得远"
            case .legacySwitch: return "关着那一档·换轨就 seek"
            case .shownLane: return "摆着那一轨"
            case .hiddenLane: return "看不见那一轨"
            }
        }
        #endif
    }

    /// 把播放器摆到该在的那个位置（无条件落一次 seek）。`file` 不给就是引擎报的那个数；
    /// `reconcile` 看不见那一轨那一路给的是 `mirrored` 那个数。
    /// 开窗、拖播放头、起播那一下、以及 `reconcile` 判定掉队太远的那一下走这里。
    private func align(_ side: TrackSide, to file: Double? = nil, by reason: AlignReason) {
        guard let vm, let url = boundURL[side], vm.videoFacts[url.path]?.hasVideo == true else { return }
        let player = self.player(side)
        guard player.currentItem != nil else { return }
        // 同上：换的那一份还没到手，这一轨的 seek 账不作数（旧的还挂在画面上）。
        guard pendingItem[side] == nil else { return }
        let file = file ?? engineTarget(side)
        lastPlaced[side] = file
        #if DEBUG
        alignCount += 1
        alignLog.append("\(reason.label)·\(side == .a ? "A" : "B")轨→\(String(format: "%.3f", file))s")
        if alignLog.count > 24 { alignLog.removeFirst(alignLog.count - 24) }
        #endif
        player.seek(to: CMTime(seconds: file, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 半帧是多少秒：帧率读不到就按 24 fps 那档算（宁可多修一次，别让画面长期偏着）。
    private func halfFrame(_ side: TrackSide) -> Double {
        guard let url = boundURL[side], let fps = vm?.videoFacts[url.path]?.fps, fps > 0 else {
            return 1 / 24
        }
        return 0.5 / fps
    }

    private func sideIsPlaying(_ side: TrackSide) -> Bool {
        vm?.sideIsPlaying(side) ?? false
    }

    /// 播放/暂停跟引擎那一头，不跟表：空格一按引擎就变了，画面慢半拍就白同步了。
    /// 起播那一下额外照顾一次，见下面 0.4 s 那一笔。
    /// 无缝那一档下看不见那一轨也要跟（它得自己按时钟走，才谈得上「换过来立刻有帧」），
    /// 关着时它不跟「起播」，但「停」照跟，见下面那一笔。
    private func followPlayState(_ side: TrackSide) {
        #if DEBUG
        // 每一趟「来看」都记一笔：光看后来那一下的 `态=` 分不开「没人来」和「来了但走岔了」。
        notePic(side, "来看", "跟状态")
        #endif
        guard let url = boundURL[side],
              vm?.videoFacts[url.path]?.hasVideo == true else { return }
        // 共享那一条流只由摆着的那一轨开合：对面那一轨画的是同一台播放器，它的引擎状态
        // 一说停就会把观众眼前这一轨按下（B 自己那台在进共享那一刻已经按过，见 `updateSharing`）。
        if sharing, side != vm?.activeTrack { return }
        let player = self.player(side)
        guard player.currentItem != nil else { return }
        // 这一轨的新 item 还没报状态：别让一支还在装载的 item 自己跑起来。账上记成停着，
        // 就绪那一喊回来 `present()` 再走一遍这里，那一下才按「起播」办。
        guard pendingItem[side] == nil else {
            #if DEBUG
            notePic(side, "按停", "跟状态·还欠第一帧")
            #endif
            wasPlaying[side] = false
            player.pause()
            return
        }
        let playing = sideIsPlaying(side)
        // 看不见那一轨在无缝关着时不跟「起播」（老办法里那一台压根没挂在 layer 上）。
        // 但「停」要跟到底：这一轨在后台被重新指派、或被独立按钮按停时，播放器挂着
        // rate = 1 会自己往前跑，画面上那一轨其实还在放（规格视频那一半）。
        if !playing, side != vm?.activeTrack, !seamlessSwitch {
            #if DEBUG
            notePic(side, "按停", "跟状态·看不见那轨")
            #endif
            wasPlaying[side] = false
            player.pause()
            return
        }
        guard side == vm?.activeTrack || seamlessSwitch else { return }
        let started = playing && !wasPlaying[side, default: false]
        wasPlaying[side] = playing
        if playing {
            if started {
                // 无缝那一档：这一轨多半就是刚才被 `warm` 养着的那一轨，画面上早有帧，
                // 起播这一下再落一次零容差 seek 等于把黑的那一下请回来 —— 只按三档的规矩补。
                // 关着 = 老办法，起播当场吸附一次。
                #if DEBUG
                notePic(side, "放开", "跟状态·起播\(seamlessSwitch ? "·无缝" : "·老办法")")
                #endif
                if seamlessSwitch {
                    player.play()
                    reconcile(side, target: engineTarget(side))
                } else {
                    align(side, by: .start)
                }
                // 起播那一下最容认错：item 还没就绪时头一次 seek 会被整个吃掉（画面停在 0），
                // 得有人补。0.4 s 后按 `correctDrift` 的规矩再看一眼 —— 掉队远就落 seek，
                // 只差一点就调速追，不再无条件愣第二下。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, self.sideIsPlaying(side) else { return }
                    self.correctDrift(side)
                }
            } else {
                #if DEBUG
                notePic(side, "放开", "跟状态·照旗标")
                #endif
            }
            player.play()
        } else {
            #if DEBUG
            notePic(side, "按停", "跟状态·旗标说停")
            #endif
            player.pause()
        }
    }

    #if DEBUG
    // MARK: 探针口子（Release 里没有这几条）

    /// 「先养后换」那趟走到哪儿了（只留最近 24 笔）。重负载第一轮整个探针停在 b00，
    /// 主线程的定时器照走、`asyncAfter` 那一串不再走，所以要看着这一步一行才能分清是装载
    /// 卡住还是主队列被谁咬住。量完删。
    private var preloadTrace: [String] = []
    var preloadTraceForCheck: String { preloadTrace.suffix(5).joined(separator: "|") }
    private func tracePreload(_ side: TrackSide, _ step: String) {
        let name = side == .a ? "A" : "B"
        preloadTrace.append("\(name):\(step)")
        if preloadTrace.count > 24 { preloadTrace.removeFirst() }
    }

    /// 这一轨「引擎要的画面位置」和「播放器实际位置」，单位秒；没有画面的那一轨回 nil。
    /// 同步对不对就看这两个数的差，和 `halfFrame` 比。
    func syncReadings(_ side: TrackSide) -> (expected: Double, actual: Double, halfFrame: Double)? {
        guard let vm, let url = boundURL[side], vm.videoFacts[url.path]?.hasVideo == true,
              player(side).currentItem != nil else { return nil }
        let expected = max(0, vm.fileTime(vm.position(of: side), side: side))
        let actual = shadowTime(side)
        guard actual >= 0 else { return nil }
        return (expected, actual, halfFrame(side))
    }

    /// 这一轨此刻的播放速率。调速追差的那一下不等于 1，追平就回 1。
    func rateForCheck(_ side: TrackSide) -> Float { player(side).rate }

    /// 现在是不是两轨走同一条流（一台解码器）。
    var sharingForCheck: Bool { sharing }

    /// 每一笔按下/放开画面那一台的账：谁按的、按的那一刻两边的账各是什么。
    /// 重负载那轮量到摆着那一轨每一拍都是「音频在放、界面旗标在放、画面 `控=0`」——
    /// 光看结果分不开「有人按了暂停」和「压根没人来放开」，所以要留这一本。
    private var picControlLog: [String] = []
    private func notePic(_ side: TrackSide, _ op: String, _ from: String) {
        picControlLog.append("\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime)) "
            + "\((side == .a ? "A" : "B"))\(op)←\(from)"
            + "[摆=\(vm?.activeTrack == side ? "是" : "否") 旗=\(sideIsPlaying(side) ? 1 : 0) "
            + "表=\(wasPlaying[side, default: false] ? 1 : 0) 待=\(pendingItem[side] == nil ? 0 : 1) "
            + "共=\(sharing ? 1 : 0) 态=\(player(side).timeControlStatus.rawValue)]")
        if picControlLog.count > 200 { picControlLog.removeFirst(picControlLog.count - 200) }
    }
    /// 播放器自己的 `timeControlStatus` 一变就记一笔（谁按的都写在上一行）。有了这一串时间戳，
    /// 「画面冻多久」不用再靠 1 s 那一拍猜：停→走之间隔了几秒，账上直接读。
    private var picStatusWatch: [NSKeyValueObservation] = []
    func watchPicStatusForCheck() {
        guard picStatusWatch.isEmpty else { return }
        for (side, player) in [(TrackSide.a, playerA), (.b, playerB)] {
            picStatusWatch.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] seen, _ in
                let value = seen.timeControlStatus.rawValue
                DispatchQueue.main.async { self?.notePic(side, "态变\(value)", "播放器"
                    + (seen.reasonForWaitingToPlay.map { "·等\($0.rawValue)" } ?? "")) }
            })
        }
    }
    func picControlTailForCheck(_ k: Int) -> String { picControlLog.suffix(k).joined(separator: " ") }
    func clearPicControlForCheck() { picControlLog = [] }

    /// 这一轨挂着的是哪一份。「·待帧」= 新 item 已经挂上但还没报状态，这一轨的摆位账全冻着；
    /// 「·共」= 这一轨的画走的是同一条流（一台解码器），`rateForCheck` / `syncReadings` 读的是对面那台。
    func laneFileForCheck(_ side: TrackSide) -> String {
        guard let url = boundURL[side] else { return "无" }
        let state = pendingItem[side] != nil ? "·待帧" : (player(side).currentItem == nil ? "" : "·已挂")
        return url.lastPathComponent + state + (sharing ? "·共" : "")
    }

    /// 落过几次硬 seek：这一串要证的正是「播中稳着走的时候一次都不该有」。
    var alignCountForCheck: Int { alignCount }

    /// 画面那一台为什么不走：`rate` 只能读出 0，分不开「有人按了暂停」和「它自己想走、
    /// 正在等什么」。`timeControlStatus` 0=停着 1=等着 2=在走，等的缘故跟着一起报。
    func picStateForCheck(_ side: TrackSide) -> String {
        let p = player(side)
        let why = p.reasonForWaitingToPlay.map { String(describing: $0.rawValue) } ?? "—"
        return "控=\(p.timeControlStatus.rawValue) 等=\(why)"
    }

    /// 「旗标说这一轨在放，可画面没在放」——重载风暴量这一眼能停多久就靠它。
    /// 回 nil 表示这一轨不该算（没画面、新 item 还欠第一帧、或旗标本来就说停）。
    func picFrozenForCheck(_ side: TrackSide) -> Bool? {
        guard let url = boundURL[side], vm?.videoFacts[url.path]?.hasVideo == true,
              player(side).currentItem != nil, pendingItem[side] == nil else { return nil }
        guard sideIsPlaying(side) else { return false }
        return player(side).timeControlStatus != .playing
    }

    /// 最近这十几笔硬 seek 各是从哪一路来的（靠它认出「换轨那一下落 3 次」里
    /// 有 2 次其实是 `warm` 自己在砸 seek）。
    var alignTraceForCheck: String { alignLog.joined(separator: " ｜ ") }

    /// 探针用：播中无条件落一次 seek，把「发出 / 完成 / 完成后 0.3 s」三个时刻的引擎位和
    /// 播放器位都抄下来 —— 量的是一次 seek 自己吃掉多少秒，容差按这个数定。
    func probeSeekForCheck(_ side: TrackSide, _ log: @escaping (String) -> Void) {
        guard let vm, let url = boundURL[side], vm.videoFacts[url.path]?.hasVideo == true else {
            log("seek 账: 这一轨没画面，读不到")
            return
        }
        func t(_ d: Double) -> String { String(format: "%.3f", d) }
        let p = player(side)
        let engineAtIssue = vm.position(of: side)
        let target = max(0, vm.fileTime(engineAtIssue, side: side))
        let issued = ProcessInfo.processInfo.systemUptime
        log("seek 账·发出: 引擎=\(t(engineAtIssue)) 目标=\(t(target)) "
            + "播放器=\(t(p.currentTime().seconds))")
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { [weak vm] done in
            let elapsed = ProcessInfo.processInfo.systemUptime - issued
            let e = vm?.position(of: side) ?? 0
            log("seek 账·完成(+\(t(elapsed))s): 落地=\(done ? "是" : "否") "
                + "引擎=\(t(e)) 播放器=\(t(p.currentTime().seconds))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let e2 = vm?.position(of: side) ?? 0
                log("seek 账·完成后 0.3s: 引擎=\(t(e2)) 播放器=\(t(p.currentTime().seconds))")
            }
        }
    }

    /// 重负载那三条（换曲后黑屏、常常卡顿、切换往回跳）各有各的来路，光看位置分不开：
    /// 「没帧可画」是 item 那一头的事（没挂回来 / 还没就绪 / 缓冲空了），「摆错了地方」是
    /// 我们这一头的事。所以除了表上的读数，把 item 自己的账一起抄出来。
    /// `status` 是 `AVPlayerItem.Status.rawValue`（0 未知 / 1 就绪 / 2 失败）。
    func feedForCheck(_ side: TrackSide)
        -> (actual: Double, rate: Float, item: Bool, status: Int, keepUp: Bool,
            empty: Bool, ahead: Double)? {
        guard boundURL[side] != nil else { return nil }
        let p = player(side)
        // 表值走影子账：这一笔每一拍在两轨各读一次，还要再加 20 Hz 那一拍，
        // 现读就把主线程一趟一趟送进 MediaToolbox 的锁里（见 `ShadowClock`）。
        guard let current = p.currentItem else {
            return (shadowTime(side), p.rate, false, 0, false, false, 0)
        }
        let actual = shadowTime(side)
        var ahead = 0.0
        for value in current.loadedTimeRanges.map({ $0.timeRangeValue }) {
            ahead = Swift.max(ahead, value.start.seconds + value.duration.seconds - actual)
        }
        return (actual, p.rate, true, current.status.rawValue,
                current.isPlaybackLikelyToKeepUp, current.isPlaybackBufferEmpty, ahead)
    }

    /// 失败那一趟的原因（黑屏有可能是解码直接报错，账上得留一句话）。
    func feedFailureForCheck(_ side: TrackSide) -> String {
        guard let error = player(side).currentItem?.error?.localizedDescription else { return "—" }
        return error
    }

    /// 画面此刻摆的是哪一轨（F 换轨要看它）；nil = 占位那一档。
    var shownLaneForCheck: TrackSide? {
        guard let surface, let side = surface.shown else { return nil }
        // 摆着不等于挂着：无缝那一档下两层都挂，关着时只有摆着那一层挂得出画面。
        return surface.playerLayer(side).player != nil ? side : nil
    }

    /// 两台播放器此刻各挂在哪家（无缝那一条的正面证据：开着时看不见那一轨也挂着，
    /// 所以它有自己的帧可接）。
    var attachedForCheck: String {
        guard let surface else { return "无面板" }
        let a = surface.playerLayer(.a).player != nil ? "挂" : "空"
        let b = surface.playerLayer(.b).player != nil ? "挂" : "空"
        let top = surface.shown.map { $0 == .a ? "A" : "B" } ?? "占位"
        return "A=\(a) B=\(b) 在上头=\(top)"
    }

    var isShowingPlaceholderForCheck: Bool { empty?.isHidden == false }

    var panelTitleForCheck: String { panel?.title ?? "—" }

    /// 屏幕坐标（左下角原点）里的窗口框：截图要按它裁。
    var panelFrameForCheck: NSRect { panel?.frame ?? .zero }

    /// 探针要的那一张：只抓这一扇窗，落到 `<目录>/<tag>.png`，回一句话记账。
    /// 为什么不用外面的 `screencapture` 连拍：这台机器上一次全屏截图要吃掉半秒，
    /// 足以把 4K 的装载饿住 —— 实测带连拍跑，新 item 20 s 都没 ready（我一度
    /// 当成 bug）；不连拍同一份文件 0.5 s 就好了。按窗口单张抓才是量得准的那把尺。
    func shotForCheck(_ tag: String, to directory: String) -> String {
        guard let panel else { return "无面板" }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(panel.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            return "抓不到"
        }
        let rep = NSBitmapImageRep(cgImage: image)
        // 「黑屏」要能量出来，不能靠眼睛看一张一张翻：按 32×32 的格子采一遍亮度，
        // 报平均亮度和「亮得起来」的格子占比。同一趟里换之前那一张就是这条尺的零点。
        var sum = 0.0, lit = 0, seen = 0
        for y in stride(from: 8, to: rep.pixelsHigh - 8, by: max(1, rep.pixelsHigh / 32)) {
            for x in stride(from: 8, to: rep.pixelsWide - 8, by: max(1, rep.pixelsWide / 32)) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent
                    + 0.0722 * c.blueComponent
                seen += 1
                sum += l
                if l > 0.02 { lit += 1 }
            }
        }
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("hvshot-\(tag).png")
        guard let data = rep.representation(using: .png, properties: [:]) else { return "编不出 PNG" }
        do {
            try data.write(to: url)
            return "张=\(tag) \(image.width)×\(image.height) "
                + String(format: "亮=%.1f%% 均=%.3f",
                         seen > 0 ? 100 * Double(lit) / Double(seen) : 0,
                         seen > 0 ? sum / Double(seen) : 0)
        } catch {
            return "写不进: \(error.localizedDescription)"
        }
    }

    /// 窗口那本的三件：内容尺寸、锁住的宽高比、整块能不能拖。
    var windowFactsForCheck: (content: NSSize, aspect: NSSize, draggable: Bool) {
        guard let panel else { return (.zero, .zero, false) }
        return (panel.contentView?.frame.size ?? .zero, panel.contentAspectRatio,
                panel.isMovableByWindowBackground)
    }

    /// 量窗口要连它站在哪块屏、这一份程序一共有几块窗一起读。这一行查出来过一件事：
    /// 程序里读到的框是 1920×1099，外面用 CGWindowList 量到的是 1842×1055 —— 不是有两块
    /// 面板，是 fit 拿错了屏（程序在后台时 `NSScreen.main` 是别的软件那块），摆出来的窗口
    /// 比那块屏高，被系统按屏夹了一号。两处读数一模一样才算摆对。
    var windowPlaceForCheck: (frame: NSRect, screen: String, visible: NSRect, others: String) {
        guard let panel else { return (.zero, "无", .zero, "无面板") }
        let s = panel.screen
        let list = NSApp.windows.map { w in
            "\(w.title.isEmpty ? "无题" : w.title)[\(w.isVisible ? "显" : "隐")]"
                + "\(Int(w.frame.width))×\(Int(w.frame.height))@(\(Int(w.frame.minX)),\(Int(w.frame.minY)))"
        }.joined(separator: " ")
        return (panel.frame, s?.localizedName ?? "无（nil）", s?.visibleFrame ?? .zero, list)
    }

    /// 递一个任意尺寸进去，读回真正落下来的那一个。实测：`setContentSize` 不理
    /// `contentAspectRatio`（递 800×600 就落 800×600），所以这一条只量得到尺寸本身，
    /// 量不到用户拖边那一趟 —— 那一趟只有真指针能走（这台机器注不进按键）。
    func resizeForCheck(_ size: NSSize) -> NSSize {
        panel?.setContentSize(size)
        return panel?.contentView?.frame.size ?? .zero
    }

    /// 记忆那三条规则的实测口子：喂一份任意的画面尺寸走一遍 `fitWindow`，把落下来的窗口框
    /// 和账上的缩放比抄回来。真凑两份不同分辨率的视频要现编素材，而这条路径本身只吃
    /// 「画面宽高 + 当前窗口框」两个数，直接喂参数量的就是同一段代码。
    func fitForCheck(width: Double, height: Double) -> String {
        guard let panel else { return "无面板" }
        var facts = VideoFacts(hasVideo: true)
        facts.width = width
        facts.height = height
        fitWindow(to: facts, key: "check:\(Int(width))x\(Int(height))")
        let content = panel.contentRect(forFrameRect: panel.frame).size
        let scale = lastPicture.map { content.height / $0.height } ?? 0
        let frame = panel.frame
        return String(format: "画面=%.0f×%.0f 内容=%.0f×%.0f 缩放比=%.4f 比例锁=%.0f×%.0f",
                      width, height, content.width, content.height, scale,
                      panel.contentAspectRatio.width, panel.contentAspectRatio.height)
            + String(format: " 框=%.0f×%.0f@(%.0f,%.0f) midX=%.1f maxY=%.1f",
                     frame.width, frame.height, frame.minX, frame.minY, frame.midX, frame.maxY)
    }

    /// 账上现在存着什么（重启那一趟要照它恢复）。
    var memoryForCheck: String {
        let defaults = UserDefaults.standard
        func text(_ key: String) -> String {
            guard let raw = defaults.array(forKey: key) as? [Double] else { return "无" }
            return raw.map { String(format: "%.0f", $0) }.joined(separator: "×")
        }
        return "框[\(text(MemoryKey.frame))] 画面[\(text(MemoryKey.picture))] 内存里的上一份="
            + (lastPicture.map { String(format: "%.0fx%.0f", $0.width, $0.height) } ?? "无")
    }

    /// 恢复那一条的实测口子：假装程序刚重启（把账读回来），看窗口框落成什么样。
    func restoreForCheck() -> String {
        guard let panel else { return "无面板" }
        let ok = restoreMemory()
        return "恢复=\(ok ? "是" : "否") 框=\(Int(panel.frame.width))×\(Int(panel.frame.height))"
            + "@(\(Int(panel.frame.minX)),\(Int(panel.frame.minY))) " + memoryForCheck
    }

    /// 一个数还能不能用：非有限（NaN / Inf）在这一行里直接写出来。
    private func stateNum(_ v: CGFloat) -> String {
        v.isFinite ? String(format: "%.1f", v) : "非有限(\(v))"
    }

    /// 视频窗口此刻在 AppKit 那本账上的全部状态。闪退的崩溃报告死在拖边改框那一路
    /// （`_resizeWithEvent` → `_setFrameCommon` → `_adjustNeedsDisplayRegionForNewFrame`），
    /// 所以先把窗口自己报出来的每个数都抄下来找非有限值、0 值和离谱值。
    var stateDumpForCheck: String {
        guard let panel else { return "无面板" }
        let f = panel.frame
        let c = panel.contentRect(forFrameRect: f)
        var lines = [
            "框=\(stateNum(f.minX)),\(stateNum(f.minY)) \(stateNum(f.width))×\(stateNum(f.height))",
            "内容=\(stateNum(c.width))×\(stateNum(c.height)) 比例锁=\(stateNum(panel.contentAspectRatio.width))×\(stateNum(panel.contentAspectRatio.height))",
            "下限=\(stateNum(panel.contentMinSize.width))×\(stateNum(panel.contentMinSize.height)) 上限=\(stateNum(panel.contentMaxSize.width))×\(stateNum(panel.contentMaxSize.height))",
            "样式=\(panel.styleMask.rawValue) 层级=\(panel.level.rawValue) 浮窗=\(panel.isFloatingPanel) 可见=\(panel.isVisible) alpha=\(stateNum(CGFloat(panel.alphaValue)))",
            "屏=\(panel.screen?.localizedName ?? "nil") 整块可拖=\(panel.isMovableByWindowBackground) 动画=\(panel.animationBehavior.rawValue)",
        ]
        if let root = panel.contentView {
            lines.append(" contentView=\(type(of: root)) \(stateNum(root.frame.width))×\(stateNum(root.frame.height))"
                         + " wantsLayer=\(root.wantsLayer) 子视图="
                         + (root.subviews.map { "\(type(of: $0)) \(Int($0.frame.width))×\(Int($0.frame.height))\($0.isHidden ? "/隐" : "")" }.joined(separator: " ")))
            for (i, sub) in (root.layer?.sublayers ?? []).enumerated() {
                lines.append("  layer[\(i)]=\(type(of: sub)) \(stateNum(sub.frame.width))×\(stateNum(sub.frame.height))"
                             + " z=\(stateNum(sub.zPosition)) opacity=\(stateNum(CGFloat(sub.opacity)))"
                             + " player=\((sub as? AVPlayerLayer).map { $0.player == nil ? "无" : "有" } ?? "—")")
            }
        }
        lines.append(memoryForCheck)
        return lines.joined(separator: "\n")
    }

    /// 真拖边那一趟注不进鼠标，但 live resize 那一层是公开 API：`beginLiveResize` 就是 AppKit
    /// 在拖边那一下里自己包的壳，进去再改一次框走的是崩溃报告里同一条 `_setFrameCommon` →
    /// `_adjustNeedsDisplayRegionForNewFrame`。活着回来就把前后两版的框抄回去。
    func liveResizeForCheck(_ dx: CGFloat, _ dy: CGFloat) -> String {
        guard let panel else { return "无面板" }
        let before = panel.frame
        var f = before
        f.size = NSSize(width: before.width + dx, height: before.height + dy)
        f.origin.y = before.maxY - f.height
        // SDK 的 Swift 覆写里没露这两句（实测 `beginLiveResize` 取不到），只能按选择子喊。
        let begin = NSSelectorFromString("beginLiveResize")
        let end = NSSelectorFromString("endLiveResize")
        if panel.responds(to: begin) { panel.perform(begin) }
        panel.setFrame(f, display: true)
        panel.contentView?.needsLayout = true
        panel.displayIfNeeded()
        if panel.responds(to: end) { panel.perform(end) }
        let after = panel.frame
        return String(format: "%@ %.1f×%.1f → %.1f×%.1f 比例锁=%.1f×%.1f",
                      dx == 0 && dy == 0 ? "原地" : "改框",
                      before.width, before.height, after.width, after.height,
                      panel.contentAspectRatio.width, panel.contentAspectRatio.height)
    }

    /// 拖动那一下崩在哪一格已经实测复现（`_resizeWithEvent:` → `_setFrameCommon` →
    /// `_adjustNeedsDisplayRegionForNewFrame`，rax=+inf），但同一套事件喂给独立小程序却不崩，
    /// 所以岔子在这一扇窗自己的配置里。这里把每一项单独摘掉，交给 `AB_VIDEODRAG` 那一趟试：
    /// 摘掉哪一项就不崩，根因就在哪一项上。全部只在 Debug 的探针里走，不碰真用户的窗口。
    /// 可选项：noempty / nolabel / aspect169 / maxfinite / nomin / nomovablebg / nodelegate /
    /// nolayers / notimers / noobserve / notutility / nofloat / emptyblack
    func preForCheck(_ spec: String) -> String {
        guard let panel else { return "无面板" }
        let flags = Set(spec.split(separator: ",").map(String.init))
        var did: [String] = []
        if flags.contains("dragfirst") { did.append("dragfirst") }
        if flags.contains("noempty") {
            empty?.removeFromSuperview(); empty = nil; did.append("noempty")
        }
        if flags.contains("nolabel") {
            empty?.subviews.forEach { $0.removeFromSuperview() }; did.append("nolabel")
        }
        if flags.contains("aspect169") {
            panel.contentAspectRatio = NSSize(width: 16, height: 9); did.append("aspect169")
        }
        // 三条「比例锁到底哪一格管用」的：崩的机理有两个说法 ——
        // ①AppKit 的无约束拖边数学自己出事，只要锁上比例就走另一条路；
        // ②拖边数学要除以比例的「高」，高为 0 就除出 inf（rax 实测正好是 +inf）。
        // 16×0.0001 分得开这两个：①活着、②照样崩（数太大）。16×0 和 0×9 是配套的对照。
        if flags.contains("aspecttiny") {
            panel.contentAspectRatio = NSSize(width: 16, height: 0.0001); did.append("aspecttiny")
        }
        if flags.contains("aspecth0") {
            panel.contentAspectRatio = NSSize(width: 16, height: 0); did.append("aspecth0")
        }
        if flags.contains("aspectw0") {
            panel.contentAspectRatio = NSSize(width: 0, height: 9); did.append("aspectw0")
        }
        if flags.contains("noresizable") {
            panel.styleMask.remove(.resizable); did.append("noresizable")
        }
        if flags.contains("maxfinite") {
            panel.contentMaxSize = NSSize(width: 4000, height: 3000); did.append("maxfinite")
        }
        if flags.contains("nomin") {
            panel.contentMinSize = .zero; did.append("nomin")
        }
        if flags.contains("nomovablebg") {
            panel.isMovableByWindowBackground = false; did.append("nomovablebg")
        }
        if flags.contains("nodelegate") { panel.delegate = nil; did.append("nodelegate") }
        if flags.contains("nolayers") {
            panel.contentView?.layer?.sublayers = []; did.append("nolayers")
        }
        if flags.contains("notimers") {
            driftTimer?.invalidate(); driftTimer = nil
            warmTimer?.invalidate(); warmTimer = nil; did.append("notimers")
        }
        if flags.contains("noobserve") { cancellables.removeAll(); did.append("noobserve") }
        if flags.contains("notutility") {
            panel.styleMask.remove(.utilityWindow); did.append("notutility")
        }
        if flags.contains("nofloat") {
            panel.isFloatingPanel = false; panel.level = .normal; did.append("nofloat")
        }
        // 两条「刷新显示区」的：崩的那一格是 `_adjustNeedsDisplayRegionForNewFrame`，
        // 而开窗时 `restoreMemory` 走的正是 `setFrame(display: false)` 那一条 —— 显示区
        // 从没按这一版框算过一次。摘掉这两项里的任何一项如果就不崩，根因就在这儿。
        if flags.contains("redisplay") {
            panel.setFrame(panel.frame, display: true); did.append("redisplay")
        }
        if flags.contains("displaynow") {
            panel.display(); did.append("displaynow")
        }
        if flags.contains("moved") {
            let o = panel.frame.origin
            panel.setFrameOrigin(NSPoint(x: o.x + 1, y: o.y))
            panel.setFrameOrigin(o); did.append("moved")
        }
        if flags.contains("emptyblack") {
            // 把占位那一层换成「没有 Auto Layout、没有子视图」的普通层，只看它挡不挡。
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.frame = panel.contentView?.bounds ?? .zero
            empty?.removeFromSuperview()
            panel.contentView?.addSubview(v)
            empty = nil
            did.append("emptyblack")
        }
        return did.isEmpty ? "一项都没摘" : did.joined(separator: ",")
    }


    /// 真指针那一趟在这台机器上注不进来（CGEventPost 送鼠标事件被丢，实测指针没动），
    /// 所以直接喊拖边那一下的入口 `_resizeWithEvent:`，再由下面的定时器把「拖到某处」和
    /// 「松手」两笔塞进队列。它自己会进一个「等下一个事件」的内层循环，所以这一条可能不
    /// 回来：调用方先落账再动手，外面靠「有没有新的崩溃报告」分闪退和卡住。
    func dragResizeForCheck(to size: NSSize) -> String {
        guard let panel else { return "无面板" }
        let f = panel.frame
        // `mouseEvent(with:location:…)` 在 windowNumber 非 0 时给的 location 是「相对这一扇窗」
        // 的窗内坐标，不是屏幕全局坐标。拿全局数去喂，AppKit 算出来的新框就是一笔胡话
        // （实测：两种轨道都崩，这条探路就分不出岔子在哪）。右下角在窗内坐标里是 (宽, 0)。
        func make(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)
        }
        /// 右下角这个尺寸的窗内坐标：按下在原来的角上，拖到新框的角上（顶边和左边不动）。
        func corner(_ w: CGFloat, _ h: CGFloat) -> NSPoint { NSPoint(x: w - 4, y: f.height - h + 4) }
        let down = corner(f.width, f.height)
        let goal = corner(size.width, size.height)
        // 真拖边是一串拖动事件，不是一步到位：这里分四步走过去，最后补一记松手。
        var seq: [(NSEvent.EventType, NSPoint)] = []
        for i in 1...4 {
            let t = CGFloat(i) / 4
            seq.append((.leftMouseDragged,
                        NSPoint(x: down.x + (goal.x - down.x) * t, y: down.y + (goal.y - down.y) * t)))
        }
        seq.append((.leftMouseUp, goal))
        var fired = 0
        var landed = ""
        let timer = Timer(timeInterval: 0.12, repeats: true) { _ in
            guard fired < seq.count else { return }
            // 崩了就没机会收尾抄账，所以每一笔当场打到 stderr。
            let now = panel.frame
            fputs("拖动[\(fired)] 动手前框=\(Int(now.width))×\(Int(now.height))"
                  + "@(\(Int(now.minX)),\(Int(now.minY)))\n", stderr)
            fflush(stderr)
            let step = seq[fired]
            fired += 1
            guard let e = make(step.0, step.1) else { landed = "造不出\(step.0.rawValue)"; return }
            NSApp.postEvent(e, atStart: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        let sel = NSSelectorFromString("_resizeWithEvent:")
        guard panel.responds(to: sel), let ev = make(.leftMouseDown, down) else {
            timer.invalidate()
            return "窗口不认 _resizeWithEvent 或造不出按下"
        }
        panel.perform(sel, with: ev)
        timer.invalidate()
        let after = panel.frame
        return String(format: "%@ 按下@(%.0f,%.0f) 拖到@(%.0f,%.0f) → 框=%.1f×%.1f 比例锁=%.1f×%.1f",
                      landed.isEmpty ? "走完" : landed, down.x, down.y, goal.x, goal.y,
                      after.width, after.height,
                      panel.contentAspectRatio.width, panel.contentAspectRatio.height)
    }
    #endif
}

// MARK: 窗口账的记账人（反馈：大小和位置的记忆）

/// 只负责在两下「用户自己动完」之后把这一版记下来：拖边（live resize 结束那一下，不是
/// 每一帧）和把窗挪走。程序自己 `setFrame` 那几趟也会喊 `windowDidMove`，记的是同一个数，
/// 不改任何东西 —— 换轨时那份账由 `fitWindow` 末尾自己记。
extension VideoPanelController: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    /// 红点关掉那一趟走的是这条（不是我们的 `close()`），账要留到下一次开机。
    func windowWillClose(_ notification: Notification) { rememberFrame() }
}
