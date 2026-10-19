import SwiftUI
import AppKit

// MARK: 混音器窗口
//
// 编辑模式的通道条总览：两轨并排，每轨 pre-gain / 垂直推子 / 电平表 / 声像 / 六个插件槽。
// 窗口和「信息」一样是 utility panel —— 主窗口仍然能用，播放热键不受影响（见 ABPlayerApp
// 的按键闸门）。插件槽先摆空框，之后才往里装东西。

final class MixerPanelController {
    static let shared = MixerPanelController()
    private(set) var panel: NSPanel?
    let meters = MixerMeters()

    var isVisible: Bool { panel?.isVisible ?? false }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func toggle(vm: PlayerViewModel) {
        if isVisible { close() } else { open(vm: vm) }
    }

    func open(vm: PlayerViewModel) {
        if panel == nil {
            // 至多缩到给定的那张截图，不能再小。那张量出来窗口
            // 479×349 pt（截图 2×，边界 px 32.5/990.5 × 21.5/719.5），utility 窗口的标题栏
            // 19 pt，所以内容正好是 479 × 330 —— 和下面 MixerPanel 里那枚
            // `.frame(minWidth:minHeight:)` 是同一笔账。宽度这一轮被刻度列（9 → 30）和
            // 黑底读数撑到 492，再窄就要压掉右边那条通道条的一格，所以最小值跟着抬到 492。
            let minSize = NSSize(width: 492, height: 330)
            // 起手的宽度直接取那枚下限（给定的截图就是这一档）：原先开在 520，多出来的
            // 28 pt 落在两条通道条之间，等于每次开窗都要人再往里拖一次。高度仍旧是 420。
            let p = NSPanel(contentRect: NSRect(origin: .zero,
                                                size: NSSize(width: minSize.width, height: 420)),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = "混音器"
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentMinSize = minSize
            // 撑开这个界面的是按钮和标识，不是推子与电平表（.11）。
            // 用下面那枚子类而不是裸 NSHostingView：橡皮擦的指针矩形要登记在
            // AppKit 真正命中的那颗视图上，才轮得到我们。
            p.contentView = MixerHostingView(rootView: MixerPanel(vm: vm, meters: meters)
                                                .environmentObject(vm))
            p.center()
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        meters.start(vm: vm)
    }

    func close() {
        panel?.orderOut(nil)
        meters.stop()
    }

    /// 退出编辑模式时窗口跟着关掉：链路一断，表上的读数就成了假的。
    func editModeEnded() {
        if isVisible { close() }
    }
}

// MARK: - 电平表数据
//
// 峰值保持 1.5 s，然后以 20 dB/s 回落；Peak dBFS 一直攒着，直到被点掉（仿 Logic）。
// 读数不走 @Published：那一条会让整块面板重画一次。
// 闪烁有两处根因，都实测过：一是面板被高频重画（表改 CALayer、读数各订各的，进度条上的
// 指针也不再被抢），二是抽头的交付节奏（本机一包 4410 帧 = 100 ms），问得比它快就有一
// 半是空手，空手被当成静音就每包塌一次 —— 现在空手那一拍保持上一读数。
// 慢的根因是第三件事：旧版把整包压成一个峰值，表最快也就 10 Hz 换值。现在抽头按 5 ms
// 切子窗排队，表提到 60 Hz 按流逝时间去取窗，直上、约 120 ms 指数释放。held 只喂顶端那
// 条白线，柱长和颜色跟着 current 走，所以色彩是快的。

/// 收电平读数的人：表和 Peak 读数各订一份，值来了自己画。
protocol MeterObserver: AnyObject {
    func metersDidRefresh(_ snapshot: MixerMeters.Snapshot)
}

final class MixerMeters {
    struct Lane {
        var current: Double = -96
        var held: Double = -96
        var heldAt = Date()
        var peak: Double = -96
        /// 上一次真正取到子窗的时刻。拿不到的那一拍要留着上一读数，不能当静音 ——
        /// 当静音就是每包闪一下。
        var lastFresh = Date.distantPast
        /// 攒着还没换成窗数的时间。60 Hz 一拍是 16.7 ms，子窗 5 ms，所以正常一拍取 3 个
        /// （15 ms），剩下那点零头留在这儿，攒够下一拍就取 4 个：表的走速对上音频的走速，
        /// 不会因为定时器抖动而越拖越远。
        var due = 0.0
    }
    struct Snapshot { let a: Lane; let b: Lane }

    /// 这么久都没有新样本，就当这一轨真的没声了（暂停、卸插件、没接上）。
    static let staleAfter: TimeInterval = 0.3
    /// 回落的时间常数：一拍 16.7 ms 就走掉 13%，几拍之内贴住新目标，但又不像定斜率那样
    /// 看着像爬楼梯。
    static let releaseSeconds: Double = 0.120
    /// 攒窗的上限：界面问得太慢时也不许越积越多，够吸收调度抖动就行。
    static let dueCap: Double = 0.05
    private var laneA = Lane()
    private var laneB = Lane()
    private let peakA = PeakDisplay()
    private let peakB = PeakDisplay()
    private let observers = NSHashTable<AnyObject>.weakObjects()

    private var timer: Timer?
    private var lastTick = Date()
    /// 子窗长度，由引擎那一拍带回来（跟着采样率走）。第一包之前用不到，先按 5 ms 兜底。
    private var windowSeconds = AudioEngine.meterWindowSeconds

    #if DEBUG
    /// 取数侧的账，发布二进制不含。表比音频慢一整截只有两种来路：抽头交得比界面取得多，
    /// 或者主线程被压住、定时器来不及按 `dueCap` 取满。`ticks/dtMax/clampedTicks` 一对就分得开。
    private(set) var dbgTicks = 0
    private(set) var dbgDtSum = 0.0
    private(set) var dbgDtMax = 0.0
    private(set) var dbgClampedTicks = 0
    private(set) var dbgTakenTotal = 0
    func dbgResetLedger() {
        dbgTicks = 0; dbgDtSum = 0; dbgDtMax = 0; dbgClampedTicks = 0; dbgTakenTotal = 0
    }
    #endif

    var snapshot: Snapshot { Snapshot(a: laneA, b: laneB) }

    func subscribe(_ observer: MeterObserver) { observers.add(observer) }

    func peakDisplay(_ side: TrackSide) -> PeakDisplay { side == .a ? peakA : peakB }

    func start(vm: PlayerViewModel) {
        guard timer == nil else { return }
        lastTick = Date()
        // 60 Hz 和屏幕同拍。取窗是按时间算的，所以这一档提上去等于把表的重画频率
        // 交给 CALayer 那一级；SwiftUI 那一侧只有 Peak 字符串真变了才发布。
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick(vm: vm)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 点一下 Peak 读数：攒着的峰值归零，从这一刻的电平重新攒。
    func clearPeak(_ side: TrackSide) {
        if side == .a { laneA.peak = -96 } else { laneB.peak = -96 }
        publish()
    }

    private func tick(vm: PlayerViewModel) {
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastTick))
        lastTick = now
        var clamped = false
        for side in [TrackSide.a, .b] {
            var lane = side == .a ? laneA : laneB
            if now.timeIntervalSince(lane.heldAt) > 1.5 {
                lane.held = max(-96, lane.held - 20 * dt)
            }
            let wanted = lane.due + dt
            lane.due = min(Self.dueCap, wanted)
            if wanted > Self.dueCap { clamped = true }
            let count = Int(lane.due / windowSeconds)
            if count > 0 {
                let read = vm.laneWindowsDB(side, count: count)
                if read.taken > 0 {
                    lane.due -= Double(read.taken) * read.windowSeconds
                    windowSeconds = max(0.001, read.windowSeconds)
                    #if DEBUG
                    dbgTakenTotal += read.taken
                    #endif
                    let incoming = read.peakDB
                    lane.lastFresh = now
                    // 直上：新读数高过现值就一步到位。回落走 120 ms 时间常数的指数，
                    // 定斜率在 60 Hz 下看着像爬楼梯，大落差还要拖上一秒。
                    if incoming >= lane.current {
                        lane.current = incoming
                    } else {
                        lane.current = max(-96, incoming
                                          + (lane.current - incoming) * exp(-dt / Self.releaseSeconds))
                    }
                    if incoming >= lane.held {
                        lane.held = incoming
                        lane.heldAt = now
                    }
                    if incoming > lane.peak { lane.peak = incoming }
                } else if now.timeIntervalSince(lane.lastFresh) > Self.staleAfter {
                    lane.current = -96      // 0.3 秒没有新样本：真的停了，落回底
                }
                // 没有新窗又还没超时的话，current 一动不动：抽头 100 ms 才来一包，
                // 空手那一拍当成静音就是那道闪烁。
            }
            if side == .a { laneA = lane } else { laneB = lane }
        }
        #if DEBUG
        dbgTicks += 1
        dbgDtSum += dt
        dbgDtMax = max(dbgDtMax, dt)
        if clamped { dbgClampedTicks += 1 }
        #endif
        publish()
    }

    private func publish() {
        let snapshot = Snapshot(a: laneA, b: laneB)
        peakA.apply(snapshot.a)
        peakB.apply(snapshot.b)
        for case let observer as MeterObserver in observers.objectEnumerator() {
            observer.metersDidRefresh(snapshot)
        }
    }
}

// MARK: - 面板

struct MixerPanel: View {
    @ObservedObject var vm: PlayerViewModel
    let meters: MixerMeters

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ChannelStrip(vm: vm, meters: meters, side: .a)
            VStack(spacing: 8) {
                Spacer().frame(height: 22)
                // 两颗的方向就是名字里那支箭：[A→B] 把 A 抄到 B，[A←B] 把 B 抄到 A。
                // 亮着的那颗跟着当前选中的轨走，亮的是这一条通道被选中时的那层亮灰，
                // 说的都是「这一轨此刻是主动的一方」。
                StripCopyButton(title: "[A→B]", lit: vm.activeTrack == .a) {
                    vm.copyChannelStrip(from: .a, to: .b)
                }
                StripCopyButton(title: "[A←B]", lit: vm.activeTrack == .b) {
                    vm.copyChannelStrip(from: .b, to: .a)
                }
                if let error = vm.pluginError {
                    // 装不上的原话：点一下收掉，下次装载也会覆盖它。
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(.abOrange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 60, alignment: .leading)
                        .onTapGesture { vm.pluginError = nil }
                }
                Spacer()
            }
            .controlSize(.small)
            .fixedSize()
            ChannelStrip(vm: vm, meters: meters, side: .b)
        }
        .padding(10)
        // 492 = 两条通道条各 202 + 中间两颗抄送键 56 + 两道 6 的间距 + 10 的边。
        // 和 MixerPanelController.open 里那枚 contentMinSize 同一笔账。
        .frame(minWidth: 492, minHeight: 330)
        .sheet(item: $vm.browserTarget) { target in
            PluginBrowser(vm: vm, target: target)
        }
    }
}

/// 两条通道条中间那两颗抄送键。整块都是判定区（不是只有字）。
/// 亮起来用的是这一条通道被选中时同一种亮灰 —— 高亮说的是「这一轨是主动的一方」，
/// 不是「往左搬还是往右搬」，所以不借主窗口 A/B 那颗的彩色。
private struct StripCopyButton: View {
    let title: String
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 56)
        .background(lit ? Color(white: 1, opacity: 0.22) : Color(white: 0.25))
        .foregroundColor(.white)
        .cornerRadius(3)
    }
}

// MARK: - 一条通道条

struct ChannelStrip: View {
    @ObservedObject var vm: PlayerViewModel
    let meters: MixerMeters
    let side: TrackSide

    @State private var renaming = false
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private var preGain: Double { side == .a ? vm.preGainA : vm.preGainB }
    private var fader: Double { side == .a ? vm.laneFaderA : vm.laneFaderB }
    private var pan: Int { side == .a ? vm.panA : vm.panB }
    private var track: Track? { side == .a ? vm.trackA : vm.trackB }

    var body: some View {
        VStack(spacing: 6) {
            preGainRow
            panRow
            HStack(alignment: .bottom, spacing: 4) {
                // 推子/表上面的文字带取 20 pt 高 —— 槽列是
                // 「一格 20 + 缝 4」，所以 20 的带子把字压在第 1 格的重心（10 pt）上，
                // 带子的下沿又正好是第 1、2 格之间那道缝的上沿，推子和表就从那儿起。
                // 两列都拉满高度（alignment: .top），底下才齐到槽列的底部。
                VStack(spacing: 0) {
                    faderValue
                        .frame(height: 20)
                    HStack(alignment: .top, spacing: 0) {
                        // 推子只留帽宽 + 1 pt 的边，刻度列（30）才贴得住；groove 在自己的
                        // 列里居中，所以它跟刻度线的间距就是 mixlab 那一笔。
                        VerticalFader(db: Binding(
                            get: { fader },
                            set: { vm.setLaneFader($0, for: side) }
                        ), onGestureBegin: { vm.beginEdit() })
                            .frame(width: 14)
                        FaderTicks()
                            .frame(width: FaderTicksNSView.columnWidth)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minWidth: 44, minHeight: 120, maxHeight: .infinity, alignment: .top)
                VStack(spacing: 0) {
                    PeakReadout(display: meters.peakDisplay(side),
                                onTap: { meters.clearPeak(side) })
                        .frame(width: 46, height: 16)
                        .frame(height: 20)
                    HStack(alignment: .top, spacing: 1) {
                        MeterBar(meters: meters, side: side)
                            .frame(minWidth: 12, minHeight: 120, maxHeight: .infinity, alignment: .top)
                        MeterScale().frame(width: 22)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minWidth: 40, minHeight: 140, maxHeight: .infinity, alignment: .top)
                SlotColumn(vm: vm, side: side)
                    .frame(width: 92)
            }
            .frame(maxHeight: .infinity)
            nameRow
        }
        .padding(6)
        .background(vm.activeTrack == side ? Color(white: 1, opacity: 0.22) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(white: 0.32), lineWidth: 1))
    }

    // pre-gain：黑底，首位的 0 也画成黑色（也就是看不见），非 0 才显出颜色。
    private var preGainRow: some View {
        HStack(spacing: 4) {
            Text("pre-gain")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize()
            Spacer(minLength: 2)
            PreGainReadout(db: Binding(
                get: { preGain },
                set: { vm.setPreGain($0, for: side) }
            ), onGestureBegin: { vm.beginEdit() })
            .frame(width: 66, height: 16)
        }
    }

    private var panRow: some View {
        HStack(spacing: 4) {
            Text("Pan")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize()
            PanSlider(value: Binding(
                get: { Double(pan) },
                set: { vm.setPan(Int($0.rounded()), for: side) }
            ), onGestureBegin: { vm.beginEdit() })
            .frame(height: 16)
            Text(pan == 0 ? "C" : String(format: "%+d", pan))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 26, alignment: .trailing)
                .fixedSize()
        }
    }

    // 推子数值：无底色，精度 0.1。
    private var faderValue: some View {
        FaderValueReadout(db: Binding(
            get: { fader },
            set: { vm.setLaneFader($0, for: side) }
        ), onBeforeCommit: { vm.beginEdit() })
    }

    private var nameRow: some View {
        HStack(spacing: 4) {
            // 原来那行「A轨/B轨」的彩色字，换成走带上同款的圆角
            // 色块，只留字母。边长按给定的 20 pt（也是插件槽那一格的短边），配色沿用走带
            // A/B 那两支 barChipA / barChipB。
            Text(side.rawValue)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.barChipText)
                .frame(width: 20, height: 20)
                .background(side == .a ? Color.barChipA : Color.barChipB)
                .cornerRadius(4)
            if renaming {
                TextField("", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .background(Color(white: 0.25))
                    .cornerRadius(3)
                    .focused($nameFocused)
                    .onSubmit {
                        vm.renameAssignedTrack(side, to: nameDraft)
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
                    .onAppear { nameFocused = true }
            } else {
                Text(track?.displayName ?? "未指派")
                    .font(.system(size: 13))     // 轨道名跟着色块一起增大
                    .foregroundColor(track == nil ? .secondary : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        nameDraft = track?.displayName ?? ""
                        renaming = true
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Peak dBFS

/// Peak 读数单独一份可观察对象：只有字符串真的变了才发布，而且发布的是它自己，
/// 不会像整块面板的 @Published 那样把电平表、推子、插件槽一起重画。
final class PeakDisplay: ObservableObject {
    @Published private(set) var text = "-∞"
    @Published private(set) var clipped = false

    fileprivate func apply(_ lane: MixerMeters.Lane) {
        let next = lane.peak >= 0 ? String(format: "+%.1f", lane.peak)
            : (lane.peak <= -95.5 ? "-∞" : String(format: "%.1f", lane.peak))
        if next != text { text = next }
        let over = lane.peak >= 0
        if over != clipped { clipped = over }
    }
}

private struct PeakReadout: View {
    @ObservedObject var display: PeakDisplay
    let onTap: () -> Void

    var body: some View {
        Text(display.text)
            .font(.system(size: 11, design: .monospaced))   // B6：跟 pre-gain 的数字同号
            .foregroundColor(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 黑底同款（radius 2）。旁通红底仍然盖满整块，
            // 「顶了格」这件事比原来那一条窄红更显眼。
            .background(display.clipped ? Color.red.opacity(0.85) : Color.black)
            .cornerRadius(2)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .help("Peak dBFS：≥0 时红底提醒，点击清除")
    }
}

// MARK: - 电平表
//
/// 表的纵轴按 dB 线性铺开：−60 在底、0 dBFS 在顶，所以中段（最要紧的那 20 dB）看得见。
/// 0 以上不留位置：数字域里那一段永远不会真的响出来，画出来只是把有用刻度挤扁。
/// 推子继续用 GainFaderScale 那套 40 dB/十倍：表要的是读数，推子要的是拧得准。
enum MeterScaleLaw {
    static let topDB = 0.0
    static let bottomDB = -60.0
    static func fraction(_ db: Double) -> CGFloat {
        CGFloat(max(0, min(1, (db - bottomDB) / (topDB - bottomDB))))
    }
}

private struct MeterBar: NSViewRepresentable {
    let meters: MixerMeters
    let side: TrackSide

    func makeNSView(context: Context) -> MeterBarNSView {
        let v = MeterBarNSView()
        v.side = side
        meters.subscribe(v)
        v.metersDidRefresh(meters.snapshot)   // 挂上就先给一帧，不用等下一拍
        return v
    }

    func updateNSView(_ v: MeterBarNSView, context: Context) { v.side = side }
}

/// 表用 CALayer 画：一条满高的绿-黄-红渐变，靠 mask 的下沿决定露出多少。
/// 换成 SwiftUI 的话，每 60 Hz 一次的值变化会把整块面板卷进同一次重画里，
/// 那一下就是「闪黑后重绘」，进度条上的指针也是在那一下被抢成箭头。
final class MeterBarNSView: NSView, MeterObserver {
    var side: TrackSide = .a { didSet { if oldValue != side { needsLayout = true } } }

    private let gradient = CAGradientLayer()
    private let reveal = CALayer()
    private let holdLine = CALayer()
    private var currentFraction: CGFloat = 0
    private var heldFraction: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        root.cornerRadius = 1
        root.masksToBounds = true
        // 颜色跟着刻度走，不跟着柱长走：满柱时顶端才是红。
        gradient.colors = [NSColor.abGreen,
                           NSColor(srgbRed: 0xE8/255.0, green: 0xD8/255.0, blue: 0x3A/255.0, alpha: 1),
                           NSColor.abOrange,
                           NSColor.red].map { $0.cgColor }
        gradient.locations = [0, 0.62, 0.85, 1]
        gradient.startPoint = NSPoint(x: 0.5, y: 0)
        gradient.endPoint = NSPoint(x: 0.5, y: 1)
        // 遮罩看的是 alpha，透明的层等于把整条渐变都裁掉，所以 reveal 必须是不透明的。
        reveal.backgroundColor = NSColor.white.cgColor
        gradient.mask = reveal
        root.addSublayer(gradient)
        holdLine.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        root.addSublayer(holdLine)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }   // 层坐标和视图坐标一样：原点左下，柱从底往上长

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        place()
    }

    func metersDidRefresh(_ snapshot: MixerMeters.Snapshot) {
        let lane = side == .a ? snapshot.a : snapshot.b
        currentFraction = MeterScaleLaw.fraction(lane.current)
        heldFraction = MeterScaleLaw.fraction(lane.held)
        // 直接摆层，不等布局周期：60 Hz 的读数到了就该上屏。
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 值就是值，别让它自己补 0.25 s 的间
        // 渐变铺满整条表，柱长交给 reveal 裁：这样颜色钉在刻度上，短柱顶端不会是绿的。
        gradient.frame = bounds
        reveal.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * currentFraction)
        holdLine.frame = NSRect(x: 0, y: bounds.height * heldFraction - 0.75,
                                width: bounds.width, height: 1.5)
        CATransaction.commit()
    }
}

/// 表右侧的数字刻度，仿 Logic 的间距。
private struct MeterScale: View {
    private let marks = [0.0, -6.0, -12.0, -24.0, -48.0]

    var body: some View {
        GeometryReader { geo in
            ForEach(marks, id: \.self) { db in
                Text(String(format: "%d", Int(db)))
                    .font(.system(size: 8))
                    .foregroundColor(Color(white: 0.6))
                    .position(x: geo.size.width / 2,
                              y: min(max(geo.size.height * (1 - MeterScaleLaw.fraction(db)), 5),
                                     geo.size.height - 5))
            }
        }
    }
}

/// 推子和电平表之间的刻度：贴紧推子描线，整档带数字。
/// 照 mixlab 的量表：列宽 30、线长 7、次线 ×0.55、数字 9 pt 白 0.55；
/// 纵轴跟推子共用同一笔 groove 账，所以线头和帽子一定齐。
private struct FaderTicks: NSViewRepresentable {
    func makeNSView(context: Context) -> FaderTicksNSView { FaderTicksNSView() }
    func updateNSView(_ v: FaderTicksNSView, context: Context) {}
}

final class FaderTicksNSView: NSView {
    static let columnWidth: CGFloat = 30
    static let tickLength: CGFloat = 7
    /// 只有 0 和 −∞ 是长线？不 —— mixlab 那条判据是「整十或 0 以上算主刻度」，
    /// −5 是唯一的一条次刻度。
    private static let marks: [Double] = [10, 5, 0, -5, -10, -20, -30, -50, -96]

    override func draw(_ r: NSRect) {
        let g = VerticalFaderNSView.grooveRect(in: bounds)
        guard g.height > 1 else { return }
        let grey = NSColor(white: 0.55, alpha: 1)
        for t in Self.marks {
            let y = (g.minY + GainFaderScale.position(for: t) * g.height).rounded()
            let major = t >= 0 || abs(t) >= 10 || t <= GainFaderScale.minDB + 1
            let len = major ? Self.tickLength : Self.tickLength * 0.55
            // 刻度线改成填一格高的矩形，不再 stroke。stroke 的线心落在整数行上，
            // 1 pt 的墨被劈成上下两行 —— 实测（AB_TICK_CHECK，逐行量位图）长线（7 pt）两行
            // 都只有 0.27，短线（−5 那根 3.85 pt）两行却有 0.50：整张表上最亮的一根线是 −5，
            // 用户眼里的「白色高亮那一格」就这样跑到 −5 去了。填矩形是一整行铺满，长短两档
            // 都回到 0.55，亮度归线本身；0 那一线照话给纯白（量到 1.00）。
            (t == 0 ? NSColor.white : grey).setFill()
            NSRect(x: 0, y: y, width: len.rounded(), height: 1).fill()
            // −5 是唯一一条次刻度，线照旧短，但字要补上。
            guard major || t == -5 else { continue }
            let label = t <= GainFaderScale.minDB + 1 ? "-∞"
                : (t > 0 ? String(format: "+%.0f", t) : String(format: "%.0f", t))
            let attr = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                // 0 dB 那一格纯白高亮，其余仍是白 0.55。
                .foregroundColor: t == 0 ? NSColor.white : grey,
            ])
            attr.draw(at: NSPoint(x: Self.tickLength + 5, y: y - attr.size().height / 2))
        }
    }

#if DEBUG
    /// 探针（AB_TICK_CHECK）：白色高亮到底落在哪一条刻度上。
    ///
    /// 上一版走的是 `bitmapImageRepForCachingDisplay` —— 那张位图的底色是未初始化的，
    /// 没画过的地方也能读出「白」（不看 alpha 就更是如此），量出来的白带压根不含 0 那一行，
    /// 等于白量。现在自己造一张 8 bit RGBA、先涂成不透明的黑：凡是白的都是真画上去的。
    ///
    /// 再一条：认线不认我自己的换算。先在左边那条窄窄的「线区」（x 0…7）逐行找灰，
    /// 灰行堆出来的就是真画上去的刻度线在第几行；然后拿同一批行的右边「数字区」（x 11…）
    /// 数白与灰。哪一行的字是白的，一目了然，也不用信我算的 y。
    func debugScaleReport(label: String) -> [String] {
        var lines: [String] = ["\(label) 视图 \(Int(bounds.width))×\(Int(bounds.height))"]
        let wide = Int(bounds.width), high = Int(bounds.height)
        guard wide > 12, high > 20,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: wide * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            lines.append("造不出位图")
            return lines
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()

        func band(_ py: Int, _ xs: Range<Int>) -> (ink: Int, white: Int, grey: Int, peak: CGFloat) {
            var ink = 0, w = 0, m = 0, peak: CGFloat = 0
            for px in xs where px >= 0 && px < wide {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.5 else { continue }
                let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if lum > 0.12 { ink += 1 }
                peak = max(peak, lum)
                if lum > 0.9 { w += 1 } else if lum > 0.4 { m += 1 }
            }
            return (ink, w, m, peak)
        }
        let lineStrip = 0..<Int(Self.tickLength) + 1
        let labelStrip = Int(Self.tickLength) + 4..<wide
        // 2) 每一档算出来该画在哪一行（跟 draw 同一笔账）。
        var expect: [String] = []
        for t in Self.marks { expect.append("档\(String(format: "%+.0f", t)) y=\(debugMarkY(t))") }
        lines.append("算出来的档行 " + expect.joined(separator: " "))
        // 3) 不预设阈值结论：把有墨的行原样列出来（线区、字区分开），谁配谁看得见。
        var lineRows: [String] = []
        var whiteRows: [String] = []
        for py in 0..<high {
            let l = band(py, lineStrip), d = band(py, labelStrip)
            if l.ink > 0 {
                lineRows.append("线 行\(py)(y=\(Int(bounds.height) - 1 - py)) 墨=\(l.ink) 峰=\(String(format: "%.2f", l.peak))")
            }
            if d.white > 0 {
                whiteRows.append("白 行\(py)(y=\(Int(bounds.height) - 1 - py)) 白=\(d.white) 灰=\(d.grey)")
            }
        }
        lines.append("线行：" + (lineRows.isEmpty ? "一条都没有" : lineRows.joined(separator: " ")))
        lines.append("白字行：" + (whiteRows.isEmpty ? "一行都没有" : whiteRows.joined(separator: " ")))
        // 4) 每一档的字：白/灰各多少个，峰亮多少。线区同量一遍 —— 谁最亮要看线，不看字。
        for t in Self.marks {
            let center = Int((bounds.height - 1 - debugMarkY(t)).rounded())
            var w = 0, m = 0, peak: CGFloat = 0, linePeak: CGFloat = 0, lineWhite = 0
            for py in max(0, center - 5)...min(high - 1, center + 5) {
                let b = band(py, labelStrip), l = band(py, lineStrip)
                w += b.white; m += b.grey; peak = max(peak, b.peak)
                linePeak = max(linePeak, l.peak); lineWhite += l.white
            }
            lines.append("档\(String(format: "%+.0f", t)) 字 白=\(w) 灰=\(m) 峰=\(String(format: "%.2f", peak))"
                + "｜线 白=\(lineWhite) 峰=\(String(format: "%.2f", linePeak))")
        }
        return lines
    }

    /// 某一档按 draw 同一笔账画在视图哪一行。
    private func debugMarkY(_ db: Double) -> CGFloat {
        let g = VerticalFaderNSView.grooveRect(in: bounds)
        return (g.minY + GainFaderScale.position(for: db) * g.height).rounded()
    }
#endif
}

// MARK: - 插件槽与拖拽调序

/// 拖拽调序的在途记账：谁被拿起来了、鼠标此刻悬在哪一格。
/// 源和落点都在同一个进程里，所以链子的事认这一份账，不认粘贴板 —— 绕一圈字符串反而
/// 丢掉只在此刻成立的状态（「这一格正在装」「这一格还被插件占着」）。粘贴板上照旧写一份
/// 格号（payload），那是拖拽会话要有 item 才肯起飞的门槛，也是探针看日志时能读的凭据。
final class SlotDrag: ObservableObject {
    static let shared = SlotDrag()

    /// 落格淡化的时长：一帧 16.7 ms 的十分来一秒，够把「药丸没了、格子变了」缝成一件事，
    /// 又不至于让人觉得插件是慢慢长出来的。
    static let settle = Animation.easeOut(duration: 0.18)

    /// 拖的是哪一格，写成一句看得懂的话。
    static func payload(_ ref: SlotTarget) -> String { "ab-slot:\(ref.side == .a ? "a" : "b"):\(ref.index)" }

    /// 被拿起来的那一格（nil = 此刻没在拖）。
    @Published var source: SlotTarget?
    /// 鼠标此刻悬着的那一格，只在拖拽途中有意义：落点靠它描圈。
    @Published var hovering: SlotTarget?

    /// 松手那一下按没按 ⌥：按了就是复制（源格原样留着），没按就是搬。
    static func isCopy(_ flags: NSEvent.ModifierFlags) -> Bool {
#if DEBUG
        if debugForceCopy { return true }
#endif
        return flags.contains(.option)
    }

    func begin(_ ref: SlotTarget) {
        source = ref
        hovering = nil
    }

    /// 落格之后把账清掉。
    func end() {
        source = nil
        hovering = nil
    }

    /// 拖到别处取消的那一趟没人清账：SwiftUI 的 onDrag 只有 preview/itemProvider 两支，
    /// 没有「会话结束」的回调可挂。留着的话，下一次有别的程序往格子上拖一段文字，那份
    /// 旧账会被当成一次落格去动链子。
    /// 借混音器自己的鼠标事件当实证：拖拽途中 AppKit 不给视图发 mouseEntered/mouseMoved
    /// （事件全被拖拽会话吃了），而那时候左键还按着 —— 两条一起看，清不错。
    func expireIfIdle() {
        guard source != nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        end()
    }

#if DEBUG
    /// 这台机器注入不了全局修饰键（同 ⌘ 那一条），所以探针留一枚开关，让「⌥ 复制」
    /// 这一头也能在自动验证里走到。Release 里没有这条路。
    static var debugForceCopy = false
#endif
}

// MARK: - 插件槽

/// 六格插件链 + 整轨旁通。空槽点一下就开浏览器；装上的插件用 #266EB8 写字，
/// 左边那颗是单格 bypass，右边的 ✕ 卸掉。载入色 #266EB8，bypass 激活色
/// 和范围播放那颗一致（abOrange）。
private struct SlotColumn: View {
    @ObservedObject var vm: PlayerViewModel
    let side: TrackSide

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<AudioEngine.slotCount, id: \.self) { index in
                SlotCell(vm: vm, state: vm.slots(side)[index], side: side, index: index)
            }
            Button(action: { vm.toggleLaneBypass(side) }) {
                Text("Bypass")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(vm.laneBypass(side) ? Color.abOrange : Color(white: 0.25))
            .foregroundColor(.white)
            .cornerRadius(3)
            // 预设按钮各轨道一个，摆在同一条槽列的最下面。存的是这一整条通道条
            // （pre-gain、推子、声像、整轨旁通、六格和它们的旋钮）。不再开访达：
            // 载入是直接把「轨道预设」里现成的 .abpreset 列成二级菜单点，默认档另有进出两条。
            Menu {
                Menu("载入预设") {
                    let presets = ProjectStore.channelPresets()
                    if presets.isEmpty {
                        Button("尚未保存任何预设") {}.disabled(true)
                    } else {
                        ForEach(presets, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                vm.applyChannelPreset(at: url, for: side)
                            }
                        }
                    }
                }
                // 名字手写，重名先问覆盖（不自动加编号）。落在「载入预设」
                // 读的那同一个文件夹，所以存完下一次就能在这儿点到。
                Button("保存预设") { vm.saveChannelPresetNamed(for: side) }
                Button("恢复默认预设") { vm.restoreDefaultPreset(for: side) }
                    .disabled(!ProjectStore.hasDefaultPreset(for: side))
                Divider()
                Button("移除全部插件") { vm.removeAllPlugins(for: side) }
                Button("保存当前预设为默认") { vm.saveDefaultPreset(for: side) }
            } label: {
                Text("预设")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .background(Color(white: 0.25))
            .foregroundColor(.white)
            .cornerRadius(3)
            .help("载入预设 / 保存预设 / 恢复默认预设 / 移除全部插件 / 将该轨设定存为默认")
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SlotCell: View {
    @ObservedObject var vm: PlayerViewModel
    let state: SlotState
    let side: TrackSide
    let index: Int

    /// 拖拽的在途状态（谁被拿起来、悬在哪一格）。整片格子共用一份，谁都不用存副本。
    @ObservedObject private var drag = SlotDrag.shared

    private var loaded: Bool { state.plugin != nil }
    private var ref: SlotTarget { SlotTarget(side: side, index: index) }

    var body: some View {
        cell
            // 拿起来的那一格半透明，并且要「鼠标正悬在某一格上」才画：取消掉的那一趟没有
            // 结束回调可挂，而 hovering 是 AppKit 保证会给回 false 的（离开目标区就
            // draggingExited），它一空这格就复原，不会一直灰着。
            .opacity(dimmed ? 0.35 : 1)
            .overlay(dropRing)
            .onDrop(of: [.utf8PlainText], isTargeted: hoverBinding, perform: dropped)
            .modifier(SlotDragSource(armed: loaded && !state.loading,
                                      name: state.plugin?.name ?? "", ref: ref))
            // 落定的那一段淡化（方案 B）：谁在这一格、装没装完、旁没旁通、是不是落点、
            // 有没有被拿着 —— 这几样任一变化就走 0.18 s 的 easeOut。系统那张拖拽药丸
            // 什么时候没我们管不着（实测 perform 栈里只压 0.3~3.6 ms，剩下全是 AppKit
            // 自己撕 preview 的收尾），但它消失的那一刻格子里已经在淡入落定了。
            .animation(SlotDrag.settle, value: settleKey)
    }

    private var dimmed: Bool { drag.source == ref && drag.hovering != nil }

    /// 淡化只认这一格自己的样子，不认电平表那种每帧都变的读数。
    private var settleKey: String {
        "\(state.plugin?.id ?? "-")|\(state.bypass ? 1 : 0)|\(state.loading ? 1 : 0)"
            + "|\(ringOn ? 1 : 0)|\(dimmed ? 1 : 0)"
    }

    /// 格子本体。拖拽和落点都挂在这上面（见 body），所以先把它单独摘出来。
    private var cell: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(Color(white: 0.45), lineWidth: 1)
            // 装上就整块填蓝、字是白的；旁通时把蓝压暗一档，⏻ 那颗转橙。
            .background(fill)
            .frame(height: 20)
            .overlay(content: { content })
            .background(SlotCursor(eraserEligible: loaded))
            .contentShape(Rectangle())
            .onTapGesture(perform: tapped)
            // 提示写的是「按下哪把键打开这一格」：A 轨那一列是裸数字，B 轨那一列要加 ⇧。
            .help(loaded
                  ? "点击打开插件界面（\(side == .a ? "\(index + 1)" : "⇧\(index + 1)")）· ⌘ 点击 = 移除"
                    + " · 拖动 = 调序（按住 ⌥拖动 = 复制）"
                  : "点击加载插件")
    }

    private var fill: Color {
        guard loaded else { return Color(white: 0.18) }
        return state.bypass ? Color.abMixBlue.opacity(0.35) : Color.abMixBlue
    }

    /// 落点描一圈绿的**外框**：绿是「松手就落在这儿」，画在格子外面才不遮住它自己的边线
    /// （负边距把描边扩到 bounds 之外）。
    /// 圈常驻、靠 opacity 有无：if/else 画出来的圈是整枚子视图的插入与移除，`.animation`
    /// 追不上它，落定那一下还是硬闪；改成同一枚描边淡入淡出，才接得住系统那张拖拽药丸。
    private var dropRing: some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(Color.green, lineWidth: 2)
            .padding(-3)
            .opacity(ringOn ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var ringOn: Bool {
        drag.hovering == ref && drag.source != nil && drag.source != ref && !state.loading
    }

    private var hoverBinding: Binding<Bool> {
        Binding(get: { drag.hovering == ref },
                set: { inside in
                    if inside { drag.hovering = ref } else if drag.hovering == ref { drag.hovering = nil }
                })
    }

    /// 松手。⌥ 按着就是复制（源格不动，落点按源的身份和参数重新实例化）。
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        // providers 一个字都不读：格号在进程内那一份账上，比粘贴板准，而且「这一格还在装」
        // 那种只在此刻成立的状态，粘贴板也带不来。别的程序拖一段文字进来确实会走到这一关，
        // 挡它的是 expireIfIdle：上一次取消掉的拖拽留下的那份旧账，鼠标一回到混音器就清了。
        guard let source = drag.source, source != ref, !state.loading,
              !vm.slots(source.side)[source.index].loading else { return false }
        vm.applySlotDrag(from: source, to: ref, copy: SlotDrag.isCopy(NSEvent.modifierFlags))
        SlotDrag.shared.end()
        return true
    }

    @ViewBuilder private var content: some View {
        if state.loading {
            // 空槽平时什么都不写（六格排下来「空槽 3」是噪声），只有真在装的时候给个进度。
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                Text("载入中").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .transition(.opacity)      // 和下面那行插件名交替时交叉淡，别硬换
        } else if let plugin = state.plugin {
            loadedRow(plugin).transition(.opacity)
        }
    }

    private func tapped() {
        guard loaded else { vm.openBrowser(for: index, side: side); return }
        if NSEvent.modifierFlags.contains(.command) {
            vm.unloadSlot(index, for: side)          // 橡皮擦：只擦，不重开浏览器
        } else {
            vm.toggleSlotEditor(index, for: side)    // 点槽身 = 这一格的插件界面
        }
    }

    private func loadedRow(_ plugin: AUPlugin) -> some View {
        HStack(spacing: 2) {
            // 单格 bypass：按下去就灰掉，和整轨那颗一样用 abOrange 提醒「旁通中」。
            Button(action: { vm.toggleSlotBypass(index, for: side) }) {
                Image(systemName: "power")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(state.bypass ? .abOrange : .white)
                    .frame(width: 11, height: 14)
            }
            .buttonStyle(.plain)
            Text(plugin.name)
                .font(.system(size: 9))
                .foregroundColor(state.bypass ? Color(white: 0.72) : .white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { vm.unloadSlot(index, for: side) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Color(white: 0.85))
                    .frame(width: 11, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 拖拽起飞的格子

/// 只有装着插件、又不正在装的格子起得来拖拽：空槽硬拖会拖出一张「什么都没有」的图像，
/// 落点又只认进程内那一份账，白闪一下不如不给拖。
/// 拖拽图像自己画一枚小药丸（插件名），不用系统默认的整格截图 —— 那张里带着 ⏻ 和 ✕
/// 两颗按钮，拖起来像是把一整格控件拿在手上。
private struct SlotDragSource: ViewModifier {
    let armed: Bool
    let name: String
    let ref: SlotTarget

    func body(content: Content) -> some View {
        if armed {
            content.onDrag({
                SlotDrag.shared.begin(ref)
                return NSItemProvider(object: SlotDrag.payload(ref) as NSString)
            }, preview: {
                // 起飞提示画在药丸上：一圈绿和落点外框同一句话（「拿着的就是要落下去的
                // 那个」），加一道投影把它从格子上抬起来。指针换不成 —— 拖拽会话一开，
                // NSCursor 就归 AppKit 管了（实测见记忆 abplayer-pointer-event-verification）。
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.abMixBlue))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.green, lineWidth: 1.5))
                    .shadow(color: Color.black.opacity(0.5), radius: 2.5, x: 0, y: 2)
            })
        } else {
            content
        }
    }
}

// MARK: - ⌘ 与橡皮擦指针

/// 指针走**整片插件槽一个判定区**，和进度条上 ⌘ 切框选工具同一套做法（那套实测稳）：
/// 矩形常驻在真正被命中的宿主视图上，指针摆哪颗由「鼠标此刻在哪一格 + ⌘ 按没按」现算。
/// 一路走来的三个坑，都实测过：只在 ⌘ 按下时才加矩形、靠一个镜像布尔 —— 漏掉一次松开就
/// 永久错位（「闪几下再也不出来」）；逐格记状态 —— ⌘ 按住挪到空槽不松手、在空槽按下 ⌘
/// 再挪到已用槽又上不来（用户报的这两条）；矩形登记在格子上 —— hitTest 命中的是宿主视图，
/// 那枚矩形永远轮不到（「橡皮擦不显示，但 ⌘+点仍能擦」）。
private struct SlotCursor: NSViewRepresentable {
    /// 这一格装着插件（只有装了的格子才谈得上擦）。
    var eraserEligible: Bool

    func makeNSView(context: Context) -> SlotCursorNSView {
        let v = SlotCursorNSView()
        v.eraserEligible = eraserEligible
        return v
    }

    func updateNSView(_ v: SlotCursorNSView, context: Context) { v.eraserEligible = eraserEligible }
}

/// 混音器整扇内容都由这枚宿主视图自己画，AppKit 查「鼠标底下是谁」时命中的也是它，
/// 挂在格子那层的光标矩形因此永远轮不到 —— 实测 hitTest 返回的就是这枚视图本身，
/// 而 `NSCursor.set()` 摆上去的橡皮擦会在 1.2 秒内被矩形表按回箭头。
/// 结论：⌘ 按着时的那枚矩形、以及整片插件槽的判定区，都得建在这颗真正被命中的视图上。
final class MixerHostingView<Content: View>: NSHostingView<Content> {
    private var trackingArea: NSTrackingArea?

    override func resetCursorRects() {
        super.resetCursorRects()
#if DEBUG
        SlotCursors.debugResets += 1
#endif
        SlotCursors.installEraserRects(in: self)
    }

    // 判定区和进度条上 ⌘ 切框选工具同一套做法（ProgressBarView 实测稳）：区域常驻，矩形
    // 整片加在宿主视图上，指针摆哪颗由「鼠标此刻在哪一格 + ⌘ 按没按」现算。
    // 旧写法逐格记状态，两条毛病就是这么来的：⌘ 按住从有插件的格子挪到空槽不松手（那一格
    // 根本没登记矩形，跨不出去）；在空槽上按 ⌘、之后再挪到有插件的格子也不上膛（矩形表是
    // 按下那一刻算的，此后没人重算）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // 混音器这扇窗实测 key=false，用 .activeInKeyWindow 就一台事件都收不到。
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        SlotDrag.shared.expireIfIdle()
        SlotCursors.evaluateEraser(flags: event.modifierFlags, screenPoint: pointerScreenPoint(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        SlotDrag.shared.expireIfIdle()
        SlotCursors.evaluateEraser(flags: event.modifierFlags, screenPoint: pointerScreenPoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        SlotDrag.shared.expireIfIdle()
        SlotCursors.evaluateEraser(flags: event.modifierFlags, screenPoint: pointerScreenPoint(for: event))
    }

    /// 指针位置拿事件自带的那一份，不查全局的 `NSEvent.mouseLocation`：真鼠标到了这里两者
    /// 一模一样，而探针注入的事件只有 locationInWindow 是自己写的 —— 判位置要看事件，
    /// 否则探针投到格子上的移动会被判成「鼠标还在别处」。
    private func pointerScreenPoint(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

/// 一格一个：只作证「这一格装着插件、它在屏幕上哪儿」。指针不逐格摆 —— 那归上面的判定区。
final class SlotCursorNSView: NSView {
    var eraserEligible = false {
        didSet { guard oldValue != eraserEligible else { return }; SlotCursors.refreshAll() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { SlotCursors.register(self) }
    }

    /// 这一格在屏幕坐标里的覆盖范围（左下原点），和 `NSEvent.mouseLocation` 直接对得上。
    var screenFrame: NSRect? {
        guard let window, bounds.width > 1, bounds.height > 1 else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

#if DEBUG
    /// 「橡皮擦未显示，功能正常」这句话里能量的只有链路：格子在不在册、有没有面积、
    /// 它的矩形在屏幕上到底盖不盖得住鼠标、判定区摆过几次指针。
    /// 指针本身拍不进截图，这台机器又注入不了真鼠标，所以只能这样抄表。

    /// 判定区此刻该不该在这一格摆橡皮擦（Debug 里可被强制上膛绕开 ⌘ 检测）。
    func debugShouldErase(mouseScreen: NSPoint) -> Bool {
        guard eraserEligible else { return false }
        let held = SlotCursors.debugForceEraser || NSEvent.modifierFlags.contains(.command)
        return held && screenFrame?.contains(mouseScreen) == true
    }

    /// 这一格在屏幕坐标里的覆盖范围，和 NSEvent.mouseLocation 直接对得上。
    func debugLine(mouseScreen: NSPoint) -> String {
        guard let window else {
            return "格子 无窗口 · bounds \(Int(bounds.width))×\(Int(bounds.height)) · 有插件=\(eraserEligible)"
        }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        var line = "格子 \(Int(onScreen.width))×\(Int(onScreen.height)) 屏幕左上≈"
            + "\(Int(onScreen.minX)),\(Int(onScreen.minY)) · 盖住鼠标=\(onScreen.contains(mouseScreen))"
            + " · 有插件=\(eraserEligible) · 该摆橡皮擦=\(debugShouldErase(mouseScreen: mouseScreen))"
            + " · 窗口「\(window.title)」"
            + " 可见=\(window.isVisible) key=\(window.isKeyWindow)"
        // 矩形表只认「鼠标这一点上最靠前的那一枚视图」。set() 之后指针又被换回箭头，
        // 说的就是另有其人盖在我们头上抢了这颗指针 —— 把命中链打出来才知道是谁。
        if onScreen.contains(mouseScreen) {
            let hit = window.contentView?.hitTest(window.convertPoint(fromScreen: mouseScreen))
            var chain: [String] = []
            var walk = hit
            while let v = walk { chain.append(String(describing: type(of: v))); walk = v.superview }
            line += " · 命中=\(chain.joined(separator: "<")) · 命中即本格=\(hit === self)"
        }
        return line
    }

    /// 探针挪鼠标用：这一格中心在屏幕坐标里的位置（左下原点，正是 CGWarp 要的）。
    var debugScreenCenter: NSPoint? {
        screenFrame.map { NSPoint(x: $0.midX, y: $0.midY) }
    }
#endif
}

/// 整片插件槽一份判定。指针摆哪颗只看两件事：鼠标此刻在哪一格、⌘ 按没按 —— 这里不存
/// 「上一刻是什么」的副本，存了就又会粘（旧写法逐格记状态，两条毛病的根子都在那）。
enum SlotCursors {
    private static let views = NSHashTable<SlotCursorNSView>.weakObjects()

    static func register(_ view: SlotCursorNSView) { views.add(view) }

    /// 某一格的占用变了：矩形表重算，并按鼠标此刻的位置再摆一次。
    static func refreshAll(flags: NSEvent.ModifierFlags? = nil) {
        guard let window = windowOfRecord(), let host = window.contentView else { return }
        window.invalidateCursorRects(for: host)
        evaluateEraser(flags: flags ?? NSEvent.modifierFlags)
    }

    /// 判定区的现算：⌘ 按着 + 鼠标底下这一格装着插件 = 摆橡皮擦；否则只在「刚才摆过橡皮擦」
    /// 的时候把箭头摆回去。
    ///
    /// 为什么收回去要自己动手：我们只给有插件的那几格登记过矩形，指针从那一格挪进空槽不算
    /// 「跨出矩形」，AppKit 不会替我们把指针还原 —— 旧写法就是停在这一步，橡皮擦从此粘在
    /// 空槽上。为什么没上膛时不能每次都摆箭头：整片格子上鼠标每动一下这里都会走到，无条件
    /// 写箭头会把 ✕ 那颗的手型一直按回去。为什么上膛那一头不设「和上次一样就跳过」：AppKit
    /// 会按它自己的表把指针摆回去（实测约 1.2 秒内一次），记的那一份成了假账之后就再也不 set。
    static func evaluateEraser(flags: NSEvent.ModifierFlags, screenPoint: NSPoint? = nil) {
        guard NSApp.isActive else { return }
        let armed = eraserCellUnderMouse(flags: flags,
                                         screenPoint: screenPoint ?? NSEvent.mouseLocation) != nil
#if DEBUG
        debugLastVerdict = armed ? "橡皮擦" : (wasErasing ? "无（刚从橡皮擦收回）" : "无")
#endif
        if armed {
            wasErasing = true
#if DEBUG
            debugEraserSets += 1
            (debugStockCursor ? NSCursor.crosshair : EraserCursor.value).set()
#else
            EraserCursor.value.set()
#endif
        } else if wasErasing {
            wasErasing = false
#if DEBUG
            debugArrowSets += 1
#endif
            NSCursor.arrow.set()
        }
    }
    /// 只记「上一拍这枚橡皮擦是不是我们摆的」，用来决定要不要自己动手收回。
    private static var wasErasing = false

    /// 由宿主视图在 `resetCursorRects()` 里回调：⌘ 真按着才给装着插件的那几格补登矩形，
    /// 没按住时一枚都不加 —— 别的指针（✕ 那颗的手型）是 SwiftUI 自己登记的，别拿矩形盖过去。
    static func installEraserRects(in host: NSView) {
        guard rectsArmed() else { return }
        for view in views.allObjects where view.eraserEligible && view.window === host.window {
#if DEBUG
            debugRectsInstalled += 1
            let cursor: NSCursor = debugStockCursor ? .crosshair : EraserCursor.value
#else
            let cursor = EraserCursor.value
#endif
            host.addCursorRect(view.convert(view.bounds, to: host), cursor: cursor)
        }
    }

    private static func eraserCellUnderMouse(flags: NSEvent.ModifierFlags,
                                             screenPoint: NSPoint) -> SlotCursorNSView? {
        guard commandHeld(flags: flags) else { return nil }
        return views.allObjects.first { $0.eraserEligible && $0.screenFrame?.contains(screenPoint) == true }
    }

    /// ⌘ 按没按，问的是这次递给谁的那份修饰键：鼠标事件自带的是那一下的真值，⌘ 自己按出来
    /// 的走 flagsChanged 也是。Debug 里另有一枚强制上膛的开关（本机伪造不了全局修饰键）。
    private static func commandHeld(flags: NSEvent.ModifierFlags) -> Bool {
#if DEBUG
        if debugForceEraser { return true }
#endif
        return flags.contains(.command)
    }

    /// 矩形表登不登橡皮擦，只看全局 ⌘（AppKit 摆指针时没有事件可问）。探针替不了用户按
    /// 这一下 —— 本机伪造不了全局修饰键 —— 所以留一枚只补登矩形的开关：判定仍读注入
    /// 事件自带的那份 ⌘，两边各管各的，才分得清「判不出 ⌘」和「矩形没登」。
    private static func rectsArmed() -> Bool {
#if DEBUG
        if debugForceRects { return true }
#endif
        return commandHeld(flags: NSEvent.modifierFlags)
    }

    private static func windowOfRecord() -> NSWindow? {
        views.allObjects.first { $0.window != nil }?.window
    }

#if DEBUG
    // 计数器：矩形重算过几次、判定区摆过几次橡皮擦/箭头。指针本身拍不进截图，这台机器又
    // 注不进真鼠标，所以链路上能量的只有这些 —— 外加一张 screencapture -C 带指针的屏。
    static var debugResets = 0
    static var debugEraserSets = 0
    static var debugArrowSets = 0
    /// 往矩形表里登过几枚橡皮擦（累计）。这一枚专门用来区分「判定区算出了橡皮擦」和
    /// 「AppKit 手上真有这颗矩形」—— 只有后者才守得住 1.2 秒。
    static var debugRectsInstalled = 0
    /// 判定区最后一次现算的结果。它读的是递给那一下的事件自带的修饰键（探针注入的那份也算），
    /// 和下面抄表时按全局 ⌘ 重算的那一列不是一回事，别混着看。
    static var debugLastVerdict = "未判过"
    /// 探针要把「⌘ 检测」这一环先摘掉：鼠标能挪，⌘ 在全局状态里却不能伪造（本机没辅助
    /// 功能权限），所以强制上膛之后截一张带光标的屏，才能分清「这颗光标根本摆不出来」和
    /// 「⌘ 没被认出来」。Release 里没有这条路。
    static var debugForceEraser = false
    /// 只补登矩形、不碰判定：注入的事件自带 ⌘ 管判定，这一枚管 AppKit 那张表，两件事
    /// 分开才测得出「判定对了但表里没有」这一格（真按 ⌘ 时两处同时成立）。
    static var debugForceRects = false
    /// 探针替身：把橡皮擦换成系统自带的十字，用来分清「这颗自定义图摆不上屏」和
    /// 「矩形/ set() 这条路压根没走到」。
    static var debugStockCursor = false

    static func debugCountersText() -> String {
        "矩形重算=\(debugResets) · 登进表=\(debugRectsInstalled) 枚 · 摆橡皮擦=\(debugEraserSets) · 收回箭头=\(debugArrowSets)"
    }

    /// 采样一次：鼠标此刻在哪、每一格的矩形覆盖不覆盖它、几个计数器走到哪儿了。
    /// 探针按秒连着抄十几遍，人只要在这段时间里把鼠标停在有插件的格子上按住 ⌘，
    /// 日志就能指出断的是哪一环。
    static func debugSample() -> String {
        let mouse = NSEvent.mouseLocation
        let all = views.allObjects
        let aimed = NSCursor.current === EraserCursor.value ? "橡皮擦"
            : (NSCursor.current === NSCursor.crosshair ? "十字（探针替身已上屏）"
                                                       : (NSCursor.current === NSCursor.arrow ? "箭头" : "不是橡皮擦"))
        var head = "鼠标=\(Int(mouse.x)),\(Int(mouse.y)) · ⌘按下=\(NSEvent.modifierFlags.contains(.command))"
        head += " · 在册=\(all.count) 格 · \(debugCountersText())"
        head += " · 判定=\(debugLastVerdict)（现算全局=\(eraserCellUnderMouse(flags: NSEvent.modifierFlags, screenPoint: mouse) == nil ? "无" : "橡皮擦")）"
        head += " · 橡皮擦图=\(EraserCursor.debugLabel) · 屏幕上此刻=\(aimed)"
        var lines = [head]
        for view in all where view.window != nil {
            lines.append("  · " + view.debugLine(mouseScreen: mouse))
        }
        return lines.joined(separator: "\n")
    }

    /// 第一格「装着插件、又有窗口」的格子中心（屏幕坐标），给探针把鼠标挪过去用。
    static func debugAimedCenter() -> NSPoint? {
        views.allObjects.first { $0.eraserEligible }?.debugScreenCenter
    }

    /// 判定区两条毛病各一头：⌘ 按住挪进有插件的格该上膛、挪进空槽该收回。探针要找的
    /// 就是「装着插件的那一格」和「空着的那一格」，point 是格中心在**所在窗口 base 坐标**
    /// 里的位置 —— `NSEvent.mouseEvent(...)` 的 location 要的就是这个；center 是同一格中心
    /// 的屏幕坐标（左下原点），给 CGWarp 把真鼠标也挪过去用，两边位置对得上才看得出矩形
    /// 表认不认这颗指针。
    static func debugCellTarget(occupied: Bool) -> (window: NSWindow, point: NSPoint, center: NSPoint)? {
        guard let view = views.allObjects.first(where: {
            $0.eraserEligible == occupied && $0.window != nil && $0.bounds.width > 1
        }), let window = view.window, let center = view.debugScreenCenter else { return nil }
        return (window, view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), center)
    }
#endif
}

/// ⌘ 的按下与松开只能从按键监听知道（鼠标常常一动不动）。这里不存状态，只把
/// 「修饰键变了」这件事交给判定区，判定区拿这一下自带的修饰键现算 —— 谁都不会记错。
///
/// 也不做「和上次一样就不通知」的去重：⌘ 按住时切走应用（⌥⌘←、⌘Tab）就收不到
/// 松开那一下，去重表就此定格在「⌘ 还按着」，往后每次真按 ⌘ 都被判成没变。
enum CommandKeys {
    static func flagsChanged(_ event: NSEvent) {
        SlotCursors.refreshAll(flags: event.modifierFlags)
        CommandState.shared.held = event.modifierFlags.contains(.command)
    }
}

/// ⌘ 按没按，给 SwiftUI 侧用的一份现算状态（播放列表的抓手指针、按住 ⌘ 才拖得动
/// 排序）。只有 flagsChanged 会写它，读的一方不存副本 —— 和上面 CommandKeys 那句注释
/// 同一个道理：鼠标常常一动不动，⌘ 松开只能从按键监听知道。
/// 不标 @MainActor：写它的那条路径（事件监听）本身跑在主线程上，但不是隔离上下文，
/// 和 SlotDrag 一个写法。
final class CommandState: ObservableObject {
    static let shared = CommandState()
    @Published var held = false
}

/// 播放列表的抓手指针：⌘ 按着 + 指针停在某一行 = 张开的手，拖起来 = 握拳。
/// 不做「和上次一样就跳过」的去重（AppKit 会在约 1.2 秒内按自己的矩形表把指针摆回箭头，
/// 记的那份副本就成了假账，从此再也上不来 —— 橡皮擦就是这么踩过去的），只记
/// 「上一拍这枚手型是不是我们摆的」，好知道该不该自己收回去。
@MainActor enum PlaylistCursor {
    private static var holding = false

    static func show(_ cursor: NSCursor?) {
        if let cursor {
            holding = true
            cursor.set()
        } else if holding {
            holding = false
            NSCursor.arrow.set()
        }
    }
}

/// AppKit 没有现成的橡皮擦指针，照设计图画一枚：倾斜的圆角矩形、黑色填充、白色描边，
/// 靠头一条分隔带（擦除面和手柄的分界）。这颗只是光标，不进界面资源。
enum EraserCursor {
    static let value: NSCursor = make()

    /// 画布边长。整枚图（含描边）都要落在里面，不然会被裁掉。
    private static let canvas = NSSize(width: 24, height: 24)
    /// 锚点 = 机身「对齐角」斜切之后所在的位置，也就是指针真正「点」到的那一点。
    private static let tip = NSPoint(x: 8, y: 16.1)
    private static let bodySize = NSSize(width: 13.1, height: 8)
    /// 要对齐到锚点的那个角：原始矩形的左上角 (0, 8)。斜 −45° 之后它是最高点，另外三个角
    /// 落在 (2.34, 10.44) / (17.26, 6.84) / (11.61, 1.18)，整颗连同描边都在 24×24 里。
    /// 放在机身外面（比如 (-4, 9.6)）就是「橡皮浮在点旁边 4 px」，点不准。
    private static let bodyCornerInBody = NSPoint(x: 0, y: 8)

    private static func make(scale: CGFloat = 1) -> NSCursor {
        let size = NSSize(width: canvas.width * scale, height: canvas.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        let placed = transform(scale: scale)
        let body = NSBezierPath(roundedRect: NSRect(origin: .zero, size: bodySize),
                                xRadius: 2.2, yRadius: 2.2)
        body.transform(using: placed)
        NSColor.black.setFill()
        body.fill()
        NSColor.white.setStroke()
        body.lineWidth = 1.0 * scale
        body.stroke()
        // 分隔带：白色的一条，两头顶到机身外边再按机身形状裁掉，所以它和白色描边之间
        // 不再有黑缝（之前留 1 px 内缩，看着像一块白方片浮着）。
        // 左上这一整截（机身左端 → 带子外沿 x = 4.5）一起涂白。原来只补
        // 一小块 collar，机身圆角和带子之间剩一个黑尖角；给定的那张图里左上半是整块白的。
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSColor.white.setFill()
        let seamOuterEdge: CGFloat = 4.5          // 带子 x 3.2 + 宽 1.3
        let cap = NSBezierPath(rect: NSRect(x: -2, y: -2, width: seamOuterEdge + 2,
                                            height: bodySize.height + 4))
        cap.transform(using: placed)
        cap.fill()
        NSGraphicsContext.restoreGraphicsState()
        // 描边再压一遍：带子被裁在机身轮廓上，最后这一笔才让白边在两头都不断。
        NSColor.white.setStroke()
        body.lineWidth = 1.0 * scale
        body.stroke()
        image.unlockFocus()
        image.isTemplate = false
        // hotSpot 的 y 要翻一次：画布是 lockFocus 的 y 向上，而 NSCursor 的热点从上边往下量
        // （实测：系统箭头 17×23、hotSpot (4,4)，它的尖正好在从上数第 4 行；手型 32×32、
        // hotSpot (13,8)，指尖在从上第 8 行）。不翻的话整块橡皮浮在鼠标点上方 13.8 px，
        // 就是「⌘ 一按下去点不准」的那个偏。
        return NSCursor(image: image, hotSpot: NSPoint(x: tip.x * scale,
                                                       y: (canvas.height - tip.y) * scale))
    }

    /// 顺时针斜 45°，再把机身最上角平移到 tip；scale 只给探针放大用，几何量一起乘。
    private static func transform(scale: CGFloat = 1) -> AffineTransform {
        let angle = -45.0 * Double.pi / 180
        let rotated = NSPoint(x: bodyCornerInBody.x * cos(angle) - bodyCornerInBody.y * sin(angle),
                              y: bodyCornerInBody.x * sin(angle) + bodyCornerInBody.y * cos(angle))
        var xf = AffineTransform()
        xf.translate(x: (tip.x - rotated.x) * scale, y: (tip.y - rotated.y) * scale)
        xf.scale(x: scale, y: scale)
        xf.rotate(byRadians: angle)
        return xf
    }

#if DEBUG
    /// 探针要知道自己拿到的是橡皮擦还是回退的手型：这台机器没法模拟鼠标，指针只能这样验。
    static var debugLabel: String {
        "\(Int(value.image.size.width))×\(Int(value.image.size.height)) 图 · 热点 "
            + "\(Int(value.hotSpot.x)),\(Int(value.hotSpot.y))"
    }

    /// 光标拍不进截图，所以放大八倍画成一张 PNG 落盘，和设计图对一眼。
    static func debugWriteImage(to path: String) {
        let cursor = make(scale: 8)
        guard let tiff = cursor.image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// 八倍那张只证明画法对，屏幕上用的其实是 1× 这一枚：尺寸、位深、有没有 alpha
    /// 都得单独量，否则「图是对的」和「指针是看得见的」还是两回事。
    static func debugValueImageInfo() -> String {
        let image = value.image
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return "橡皮擦 1×: 取不到位图"
        }
        return "橡皮擦 1×: 点 \(Int(image.size.width))×\(Int(image.size.height)) · "
            + "像素 \(rep.pixelsWide)×\(rep.pixelsHigh) · 位深 \(rep.bitsPerPixel) · "
            + "带 alpha=\(rep.hasAlpha) · 不透明像素=\(debugOpaquePixels(rep))"
    }

    private static func debugOpaquePixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.5 {
                count += 1
            }
        }
        return count
    }
#endif
}

// MARK: - 垂直推子

private struct VerticalFader: NSViewRepresentable {
    @Binding var db: Double
    var onGestureBegin: (() -> Void)?

    func makeNSView(context: Context) -> VerticalFaderNSView {
        let v = VerticalFaderNSView()
        v.onDrag = { self.db = $0 }
        v.onGestureBegin = onGestureBegin
        return v
    }

    func updateNSView(_ v: VerticalFaderNSView, context: Context) {
        v.db = db
        v.onDrag = { self.db = $0 }
        v.onGestureBegin = onGestureBegin
        v.needsDisplay = true
    }
}

/// 全局推子那套样式竖过来：槽在中间，帽子和滚花照旧，量程与刻度共用 GainFaderScale。
class VerticalFaderNSView: NSView {
    var db: Double = 0 { didSet { needsDisplay = true } }
    var onDrag: ((Double) -> Void)?
    var onGestureBegin: (() -> Void)?
    private var dragging = false

    /// groove 的一笔账，推子和刻度共用：上下各让出帽高的一半（18 / 2 = 9），帽子推到
    /// 两端也不会画出视图外；槽宽 2 pt（从 4 pt 降到 2 pt）。
    static func grooveRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.midX - 1, y: bounds.minY + 9, width: 2,
               height: max(0, bounds.height - 18))
    }

    private var groove: NSRect { Self.grooveRect(in: bounds) }

    override func draw(_ r: NSRect) {
        let track = groove
        NSColor.barFaderGroove.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

        let y = track.minY + GainFaderScale.position(for: db) * track.height
        NSColor.barFaderFill.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width,
                                         height: max(0, y - track.minY)), xRadius: 1, yRadius: 1).fill()

        // 帽子：走带测试台那支推子转 90° —— 横 13 × 竖 18，滚花两条横线照旧留出 8 pt 边距。
        let hw: CGFloat = 13, hh: CGFloat = 18
        let handle = NSRect(x: bounds.midX - hw / 2, y: y - hh / 2, width: hw, height: hh)
        NSColor.barFaderHandle.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2.5, yRadius: 2.5).fill()
        NSColor.barFaderKnurl.setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for offset in [handle.midY - 2, handle.midY + 2] {
            lines.move(to: NSPoint(x: handle.minX + 4, y: offset))
            lines.line(to: NSPoint(x: handle.maxX - 4, y: offset))
        }
        lines.stroke()
    }

    override func mouseDown(with e: NSEvent) {
        onGestureBegin?()
        if e.modifierFlags.contains(.option) { onDrag?(0); return }   // ⌥ 点按回 ±00.00
        dragging = true
        update(e)
    }

    override func mouseDragged(with e: NSEvent) { if dragging { update(e) } }
    override func mouseUp(with e: NSEvent) { dragging = false }

    override func scrollWheel(with e: NSEvent) {
        // ⌃ + 滚轮微调，和 pre-gain 那套手势一致；没按 ⌃ 就原样放行给窗口。
        guard e.modifierFlags.contains(.control) else { return }
        onGestureBegin?()
        // 触控板那一路竖向跟着反一次：两指往上 = 增益加。
        let step = PointerInput.up(e) > 0 ? 0.5 : -0.5
        onDrag?(max(GainFaderScale.minDB, min(GainFaderScale.maxDB, db + step)))
    }

    private func update(_ e: NSEvent) {
        let loc = convert(e.locationInWindow, from: nil)
        let track = groove
        guard track.height > 0 else { return }
        onDrag?(GainFaderScale.db(for: (loc.y - track.minY) / track.height))
    }
}

/// 推子上方的数值：黑底（pre-gain 同款），精度 0.1，双击可输入。
private struct FaderValueReadout: View {
    @Binding var db: Double
    var onBeforeCommit: (() -> Void)?

    @State private var editing = false
    @State private var text = ""

    private var display: String {
        if db <= GainFaderScale.minDB + 0.5 { return "-∞" }
        if abs(db) < 0.05 { return "±0.0" }
        return String(format: "%+.1f", db)
    }

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 16)
                    .background(Color(white: 0.25))
                    .cornerRadius(2)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
            } else {
                Text(display)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(width: 44, height: 16)
                    .background(Color.black)          //
                    .cornerRadius(2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        text = String(format: "%.1f", db)
                        editing = true
                    }
            }
        }
        .help("双击输入数值 · ⌃+滚轮微调")
    }

    private func commit() {
        onBeforeCommit?()
        editing = false
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
        db = max(Double(AudioEngine.laneFaderMinDB), min(Double(AudioEngine.laneFaderMaxDB), value))
    }
}

// MARK: - pre-gain 读数（黑底、拖动、⌃ 滚轮、⌥ 复位、双击输入）

struct PreGainReadout: NSViewRepresentable {
    @Binding var db: Double
    var onGestureBegin: (() -> Void)?

    func makeNSView(context: Context) -> PreGainNSView {
        let v = PreGainNSView()
        v.onSet = { self.db = $0 }
        v.onGestureBegin = onGestureBegin
        return v
    }

    func updateNSView(_ v: PreGainNSView, context: Context) {
        v.db = db
        v.onSet = { self.db = $0 }
        v.onGestureBegin = onGestureBegin
        v.needsDisplay = true
    }
}

class PreGainNSView: NSView {
    var db: Double = -6 { didSet { needsDisplay = true } }
    var onSet: ((Double) -> Void)?
    var onGestureBegin: (() -> Void)?
    private var dragging = false
    private var lastClick = Date.distantPast

    /// 规格：pre-gain 显示 00.0，一位小数，十位那个补出来的 0 画成黑色（看不见）。
    /// 宽度是连小数点一起算的 —— 「%04.2f」配两位小数根本不会补前导 0，
    /// 于是 0.00 那一位个位就被当成十位涂掉了，屏幕上只剩「.00」。
    private var text: String {
        let shown = (abs(db) * 10).rounded() / 10
        return (db < 0 && shown > 0 ? "-" : "+") + String(format: "%04.1f", shown)
    }

    override func draw(_ r: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ]
        let s = NSMutableAttributedString(string: text, attributes: attrs)
        s.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: s.length))
        // 涂黑的只可能是第 1 位（十位）；个位就算也是 0 照样得看得见。
        if text.hasPrefix("+0") || text.hasPrefix("-0") {
            s.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 1, length: 1))
        }
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.maxX - size.width - 3, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.option) {
            onGestureBegin?()
            onSet?(Double(AudioEngine.preGainDefaultDB))    // ⌥ 点按回 −6
            return
        }
        if e.clickCount >= 2 { editByTyping(); return }
        if Date().timeIntervalSince(lastClick) < 0.3 { editByTyping(); return }
        lastClick = Date()
        onGestureBegin?()
        dragging = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard dragging else { return }
        // 向上拖是加大。设备增量向下为正（和 locationInWindow.y 相反），所以要取负。
        let delta = -Double(e.deltaY) * 0.25
        onSet?(clamp(db + delta))
    }

    override func mouseUp(with e: NSEvent) { dragging = false }

    override func scrollWheel(with e: NSEvent) {
        // ⌃ + 滚轮微调，和 pre-gain 在走带栏上的那套手势一致。
        guard e.modifierFlags.contains(.control) else { return }
        onGestureBegin?()
        // 触控板那一路竖向跟着反一次：两指往上 = 增益加。
        let step = PointerInput.up(e) > 0 ? 0.5 : -0.5
        onSet?(clamp(db + step))
    }

    private func clamp(_ v: Double) -> Double {
        max(Double(AudioEngine.preGainMinDB), min(0, v))
    }

    private func editByTyping() {
        let field = NSTextField(frame: bounds.insetBy(dx: 2, dy: 1))
        field.stringValue = String(format: "%.1f", db)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .white
        field.backgroundColor = NSColor(white: 0.25, alpha: 1)
        field.isBezeled = false
        field.drawsBackground = true
        field.target = self
        field.action = #selector(committed(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc private func committed(_ sender: NSTextField) {
        sender.superview?.subviews.removeAll { $0 === sender }
        if let v = Double(sender.stringValue.replacingOccurrences(of: ",", with: ".")) {
            onGestureBegin?()
            onSet?(clamp(v))
        }
        needsDisplay = true
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        subviews.forEach { if let f = $0 as? NSTextField, f.window == nil { f.removeFromSuperview() } }
    }
}

// MARK: - 声像滑条（Cubase 那种细长 I 型把手）

struct PanSlider: NSViewRepresentable {
    @Binding var value: Double
    var onGestureBegin: (() -> Void)?

    func makeNSView(context: Context) -> PanSliderNSView {
        let v = PanSliderNSView()
        v.onDrag = { self.value = $0 }
        v.onGestureBegin = onGestureBegin
        return v
    }

    func updateNSView(_ v: PanSliderNSView, context: Context) {
        v.value = value
        v.onDrag = { self.value = $0 }
        v.onGestureBegin = onGestureBegin
        v.needsDisplay = true
    }
}

class PanSliderNSView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onDrag: ((Double) -> Void)?
    var onGestureBegin: (() -> Void)?
    private var dragging = false

    private var track: NSRect { bounds.insetBy(dx: 4, dy: bounds.height / 2 - 2) }

    /// 把手的中心位置 ↔ 格数（−64 … +63）。
    private func position(for pan: Double) -> CGFloat {
        let x = CGFloat(AudioEngine.panPosition(Int(pan.rounded())))
        return track.midX + x * track.width / 2
    }

    override func draw(_ r: NSRect) {
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let x = position(for: value)
        NSColor.abMixBlue.setFill()
        let from = min(x, track.midX), to = max(x, track.midX)
        NSBezierPath(rect: NSRect(x: from, y: track.midY - 1.5,
                                  width: to - from, height: 3)).fill()
        // 中间那一格：不偏的时候也要看得见。
        NSColor(white: 0.6, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: track.midX - 0.5, y: track.minY - 2, width: 1,
                                  height: track.height + 4)).fill()
        // 把手：mixlab 那根细竖条（5 × 16，圆角 1），上下两道 flange 不要了
        // （只改这一处）。
        NSColor(white: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 2.5, y: bounds.midY - 8, width: 5,
                                         height: 16), xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with e: NSEvent) {
        onGestureBegin?()
        if e.modifierFlags.contains(.option) { onDrag?(0); return }   // ⌥ 点按回中置
        dragging = true
        update(e)
    }

    override func mouseDragged(with e: NSEvent) { if dragging { update(e) } }
    override func mouseUp(with e: NSEvent) { dragging = false }

    private func update(_ e: NSEvent) {
        let loc = convert(e.locationInWindow, from: nil)
        let t = track
        guard t.width > 0 else { return }
        let x = max(-1, min(1, 2 * (loc.x - t.midX) / t.width))
        // −1 … +1 再拆回格数：负半边 64 格，正半边 63 格，和 AudioEngine 的换算一致。
        let pan = x < 0 ? x * 64 : x * 63
        onDrag?(pan.rounded())
    }
}
