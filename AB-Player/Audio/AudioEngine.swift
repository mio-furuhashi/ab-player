import AVFoundation
import os

class AudioEngine {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    /// Monitoring gain for the transport fader. `outputVolume` tops out at 1.0,
    /// so the boost side uses the EQ unit's globalGain (-96…+24 dB) instead; its
    /// single band is bypassed to keep the signal uncoloured.
    private let gainUnit = AudioEngine.makeTrimUnit()

    /// 全局推子的提升端。mixer 的 outputVolume 封顶 1.0，所以 +dB 那半边
    /// 由一个只动 globalGain 的 EQ 单元负责，它的唯一一条带旁通掉以保持信号原样。
    static func makeTrimUnit() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands.first?.bypass = true
        return eq
    }

    private var nativeA: AVAudioPCMBuffer?
    private var nativeB: AVAudioPCMBuffer?
    private var bufferA: AVAudioPCMBuffer?
    private var bufferB: AVAudioPCMBuffer?
    private var connectionFormat: AVAudioFormat?

    private var setupDone = false

    // MARK: - Per-side state

    private struct SideState {
        var playing = false
        /// 轨内时间（刻度上的位置），不是文件里的位置：下面两格都按这个口径记。
        var position: TimeInterval = 0
        var wallStart: TimeInterval = 0
        var posAtStart: TimeInterval = 0
        /// 排期时垫在音频前面的那段空白（秒）。正偏移从头起播时不为零：那时样本时钟
        /// 还没开始走，`sampleTime` 是负的，加上这一格才回到轨内时间。
        var scheduledDelay: TimeInterval = 0
    }

    private var stateA = SideState()
    private var stateB = SideState()

    /// 这一轨正在重新指派、新文件还没装上（值是排队中的装载趟数）。
    /// 挂着的还是上一份缓冲，所以这段时间的播放指令一律忽略：一放就是旧文件。
    /// 记数不记真假 —— 连着指派两份时，前一份的收尾不能把后一份的闸门提前打开。
    private var pendingLoads: [TrackSide: Int] = [:]

    /// 闸门按住那一轨期间收到的播放指令（值是收到那一刻的轨内位置）。
    /// 不能丢：重新指派一支 4K 视频要一秒上下，那一下空格按下去没声音也没画面，用户读到的
    /// 就是「这一轨卡死了」（实测：指派后立刻按空格，A 重新起步、B 停在 0 不动）。
    /// 闸门一开就补放 —— 补的是新文件，不是旧缓冲，所以不违那一条。
    /// 存位置不存 nil：字典的值一可选，`dict[side] = nil` 就成了「删键」，把要记的那条抹掉。
    private var deferredPlay: [TrackSide: TimeInterval] = [:]

    // MARK: - 时间偏移（time trim）

    /// 每一轨在刻度上的错位，秒。参数式：一个样本都不搬，只改排期的起点和轨内时间
    /// 的换算 —— 正数在头部空出 offset（音频排在将来起步），负数从文件里
    /// |offset| 秒处起播、尾巴跟着缩短。只有监听和显示看得见它：渲染导出、标记、
    /// 区间、章节仍旧按文件时间走。
    var trimA: TimeInterval = 0 { didSet { retrim(.a) } }
    var trimB: TimeInterval = 0 { didSet { retrim(.b) } }

    var activeTrack: TrackSide = .a
    var durationA: TimeInterval = 0
    var durationB: TimeInterval = 0

    var volumeA: Float = 1.0 { didSet { applyLaneVolume(.a) } }
    var volumeB: Float = 0.0 { didSet { applyLaneVolume(.b) } }
    var outputGainDB: Float = 0.0 {
        didSet {
            // Before setup() the AU isn't in the graph yet and its parameters
            // aren't live; setup() applies the current value itself.
            if setupDone { gainUnit.globalGain = max(-96, min(24, outputGainDB)) }
        }
    }

    // MARK: - 编辑模式：第二套拓扑

    /// 1.x 的链路一个字没改：非编辑模式下图里仍然是 player → mixer → EQ → 输出，
    /// 所以无缝切轨和它的输出电平和过去逐样本一致。进编辑模式时只把两条腿改接成
    /// player → pre-gain → 插件链 → 轨道音量 → mixer，退出时改回去。节点实例一旦
    /// attach 就常驻到进程结束（裁定：只切换接管，不销毁），插件参数因此
    /// 在两套拓扑之间来回切也不丢。
    private(set) var editMode = false
    private var editNodesAttached = false
    private let preGainA = AVAudioMixerNode()
    private let preGainB = AVAudioMixerNode()
    private let laneVolumeA = AVAudioMixerNode()
    private let laneVolumeB = AVAudioMixerNode()

    /// 链首 trim。上限 0 dB：它的职责只是把默认过热的监听电平拉回来，
    /// 提升交给插件和全局增益，不在这个位置做。
    static let preGainMinDB: Float = -60
    static let preGainDefaultDB: Float = -6
    var preGainDBA: Float = preGainDefaultDB { didSet { applyPreGains() } }
    var preGainDBB: Float = preGainDefaultDB { didSet { applyPreGains() } }

    /// 声道推子：量程与全局推子一致（−∞ … +12 dB，−96 当 −∞ 用），区别在于它在链路
    /// 里，所以会被渲染进导出；全局那根只管监听。
    /// 载体是混音器而不是 EQ：实测 outputVolume 就是精确的 dB 换算（−6/−20/+6 三档各差
    /// 0.01 dB），而 EQ 串进声道要多带一层系数与延迟，验收「编辑路由 = 1.x 路由」就难做了。
    static let laneFaderMinDB: Float = -96
    static let laneFaderMaxDB: Float = 12
    var laneFaderDBA: Float = 0 { didSet { applyLaneFaders() } }
    var laneFaderDBB: Float = 0 { didSet { applyLaneFaders() } }
    private let faderA = AVAudioMixerNode()
    private let faderB = AVAudioMixerNode()

    /// 声像的载体是 panNode 这一级混音器：实测它能把信号带到输出（硬左 = 远侧 −inf）。
    /// 中置是 0 dB，所以默认状态与 1.x 拓扑逐帧一致。本机法则是近侧 0 dB、远侧接近线性
    /// （半偏 ≈ −6 dB，推到边 = −inf），不是等功率；界面不做二次衰减，表读的就是它给的。
    private let panNodeA = AVAudioMixerNode()
    private let panNodeB = AVAudioMixerNode()
    private struct LaneDsp {
        /// 抽头交来的 5 ms 子窗峰值，按时间顺序排着等界面取。旧做法是把一整包压成
        /// 一个数：一包 4410 帧 = 100 ms，表也就 10 Hz 能换新值，那正是「仍略慢」的来处。
        var windows: [(left: Float, right: Float)] = []
        /// 子窗有多长（秒）。界面按流逝时间去取窗，所以这个数要一起交出去。
        var windowSeconds: Double = AudioEngine.meterWindowSeconds
        /// 队列封顶，超了丢最老的；丢了多少记着，只给诊断看。
        var dropped: Int = 0
        /// 上一包没凑满一个子窗的那点零头：已有几帧、这几帧里采到的峰值。零头要攒到下一包
        /// 一起报，不能单独算一整窗 —— 一包 4410 帧按 220 一刀切是 20.045 个窗，从前余下那
        /// 10 帧被当成一整窗交出去，抽头就每秒多报约 10 个窗，而表是按流逝时间去取的，
        /// 每秒只能取走 200.45 个。队列于是每秒净涨 10 个，约 40 秒顶到封顶 400 个，
        /// 电平表就比音频整整慢 2 秒（实测见 AB_METERLAG_CHECK：交 210.0 窗/s、取 200.0 窗/s）。
        var carryFrames: Int = 0
        var carryLeft: Float = 0
        var carryRight: Float = 0
        #if DEBUG
        /// 排障账目，只进锁、不进发布二进制：一共交过几个窗、多少帧、最后一包多大、
        /// 包的格式自称多少 Hz，以及首末包的墙钟。用来判积压是「抽头比界面快」
        /// 还是「界面没在取」—— 声明速率 × 墙钟一对就知道真实每秒帧数。
        var produced: Int = 0
        var totalFrames: Int = 0
        var lastPacketFrames: Int = 0
        var lastPacketRate: Double = 0
        var firstPacketUptime: TimeInterval = 0
        var lastPacketUptime: TimeInterval = 0
        #endif
    }
    private let laneA = OSAllocatedUnfairLock(initialState: LaneDsp())
    private let laneB = OSAllocatedUnfairLock(initialState: LaneDsp())
    private var laneTapsInstalled = false

    /// 一个子窗多长：44.1 kHz 是 220 帧。
    static let meterWindowSeconds = 0.005
    /// 一次最多攒多少子窗。表按时间去取，实测正常只有 27 个在手（0.13 秒，一个多包的量），
    /// 这里给到 0.3 秒，够把主线程被波形重画压住的那一下抖动吃掉。
    /// 从前这里给的是 2 秒，结果攒着的旧账会被当成现值画出去：混音器关着的时候抽头照样交付
    /// （`MixerMeters` 已经 stop，没人取），重开面板就先把两秒前的电平再演一遍。表要的从来
    /// 是「现在多响」，攒过头的那些丢掉就是了。
    static let laneWindowCap = 60

    /// 一段样本里的峰值绝对值。抽头跑在渲染线程上，所以这两个帮手都不碰 self，只吃参数
    /// （写成抽头里的嵌套函数会摊上 @Sendable 的一堆告警）。
    private static func channelPeak(_ channel: UnsafeBufferPointer<Float>,
                                    _ from: Int, _ to: Int) -> Float {
        var v: Float = 0
        for i in from..<to {
            let a = abs(channel[i])
            if a > v { v = a }
        }
        return v
    }

    /// 一个子窗的左右峰值。单声道时右轨读同一个值，和旧写法一样。
    private static func laneWindowPeaks(_ left: UnsafeBufferPointer<Float>,
                                         _ right: UnsafeBufferPointer<Float>?,
                                         _ from: Int, _ to: Int) -> (left: Float, right: Float) {
        let l = channelPeak(left, from, to)
        guard let right else { return (l, l) }
        return (l, channelPeak(right, from, to))
    }

    /// −64 … +63，与 Logic 同格；0 是中置。
    static let panMin = -64
    static let panMax = 63
    var panA = 0
    var panB = 0

    /// 格数换算成 −1 … +1：−64 与 +63 都正好推到一边。
    static func panPosition(_ pan: Int) -> Float {
        let v = Float(max(panMin, min(panMax, pan)))
        return v < 0 ? v / 64 : v / 63
    }

    func setPan(_ side: TrackSide, to value: Int) {
        let v = max(Self.panMin, min(Self.panMax, value))
        let x = Self.panPosition(v)
        if side == .a { panA = v; panNodeA.pan = x } else { panB = v; panNodeB.pan = x }
    }

    /// 界面按时间取窗：这一拍该取几个就给几个（不够就给全部），抽头已在声像之后，
    /// 所以这里不再乘一遍衰减；电平表的保持与回落是界面算的，这里只负责不漏峰。
    /// `taken == 0` 只说明抽头还没交付下一批，**不等于静音**：实测本机一包 4410 帧
    /// （抽头自称 44100 Hz，所以是 100 ms；装 512 也一样，AVAudioEngine 忽略 bufferSize 这个提示），
    /// 空手那一拍留着上一读数才对，否则就是旧版每包塌一次的闪烁。
    func drainLaneWindows(_ side: TrackSide, count: Int)
        -> (windows: [(left: Float, right: Float)], windowSeconds: Double, taken: Int) {
        let lock = side == .a ? laneA : laneB
        return lock.withLock {
            let n = min(count, $0.windows.count)
            guard n > 0 else { return ([], $0.windowSeconds, 0) }
            let taken = Array($0.windows[0..<n])
            $0.windows.removeFirst(n)
            return (taken, $0.windowSeconds, n)
        }
    }

    /// 把攒下的子窗全取走、压成一个峰值对：给只问「这一段有没有声、多响」的探针用。
    /// 电平表走 `drainLaneWindows`，两边同时在问会互相抢数据。
    func drainLanePeak(_ side: TrackSide) -> (left: Float, right: Float, fresh: Bool) {
        let drained = drainLaneWindows(side, count: .max)
        var peakL: Float = 0, peakR: Float = 0
        for window in drained.windows {
            if window.left > peakL { peakL = window.left }
            if window.right > peakR { peakR = window.right }
        }
        return (peakL, peakR, drained.taken > 0)
    }

    // MARK: - 插件槽

    /// 一个槽里装着的插件。unit 一旦实例化就跟着槽走，卸掉才放手；
    /// 在链路里的节点只 attach 不销毁（H 裁定），所以 reroute 只做接与拔。
    struct LoadedPlugin {
        let plugin: AUPlugin
        let unit: AVAudioUnitEffect
        var bypass = false
    }

    static let slotCount = 6
    private static let emptySlots: [LoadedPlugin?] = Array(repeating: nil, count: slotCount)

    private var plugins: [TrackSide: [LoadedPlugin?]] = [.a: AudioEngine.emptySlots,
                                                          .b: AudioEngine.emptySlots]
    private var laneBypass: [TrackSide: Bool] = [.a: false, .b: false]

    /// 正在等 AU 实例化的格号。装载在途时这一格既没有 unit，也不该被画成空槽。
    private var loadingSlots: [TrackSide: Set<Int>] = [.a: [], .b: []]

    /// 每一格自己的版本号。实例化是异步的，中间这一格可能已经被卸掉、被撤销换过
    /// 或者被 [A→B] 盖掉；回来的 unit 只在版本号没变时才算数，不然直接放手不要。
    /// 编号按格走，所以卸掉别的格不会打断这一格的装载。
    private var slotTokens: [TrackSide: [Int]] = [.a: Array(repeating: 0, count: slotCount),
                                                   .b: Array(repeating: 0, count: slotCount)]

    /// attach 过的所有 unit，包括已经卸掉的那些。节点不销毁，所以卸掉的那一级在
    /// 重接线时也必须被拔干净 —— 它可能还连着下游，漏了就会有两个头喂同一个推子。
    private var attachedUnits: [AVAudioUnitEffect] = []

    func slots(_ side: TrackSide) -> [LoadedPlugin?] { plugins[side] ?? Self.emptySlots }
    func isLaneBypassed(_ side: TrackSide) -> Bool { laneBypass[side] ?? false }

    /// 通道条要画的样子：身份、bypass、有没有在装。引擎是这三样的唯一存放处。
    func slotStates(_ side: TrackSide) -> [SlotState] {
        let busy = loadingSlots[side] ?? []
        return slots(side).enumerated().map { (i, slot) in
            guard let slot else { return SlotState(loading: busy.contains(i)) }
            return SlotState(plugin: slot.plugin, bypass: slot.bypass)
        }
    }

    /// 快照用的形状：六格的身份、bypass 和 AU 自己的状态，不带 unit。
    /// state 是 fullState 的二进制 plist —— 撤销、重做、[A→B] 都靠它把参数带走。
    func slotSnapshots(_ side: TrackSide) -> [SlotSnapshot?] {
        slots(side).map { slot in
            guard let slot else { return nil }
            return SlotSnapshot(plugin: slot.plugin, bypass: slot.bypass,
                                state: Self.state(of: slot.unit))
        }
    }

    // MARK: AU 状态与参数

    /// 把 AU 自己的状态（参数为主）压成一段二进制 plist。实测 Apple AUDelay 183 B。
    static func state(of unit: AVAudioUnitEffect) -> Data? {
        guard let full = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: full, format: .binary, options: 0)
    }

    /// 灌回去。属性表里认不出的键由 AU 自己忽略；失败（版本不符、非 plist）就当没这回事，
    /// 插件至少还能以默认参数出声，不该因为状态读不动就装不上。
    static func applyState(_ data: Data?, to unit: AVAudioUnitEffect) {
        guard let data,
              let full = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return }
        unit.auAudioUnit.fullState = full
    }

    /// 这一格现在的插件单元。界面（参数面板、原生界面浮窗）拿它去问 AU 要东西，
    /// 不许自己留一份当真相 —— 真相在 plugins 里。
    func unit(_ side: TrackSide, at index: Int) -> AVAudioUnitEffect? {
        slots(side).indices.contains(index) ? slots(side)[index]?.unit : nil
    }

    /// 一格的身份，给浮窗判断「这一格还是不是我打开时那个插件」。
    func slotPlugin(_ side: TrackSide, at index: Int) -> AUPlugin? {
        slots(side).indices.contains(index) ? slots(side)[index]?.plugin : nil
    }

    /// 这一格现在通不通。浮窗头部那颗开关要显示的是引擎里的真值，不是界面自己记的副本。
    func isSlotBypassed(_ side: TrackSide, at index: Int) -> Bool {
        slots(side).indices.contains(index) ? (slots(side)[index]?.bypass ?? false) : false
    }

    /// 装载的结果。`.stale` 是「回来得太晚」：这一格在途期间已经被改过，结果不算数，
    /// 调用方既不该报错、也不该记一笔失败。
    enum SlotLoadResult {
        case loaded
        case failed(Error)
        case stale
    }

    /// 装载是异步的（AU 的实例化要在主线程之外做，某些厂商的 shell 会跑好几秒），
    /// 所以完成前槽位还是空的；completion 一定在主线程回调。
    /// state 是快照里那份 AU 状态：撤销恢复、[A→B] 会带着它来，新装则不带（用默认参数）。
    func loadPlugin(_ plugin: AUPlugin, at index: Int, for side: TrackSide,
                    state: Data? = nil,
                    completion: @escaping (SlotLoadResult) -> Void) {
        guard slots(side).indices.contains(index) else {
            DispatchQueue.main.async { completion(.failed(PluginLoadError.badSlot(index))) }
            return
        }
        bumpToken(index, for: side)
        let token = slotTokens[side]?[index] ?? 0
        loadingSlots[side, default: []].insert(index)
        #if DEBUG
        debugSlotTrace = "已发出 instantiate(\(plugin.name))"
        #endif
        // 两条装载路径（aufx 走 AVAudioUnit、aumf 走 AVAudioUnitEffect 直造）最后都从
        // 这里回话：先校 token（在途被改过就不算数），再上主线程落格。
        let deliver: (AVAudioUnit?, Error?) -> Void = { [weak self] unit, error in
            guard let self else { return }
            DispatchQueue.main.async {
                #if DEBUG
                self.debugSlotTrace += " → 已回主线程"
                #endif
                self.loadingSlots[side, default: []].remove(index)
                guard token == self.slotTokens[side]?[index] else {
                    #if DEBUG
                    self.debugSlotTrace += " → stale"
                    #endif
                    completion(.stale); return
                }
                guard let unit else {
                    #if DEBUG
                    self.debugSlotTrace += " → failed(无 unit)"
                    #endif
                    completion(.failed(error ?? PluginLoadError.unavailable(plugin.name)))
                    return
                }
                // bypass 这个开关只在 AVAudioUnitEffect 上（实测：本机 Apple AUDelay
                // 实例化回来就是 AVAudioUnitEffect），插件链里别的形状接管不了。
                guard let effect = unit as? AVAudioUnitEffect else {
                    #if DEBUG
                    self.debugSlotTrace += " → failed(非 effect)"
                    #endif
                    completion(.failed(PluginLoadError.notEffect(plugin.name)))
                    return
                }
                var list = self.slots(side)
                Self.applyState(state, to: effect)
                list[index] = LoadedPlugin(plugin: plugin, unit: effect)
                self.plugins[side] = list
                self.applyBypass(side)
                self.rebuildGraph()
                #if DEBUG
                self.debugSlotTrace += " → 落格并重建图形"
                #endif
                completion(.loaded)
            }
        }
        switch plugin.kind {
        case .effect:
            AVAudioUnit.instantiate(with: plugin.component, options: []) { unit, error in
                #if DEBUG
                self.debugSlotTrace += " → 回调(unit=\(unit == nil ? "nil" : "有"), err=\(error.map { String(describing: $0) } ?? "nil"))"
                #endif
                deliver(unit, error)
            }
        case .musicEffect:
            // 实测：aumf 交给 AVAudioUnit.instantiate 回来的是乐器形状，过不了上面那道
            // AVAudioUnitEffect 的关；换成直接拿描述子造 AVAudioUnitEffect，同一个组件
            // 就是老老实实的效果器（Pro-Q 3：1 kHz 正弦 0.5 进、0.5000 出）。
            // 造之前先问一次注册表这条还在不在——找不到时这个构造器的行为没有保证。
            // 整段放在后台队列：这一步会加载厂商代码，主线程上停过好几秒。
            DispatchQueue.global(qos: .userInitiated).async {
                var desc = plugin.component
                guard AudioComponentFindNext(nil, &desc) != nil else {
                    deliver(nil, PluginLoadError.unavailable(plugin.name)); return
                }
                #if DEBUG
                self.debugSlotTrace += " → aumf 已直造"
                #endif
                deliver(AVAudioUnitEffect(audioComponentDescription: plugin.component), nil)
            }
        }
    }

    private func bumpToken(_ index: Int, for side: TrackSide) {
        guard var list = slotTokens[side], list.indices.contains(index) else { return }
        list[index] += 1
        slotTokens[side] = list
    }

    func unloadPlugin(at index: Int, for side: TrackSide) {
        guard slots(side).indices.contains(index), slots(side)[index] != nil else { return }
        var list = slots(side)
        list[index] = nil
        plugins[side] = list
        bumpToken(index, for: side)
        loadingSlots[side, default: []].remove(index)
        rebuildGraph()
    }

    /// 拖拽调序（同一轨）：把两格的内容对调。「拖到空槽 = 移动、原格留空洞」和
    /// 「拖到已用槽 = 二者调换」于是是同一条动作，不用分岔。
    /// unit 一个都不动，只换数组的顺序（链子的先后就是数组的先后），所以没有重新实例化，
    /// 参数和浮窗背后那颗实例都还是原来的；要重来的只有接线。
    func exchangeSlots(_ a: Int, _ b: Int, for side: TrackSide) {
        var list = slots(side)
        guard list.indices.contains(a), list.indices.contains(b), a != b else { return }
        list.swapAt(a, b)
        plugins[side] = list
        rebuildGraph()
    }

    func setSlotBypass(_ index: Int, for side: TrackSide, _ on: Bool) {
        guard slots(side).indices.contains(index), var slot = slots(side)[index],
              slot.bypass != on else { return }
        slot.bypass = on
        var list = slots(side)
        list[index] = slot
        plugins[side] = list
        applyBypass(side)
    }

    /// 整轨旁通：不重接线，只把这条链上所有插件的 bypass 一起按下去。
    func setLaneBypass(_ on: Bool, for side: TrackSide) {
        guard (laneBypass[side] ?? false) != on else { return }
        laneBypass[side] = on
        applyBypass(side)
    }

    private func applyBypass(_ side: TrackSide) {
        let laneOff = laneBypass[side] ?? false
        for slot in slots(side) {
            guard let slot else { continue }
            slot.unit.bypass = laneOff || slot.bypass
        }
    }

    /// 把整条链换成快照里的样子（撤销 / 重做 / [A→B] 走这里）。
    /// 身份相同的 unit 就地留下，省掉一次重新实例化；剩下缺的按顺序排队异步补。
    /// 这一次恢复会作废这一轨上所有在途的装载，completion 在链子补齐（或断掉）后回调。
    func restoreSlots(_ snapshots: [SlotSnapshot?], laneBypass on: Bool, for side: TrackSide,
                      completion: @escaping () -> Void) {
        var reusable: [String: [AVAudioUnitEffect]] = [:]
        for case let slot? in slots(side) { reusable[slot.plugin.id, default: []].append(slot.unit) }

        var list = Self.emptySlots
        var queued: [(index: Int, plugin: AUPlugin, bypass: Bool, state: Data?)] = []
        for (i, snap) in snapshots.enumerated() where i < list.count {
            guard let snap, let plugin = snap.plugin else { continue }
            // 同一个 id 在这一轨可能占着两格（⌥ 复制拖得出来），一格要一份自己的 unit：
            // 按 id 查会让两格接上同一个节点，reroute 时一个输出喂两个下游。
            if let unit = reusable[plugin.id]?.first {
                reusable[plugin.id]?.removeFirst()
                // 就地留下的 unit 也要按快照回灌：用户在撤销前把旋钮拧走了，
                // 恢复的语义是「回到那一刻的参数」，不是「保留现在的」。
                Self.applyState(snap.state, to: unit)
                list[i] = LoadedPlugin(plugin: plugin, unit: unit, bypass: snap.bypass)
            } else {
                queued.append((i, plugin, snap.bypass, snap.state))
            }
        }
        plugins[side] = list
        laneBypass[side] = on
        // 整轨的版本号一起往前推：这一轨上还在飞的 unit 回来时已经不认账了。
        for i in list.indices { bumpToken(i, for: side) }
        let pending = Set(queued.map { $0.index })
        loadingSlots[side] = pending
        applyBypass(side)
        rebuildGraph()

        func stop(_ remaining: [Int]) {
            self.loadingSlots[side, default: []].subtract(remaining)
            completion()
        }
        func loadNext() {
            guard let item = queued.first else { completion(); return }
            queued.removeFirst()
            loadPlugin(item.plugin, at: item.index, for: side, state: item.state) { result in
                guard case .loaded = result else {
                    // 顺序装到一半断了：后面几格不再装，圈也别再转。
                    stop(queued.map { $0.index })
                    return
                }
                self.setSlotBypass(item.index, for: side, item.bypass)
                loadNext()
            }
        }
        if pending.isEmpty { completion() } else { loadNext() }
    }

    enum PluginLoadError: LocalizedError {
        case badSlot(Int)
        case unavailable(String)
        case notEffect(String)

        var errorDescription: String? {
            switch self {
            case .badSlot(let i): return "第 \(i + 1) 个槽不存在。"
            case .unavailable(let name): return "\(name) 无法实例化。"
            case .notEffect(let name): return "\(name) 不是可插入的效果器。"
            }
        }
    }

    /// 重新接线要先把 engine 停一下：跑着改连接会让下游拿到半新半旧的图。
    /// 停之前记下哪些轨在放、放到哪，接完从那儿续上，和切拓扑时同一套手法。
    private func rebuildGraph() {
        guard editMode else { return }
        let wasRunning = engine.isRunning
        let running: [TrackSide] = [.a, .b].filter { isPlaying($0) }
        let positions = Dictionary(uniqueKeysWithValues: running.map { ($0, livePosition($0)) })
        engine.stop()
        reroute()
        applyPreGains()
        applyLaneFaders()
        if running.isEmpty {
            if wasRunning { try? engine.start() }
        } else {
            for side in running { playSide(side, from: positions[side] ?? 0) }
        }
    }

    private func applyLaneFaders() {
        guard editNodesAttached else { return }
        faderA.outputVolume = Self.linear(max(Self.laneFaderMinDB, min(Self.laneFaderMaxDB, laneFaderDBA)))
        faderB.outputVolume = Self.linear(max(Self.laneFaderMinDB, min(Self.laneFaderMaxDB, laneFaderDBB)))
    }

    /// 抽头装在 laneVolume 的**输入**总线上，也就是链尾 fader 的输出（链序：pre-gain →
    /// 声像 → 插件 → 推子，四样都在抽头上游）；而 A/B 选择器（laneVolume 自己的 outputVolume）
    /// 还在下游，所以没在放的那一轨照样有读数。实测（48k 源、44.1k 设备）：
    /// 装在这一节的抽头跟着声像走（硬左 = −inf、半偏 ≈ −6 dB），而声像本身照常作用到
    /// 最终输出 —— 抽头不改样本。还有一层好处：这里是重采样之前的原始域，量出来的峰值
    /// 就是文件里的峰值；最终输出那一级因为 48k→44.1k 的过冲会高出约 1 dB。
    private func installLaneTaps() {
        guard !laneTapsInstalled else { return }
        for (node, lock) in [(laneVolumeA, laneA), (laneVolumeB, laneB)] {
            node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
                guard let data = buf.floatChannelData else { return }
                let frames = Int(buf.frameLength)
                guard frames > 0 else { return }
                let rate = buf.format.sampleRate
                // 5 ms 一刀切：抽头自称 44100 Hz（AB_METERLAG_CHECK 实测），一窗就是 220 帧，
                // 一包 4410 帧正好 20.045 个窗 —— 多出那 10 帧攒着并进下一包，别当一整窗报。
                // 整包压成一个数时表最快也只能 10 Hz 换值，这就是「略慢」的那一段。
                let size = max(1, Int(AudioEngine.meterWindowSeconds * rate))
                let l = UnsafeBufferPointer(start: data[0], count: frames)
                let r: UnsafeBufferPointer<Float>? = buf.format.channelCount > 1
                    ? UnsafeBufferPointer(start: data[1], count: frames) : nil
                let seconds = Double(size) / rate
                lock.withLock { dsp in
                    dsp.windowSeconds = seconds
                    var appended: [(left: Float, right: Float)] = []
                    appended.reserveCapacity(frames / size + 1)
                    var start = 0
                    // 先接着上一包的零头凑满一窗，凑不满就继续攒着等下包 —— 一窗只有 5 ms，
                    // 一包有 100 ms，真出现「一整包还不够补一窗」也只是这一拍不交新窗。
                    if dsp.carryFrames > 0 {
                        let take = min(size - dsp.carryFrames, frames)
                        let w = AudioEngine.laneWindowPeaks(l, r, 0, take)
                        dsp.carryLeft = max(dsp.carryLeft, w.left)
                        dsp.carryRight = max(dsp.carryRight, w.right)
                        dsp.carryFrames += take
                        start = take
                        if dsp.carryFrames == size {
                            appended.append((dsp.carryLeft, dsp.carryRight))
                            dsp.carryFrames = 0
                            dsp.carryLeft = 0
                            dsp.carryRight = 0
                        }
                    }
                    while start + size <= frames {
                        appended.append(AudioEngine.laneWindowPeaks(l, r, start, start + size))
                        start += size
                    }
                    if start < frames {
                        let w = AudioEngine.laneWindowPeaks(l, r, start, frames)
                        dsp.carryLeft = w.left
                        dsp.carryRight = w.right
                        dsp.carryFrames = frames - start
                    }
                    dsp.windows.append(contentsOf: appended)
                    let overflow = dsp.windows.count - AudioEngine.laneWindowCap
                    if overflow > 0 {
                        dsp.windows.removeFirst(overflow)
                        dsp.dropped += overflow
                    }
                    #if DEBUG
                    let uptime = ProcessInfo.processInfo.systemUptime
                    dsp.produced += appended.count
                    dsp.totalFrames += frames
                    dsp.lastPacketFrames = frames
                    dsp.lastPacketRate = rate
                    if dsp.firstPacketUptime == 0 { dsp.firstPacketUptime = uptime }
                    dsp.lastPacketUptime = uptime
                    #endif
                }
            }
        }
        laneTapsInstalled = true
    }

    /// Fires when one side reaches its end naturally
    var onSideEnd: ((TrackSide) -> Void)?

    var isPlaying: Bool { stateA.playing || stateB.playing }
    var currentPosition: TimeInterval { position(of: activeTrack) }

    func isPlaying(_ side: TrackSide) -> Bool {
        side == .a ? stateA.playing : stateB.playing
    }

    /// 界面那一头在指派文件的那一拍调用：先占住闸门，解码回话再放开。
    /// 这里不记「装完接着放」——换曲那一拍就是把这一轨停住，要不要接着放得由使用者
    /// 自己那一下播放（或走带键）来记，走 `deferredPlay` 那一条正路。
    func beginLoad(_ side: TrackSide) {
        pendingLoads[side, default: 0] += 1
        deferredPlay.removeValue(forKey: side)
    }
    func endLoad(_ side: TrackSide) {
        pendingLoads[side] = max(0, (pendingLoads[side] ?? 0) - 1)
        guard !isLoading(side), deferredPlay.removeValue(forKey: side) != nil else { return }
        // 位置认这一轨账上**此刻**的那个数，不认按下那一笔时存下的旧数：装载期间很可能
        // 已经把播放头拖走了（`seekSide` 停着走的是改 `state.position` 那一条），存旧数
        // 等于把那一拖吃掉 —— 闸门一开又跳回 0。
        playSide(side)
    }
    func isLoading(_ side: TrackSide) -> Bool { (pendingLoads[side] ?? 0) > 0 }

    #if DEBUG
    /// 最近 40 笔被按回去的起播（满 40 从头截，够探针回溯几轮）。
    private var playSideRejects: [String] = []
    /// 探针要的那一句：闸门按住期间收到的起播，账上欠着没有。
    func hasDeferredPlay(_ side: TrackSide) -> Bool { deferredPlay.keys.contains(side) }
    /// 闸门上此刻记着几笔（不是「开/关」）。换一次曲该是 1、装完回 0；
    /// 长期停在 1 以上就是这一轨的播放指令再也发不出去的那一种。
    func loadGateForCheck(_ side: TrackSide) -> Int { pendingLoads[side] ?? 0 }
    /// `AVAudioEngine` 自己跑没跑 —— 播放旗标是真的、样本一个不出来的那一种要看这一格。
    var engineRunningForCheck: Bool { engine.isRunning }
    /// 缓冲那一格：`playSide` 的第一条 guard 是「没缓冲就一声不吭地回去」，界面上一个字
    /// 都不会报。「重载几次就全播不了」如果走的是这条路，账上只能靠这一格看出来。
    func bufferForCheck(_ side: TrackSide) -> String {
        guard let buf = buffer(for: side) else { return "无" }
        return "\(buf.frameLength)帧/\(Int(buf.format.sampleRate / 1000))k"
    }
    /// 起播指令被哪一条 guard 按回去的（`playSide` 里那两条都是静默的）。
    var playSideRejectsForCheck: [String] { playSideRejects }
    func clearPlaySideRejects() { playSideRejects = [] }
    func nativeForCheck(_ side: TrackSide) -> String {
        ((side == .a ? nativeA : nativeB)?.frameLength).map(String.init) ?? "无"
    }
    private func rsReject(_ line: String) {
        playSideRejects.append(line)
        if playSideRejects.count > 40 { playSideRejects.removeFirst(playSideRejects.count - 40) }
    }
    /// A/B 选轨那一格此刻落在谁身上、两条轨的音量各是多少。这个应用一次只让一条出声
    /// （非编辑图里就是 `playerX.volume` 那个 0/1），所以「两头都在放、一个字都听不见」
    /// 的那种死法只能从这一格看出来 —— 播放头照走、引擎照跑，只有这里是 0/0。
    var laneSelectorForCheck: String {
        "选=\(activeTrack) 音A=\(playerA.volume) 音B=\(playerB.volume) 编辑=\(editMode ? 1 : 0)"
    }
    #endif

    /// 轨内时间（刻度上的位置）：正偏移时前 `trim` 秒是空白，负偏移时开头那段被甩掉。
    func position(of side: TrackSide) -> TimeInterval {
        livePosition(side)
    }

    func trim(_ side: TrackSide) -> TimeInterval { side == .a ? trimA : trimB }

    /// 这一轨在刻度上占多长：文件时长 + 偏移。进度条和波形都按它铺。
    func laneDuration(_ side: TrackSide) -> TimeInterval {
        max(0, (side == .a ? durationA : durationB) + trim(side))
    }

    /// 轨内时间 → 文件里的位置（秒）。负的那一截落在文件前面，就是头部空白。
    func fileTime(_ lane: TimeInterval, side: TrackSide) -> TimeInterval {
        lane - trim(side)
    }

    /// 采样率：界面用它把偏移折到整帧上（样本精度那一档）。
    func sampleRate(for side: TrackSide) -> Double {
        buffer(for: side)?.format.sampleRate ?? 0
    }

    /// 偏移变了：正在放的那一轨从「轨内当前位置」重排一次，播放头不动。
    /// 停着的那一轨什么都不用做 —— 记的本来就是轨内时间，改的是换算。
    private func retrim(_ side: TrackSide) {
        guard isPlaying(side), buffer(for: side) != nil else { return }
        schedule(side: side, from: livePosition(side))
    }

    // MARK: - Load

    func loadTrackA(url: URL) throws {
        setup()
        let file = try AVAudioFile(forReading: url)
        nativeA = try readFullBuffer(from: file)
        durationA = Double(file.length) / file.processingFormat.sampleRate
        bufferA = convert(nativeA, to: connectionFormat!)
        stateA = SideState()
    }

    func loadTrackB(url: URL) throws {
        setup()
        let file = try AVAudioFile(forReading: url)
        nativeB = try readFullBuffer(from: file)
        durationB = Double(file.length) / file.processingFormat.sampleRate
        bufferB = convert(nativeB, to: connectionFormat!)
        stateB = SideState()
    }

    private func readFullBuffer(from file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let format = file.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: format,
                                    frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return buf
    }

    // MARK: - Format Conversion

    private func convert(_ src: AVAudioPCMBuffer?, to dstFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = src, src.frameLength > 0 else { return nil }
        if src.format.sampleRate == dstFormat.sampleRate,
           src.format.channelCount == dstFormat.channelCount {
            return src
        }
        guard let converter = AVAudioConverter(from: src.format, to: dstFormat) else { return nil }

        let ratio = dstFormat.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 4096
        guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else { return nil }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: dst, error: &conversionError) {
            (_, inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return src
        }
        guard status != .error, conversionError == nil else { return nil }
        return dst
    }

    // MARK: - Engine Setup

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 48000, channels: 2, interleaved: false)!

    func setup() {
        guard !setupDone else { return }
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(gainUnit)

        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let format: AVAudioFormat
        if mixerFormat.sampleRate > 0, mixerFormat.channelCount > 0,
           let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: mixerFormat.sampleRate,
                                 channels: mixerFormat.channelCount,
                                 interleaved: false) {
            format = f
        } else {
            format = targetFormat
        }
        connectionFormat = format

        engine.connect(playerA, to: engine.mainMixerNode, format: format)
        engine.connect(playerB, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: gainUnit, format: format)
        // nil on purpose: the EQ cannot resample, and pinning this leg to the
        // mixer format (44,100 here) while the device runs at 48,000 makes
        // engine.start() fail with -10868 and the app goes silent.
        engine.connect(gainUnit, to: engine.outputNode, format: nil)
        gainUnit.globalGain = outputGainDB

        applyLaneVolume(.a)
        applyLaneVolume(.b)
        setupDone = true
    }

    /// The A/B selector lives on the player in 1.x's graph and on its own node in
    /// the edit graph, so that the plugins still see signal from the silent lane's
    /// chain position-wise. Only one of the two is read at a time.
    private func applyLaneVolume(_ side: TrackSide) {
        let v = side == .a ? volumeA : volumeB
        if editMode {
            (side == .a ? laneVolumeA : laneVolumeB).outputVolume = v
        } else {
            node(for: side).volume = v
        }
    }

    private func applyPreGains() {
        guard editNodesAttached else { return }
        preGainA.outputVolume = Self.linear(preGainDBA)
        preGainB.outputVolume = Self.linear(preGainDBB)
    }

    static func linear(_ db: Float) -> Float {
        db <= -96 ? 0 : pow(10, db / 20)
    }

    /// Switch which topology owns the two lanes. Playback survives the switch:
    /// both live positions are taken before the engine stops, and the sides that
    /// were running are re-scheduled from them afterwards.
    func setEditMode(_ on: Bool) {
        guard on != editMode else { return }
        setup()

        let running: [TrackSide] = [.a, .b].filter { isPlaying($0) }
        let positions = Dictionary(uniqueKeysWithValues: running.map { ($0, livePosition($0)) })

        if on, !editNodesAttached {
            engine.attach(preGainA)
            engine.attach(preGainB)
            engine.attach(faderA)
            engine.attach(faderB)
            engine.attach(panNodeA)
            engine.attach(panNodeB)
            engine.attach(laneVolumeA)
            engine.attach(laneVolumeB)
            installLaneTaps()
            editNodesAttached = true
        }

        // Hand the selector over instead of copying it: whichever node is leaving
        // the path must not keep a 0 in it for the next time it is wired in.
        let selA = editMode ? laneVolumeA.outputVolume : playerA.volume
        let selB = editMode ? laneVolumeB.outputVolume : playerB.volume
        editMode = on
        if on {
            playerA.volume = 1
            playerB.volume = 1
            laneVolumeA.outputVolume = selA
            laneVolumeB.outputVolume = selB
        } else {
            laneVolumeA.outputVolume = 1
            laneVolumeB.outputVolume = 1
            playerA.volume = selA
            playerB.volume = selB
        }

        engine.stop()
        reroute()
        applyPreGains()
        applyLaneFaders()
        for side in running { playSide(side, from: positions[side] ?? 0) }
    }

    /// attach 只能在引擎停下来以后做，而 reroute 全都发生在停止的那一段里，所以挂载点
    /// 放在这儿：新装的插件第一次进链路时补上，之后只接不挂。
    private func attachIfNeeded(_ unit: AVAudioUnitEffect) {
        guard !attachedUnits.contains(where: { $0 === unit }) else { return }
        engine.attach(unit)
        attachedUnits.append(unit)
    }

    private func reroute() {
        guard setupDone, let format = connectionFormat else { return }
        engine.disconnectNodeInput(engine.mainMixerNode)
        if editMode {
            let lanes: [(side: TrackSide, player: AVAudioPlayerNode, pre: AVAudioMixerNode,
                         fader: AVAudioMixerNode, pan: AVAudioMixerNode, lane: AVAudioMixerNode)] = [
                (.a, playerA, preGainA, faderA, panNodeA, laneVolumeA),
                (.b, playerB, preGainB, faderB, panNodeB, laneVolumeB),
            ]
            // 槽位变过之后旧连接还挂在原处，会把这条链接出两个头，所以先全拆干净再按
            // 新顺序接。拆必须一次做完，不能混在每一轨的接线里：接完 A 再去拆 B 那一轮
            // 的插件输出，剪断的其实是 A（实测：player 于是报
            // 'player started when in a disconnected state'）。
            // 已经卸掉的插件也在这一串里：节点不销毁，它可能还连着下游。
            for unit in attachedUnits { engine.disconnectNodeOutput(unit) }
            for l in lanes {
                for node in [l.pre, l.fader, l.pan, l.lane] { engine.disconnectNodeOutput(node) }
            }
            for l in lanes {
                // 链序 pre-gain → 声像 → 插件 → 推子。声像排在插件之前，插件吃的是
                // 已经摆好位置的信号；推子照旧管整条链的输出。
                engine.connect(l.player, to: l.pre, format: format)
                engine.connect(l.pre, to: l.pan, format: format)
                var tail: AVAudioNode = l.pan
                for case let slot? in slots(l.side) {
                    attachIfNeeded(slot.unit)
                    engine.connect(tail, to: slot.unit, format: format)
                    tail = slot.unit
                }
                engine.connect(tail, to: l.fader, format: format)
                engine.connect(l.fader, to: l.lane, format: format)
                engine.connect(l.lane, to: engine.mainMixerNode, format: format)
            }
        } else {
            engine.connect(playerA, to: engine.mainMixerNode, format: format)
            engine.connect(playerB, to: engine.mainMixerNode, format: format)
        }
    }

    /// 引擎跑起来。返回「此刻它是不是真在跑」——调用方必须在拿到 true 之后才去碰节点。
    /// `AVAudioPlayerNode.play(at:)` 在引擎停着时不是失败、是直接抛 ObjC 异常
    /// （`required condition is false: _engine->IsRunning()`），Swift 拦不住，进程当场没：
    /// 重载/切参照模式那一趟实测两条 `Abort trap: 6`（hv_off1、hv_light），栈是
    /// `seekSide` → `schedule` → `play(at:)`，而 `seekSide` 那一路原本连 `ensureRunning` 都不走。
    @discardableResult
    private func ensureRunning() -> Bool {
        setup()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                #if DEBUG
                debugStartError = String(describing: error)
                #endif
            }
        }
        return engine.isRunning
    }

    // MARK: - Per-side transport

    func playSide(_ side: TrackSide, from time: TimeInterval? = nil) {
        guard buffer(for: side) != nil else {
            #if DEBUG
            rsReject("\(side)没缓冲(native=\(nativeForCheck(side)) 时长=\(String(format: "%.2f", side == .a ? durationA : durationB)))")
            #endif
            return
        }
        // 重新指派还没装完的那一轨：节点上挂的还是旧文件，这一放就把旧文件又请回来了。
        // 但不等于可以不管 —— 记下来，闸门一开补放（见 `deferredPlay`）。
        guard !isLoading(side) else {
            deferredPlay[side] = time ?? (side == .a ? stateA : stateB).position
            #if DEBUG
            rsReject("\(side)闸门按住→欠放")
            #endif
            return
        }
        deferredPlay.removeValue(forKey: side)
        // 已经在放、又没指定起点：这一笔是重复的起播，重排 = 节点 stop 再从头排一遍，
        // 听感是一记卡顿、画面是一次硬 seek。走带键现在按「两条腿都在放」判，所以这一格
        // 会在半停半放时被走到 —— 那一轨不该动，动的是刚换完曲还没起来的那一条。
        // 带起点的（ABX 追平到对面那一格）照旧重排。
        if time == nil && isPlaying(side) { return }
        // 起播指令发出去之前引擎必须真在跑，不然 `play(at:)` 抛 ObjC 异常整个进程没
        // （见 `ensureRunning`）。起不来就一声不吭地回去，播放旗标留在停 —— 界面上报的是
        // 「没放起来」，不是「在放却没声音」。
        guard ensureRunning() else {
            #if DEBUG
            rsReject("\(side)引擎起不来")
            #endif
            return
        }
        let state = side == .a ? stateA : stateB
        schedule(side: side, from: time ?? state.position)
    }

    func pauseSide(_ side: TrackSide) {
        // 停的指令压过还没放出去的那一起播（闸门按住时 `isPlaying` 是假的，早退就漏清了）。
        deferredPlay.removeValue(forKey: side)
        guard isPlaying(side) else { return }
        let pos = livePosition(side)
        node(for: side).stop()
        var state = side == .a ? stateA : stateB
        state.playing = false
        state.position = pos
        if side == .a { stateA = state } else { stateB = state }
    }

    func stopSide(_ side: TrackSide) {
        deferredPlay.removeValue(forKey: side)
        node(for: side).stop()
        if side == .a { stateA = SideState() } else { stateB = SideState() }
    }

    func seekSide(_ side: TrackSide, to time: TimeInterval) {
        let dur = laneDuration(side)
        let clamped = min(max(0, time), dur > 0 ? dur : time)
        // 在放的那一轨重排要走 `play(at:)`，引擎停着（被系统打断、设备换了、start 抛过）
        // 那一句就是整个进程没 —— 重载/切模式实测两条 `Abort trap: 6` 走的就是这条路。
        // 起不来就退回到「只记账不重排」，并把这一轨的播放旗标改回停，界面上不会假在放。
        if isPlaying(side), ensureRunning() {
            schedule(side: side, from: clamped)
        } else {
            var state = side == .a ? stateA : stateB
            state.position = clamped
            if !engine.isRunning { state.playing = false }
            if side == .a { stateA = state } else { stateB = state }
        }
    }

    /// Toggle one side independently (reference mode)
    func toggleSide(_ side: TrackSide) {
        if isPlaying(side) { pauseSide(side) } else { playSide(side) }
    }

    // MARK: - Combined transport (A/B synced comparison)

    func playAll() {
        playSide(.a)
        playSide(.b)
    }

    func pauseAll() {
        pauseSide(.a)
        pauseSide(.b)
    }

    func stopAll() {
        stopSide(.a)
        stopSide(.b)
    }

    func seekAll(to time: TimeInterval) {
        seekSide(.a, to: time)
        seekSide(.b, to: time)
    }

    func togglePlayPauseAll() {
        // 「在放」按两条腿一起算：半停半放（换曲那一拍就是这个形状）这一按是起播，
        // 不是再停一次 —— 读「或」的话新那份永远起不来。
        if stateA.playing && stateB.playing { pauseAll() } else { playAll() }
    }

    // MARK: - Scheduling internals

    private func node(for side: TrackSide) -> AVAudioPlayerNode {
        side == .a ? playerA : playerB
    }

    private func buffer(for side: TrackSide) -> AVAudioPCMBuffer? {
        side == .a ? bufferA : bufferB
    }

    /// 排一次期。`lanePos` 是轨内时间：偏移为正且还没走完头部空白时，缓冲整份排在
    /// 将来（那段时间里节点已经"在放"，样本时钟给出负的位置），一个样本都不搬；
    /// 偏移为负或已经走过空白，就从文件里那一帧起切尾巴 —— 这条路本来就是搬指针。
    private func schedule(side: TrackSide, from lanePos: TimeInterval) {
        guard let buf = buffer(for: side) else { return }
        // 这一路的终点是 `play(at:)`，引擎停着时它不是失败、是抛 ObjC 异常整个进程没，
        // 所以停着就什么都不做（起播那一路在 `playSide`/`seekSide` 已经先 `ensureRunning`，
        // 这一格是堵上 `retrim` 那一条不经过它们的入口）。
        guard engine.isRunning else { return }
        let player = node(for: side)
        player.stop()

        let futureSec: TimeInterval = 0.05
        let sr = buf.format.sampleRate
        let filePos = lanePos - trim(side)
        let blank = max(0, -filePos)
        let startFrame = AVAudioFramePosition(filePos * sr)
        let total = AVAudioFramePosition(buf.frameLength)

        let futureHost = mach_absolute_time() + secondsToHostTime(futureSec + blank)
        let startTime = AVAudioTime(hostTime: futureHost)

        if startFrame >= total {
            // At end: rewind to start
            player.scheduleBuffer(buf, at: startTime, options: [], completionHandler: nil)
            player.play(at: startTime)
            var state = SideState()
            state.playing = true
            state.posAtStart = 0
            state.wallStart = CACurrentMediaTime() + futureSec
            state.scheduledDelay = blank
            if side == .a { stateA = state } else { stateB = state }
            return
        }

        if startFrame <= 0 {
            player.scheduleBuffer(buf, at: startTime, options: [], completionHandler: nil)
        } else {
            let frames = AVAudioFrameCount(total - startFrame)
            if let slice = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: frames),
               let src = buf.floatChannelData, let dst = slice.floatChannelData {
                let offset = Int(startFrame)
                let len = Int(frames)
                for ch in 0..<Int(buf.format.channelCount) {
                    memcpy(dst[ch], src[ch] + offset, len * MemoryLayout<Float>.size)
                }
                slice.frameLength = frames
                player.scheduleBuffer(slice, at: startTime, options: [], completionHandler: nil)
            }
        }
        player.play(at: startTime)

        var state = SideState()
        state.playing = true
        state.position = lanePos
        state.posAtStart = lanePos
        state.wallStart = CACurrentMediaTime() + futureSec
        state.scheduledDelay = blank
        if side == .a { stateA = state } else { stateB = state }
    }

    // MARK: - Position reading

    /// 轨内时间。两条时钟在这点上要对齐：样本时钟（节点自己的，出声之后一律用它）
    /// 和墙钟（正偏移那段空白里用，因为那时还没有样本可数）。
    private func livePosition(_ side: TrackSide) -> TimeInterval {
        let state = side == .a ? stateA : stateB
        guard state.playing else { return state.position }
        let player = node(for: side)
        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime),
           playerTime.sampleRate > 0 {
            let played = Double(playerTime.sampleTime) / playerTime.sampleRate
            // 缓冲排在将来时 sampleTime 是负的：引擎重启之后它再也不返回有效值（实测），
            // 所以负值只在"确实垫了空白"的那次排期里才可信。
            if played >= 0 || state.scheduledDelay > 0 {
                return state.posAtStart + played + state.scheduledDelay
            }
        }
        return state.posAtStart + max(0, CACurrentMediaTime() - state.wallStart)
    }

    /// Update position for a playing side; fires onSideEnd at track end.
    func tickSide(_ side: TrackSide) {
        guard isPlaying(side) else { return }
        let pos = livePosition(side)
        var state = side == .a ? stateA : stateB
        state.position = pos
        if side == .a { stateA = state } else { stateB = state }

        // 轨内刻度走完 = 文件读到尽头（正偏移多走一段空白，负偏移少走一段开头）。
        let dur = laneDuration(side)
        if dur > 0 && pos >= dur {
            node(for: side).stop()
            var stopped = SideState()
            stopped.position = 0
            if side == .a { stateA = stopped } else { stateB = stopped }
            onSideEnd?(side)
        }
    }

    // MARK: - Track Switching (volume only, playback untouched)

    func switchTrack() {
        setActiveTrack(activeTrack == .a ? .b : .a)
    }

    func setActiveTrack(_ side: TrackSide) {
        if side == .a && bufferA == nil { return }
        if side == .b && bufferB == nil { return }
        activeTrack = side
        switch side {
        case .a: volumeA = 1; volumeB = 0
        case .b: volumeA = 0; volumeB = 1
        }
    }

    // MARK: - Diagnostics (编译期隔离，发布二进制不含)

    #if DEBUG
    /// 双拓扑的正确性只能靠量：在输出前最后一级挂一个 tap，把渲染出来的样本整段采走。
    /// 比对不借时间戳做对齐 —— 引擎重启后 playerTime(forNodeTime:) 就再也不返回有效值了，
    /// 所以采回来的两段样本由调用方自己找整数偏移，再逐帧比。
    private var captureCh0 = [Float]()
    private var captureCh1 = [Float]()
    private var captureActive = false
    private var captureTapInstalled = false
    private var captureNextSample: AVAudioFramePosition = -1
    private var captureGaps = 0
    /// 一轮采样里 tap 被调了几次、engine.start() 有没有抛——空窗口的两种成因靠这两个数分开。
    private var captureCallbacks = 0
    var debugStartError = ""
    private let captureLock = NSLock()

    /// 排障要动插件的参数面板（验证 AU 真的在算），得拿到那一格的 unit。
    func debugSlotUnit(_ side: TrackSide, _ index: Int) -> AVAudioUnitEffect? {
        guard let list = plugins[side], list.indices.contains(index) else { return nil }
        return list[index]?.unit
    }

    /// attach 过的节点总数：卸掉的不销毁，所以这个数只增不减，用来核对有没有漏挂。
    var debugAttachedPluginCount: Int { attachedUnits.count }

    /// 抽头队列丢窗计数：界面问得太慢、窗积到封顶才会丢，正常该一直是 0。
    func debugLaneDroppedWindows(_ side: TrackSide) -> Int {
        (side == .a ? laneA : laneB).withLock { $0.dropped }
    }

    /// 队列里还积着几个窗：表按时间去取，这个数应该只在一包刚到那会儿鼓一下。
    func debugLanePendingWindows(_ side: TrackSide) -> Int {
        (side == .a ? laneA : laneB).withLock { $0.windows.count }
    }

    /// 抽头的生产侧账目（只读，不碰队列，所以不会和电平表抢数据）：
    /// `pending + dropped` 对 `produced` 能算出界面取走了几个；`totalFrames ÷ 墙钟跨度`
    /// 是抽头真实交付的每秒帧数，和 `lastPacketRate` 一比就知道子窗时长报得准不准。
    func debugLaneWindowLedger(_ side: TrackSide)
        -> (pending: Int, produced: Int, dropped: Int, windowSeconds: Double,
            totalFrames: Int, lastPacketFrames: Int, declaredRate: Double,
            spanSeconds: TimeInterval) {
        (side == .a ? laneA : laneB).withLock {
            (pending: $0.windows.count, produced: $0.produced, dropped: $0.dropped,
             windowSeconds: $0.windowSeconds, totalFrames: $0.totalFrames,
             lastPacketFrames: $0.lastPacketFrames, declaredRate: $0.lastPacketRate,
             spanSeconds: $0.lastPacketUptime - $0.firstPacketUptime)
        }
    }

    /// 装载走到哪一步就没了下文：发出请求 / 回调 / 回主线程 / 落格，四段各记一笔。
    var debugSlotTrace: String {
        get { debugSlotTraceValue }
        set { debugSlotTraceValue = newValue }
    }
    private var debugSlotTraceValue = ""

    /// 相关峰的横轴按帧算，得知道链路上的采样率。
    var debugConnectionRate: Double { connectionFormat?.sampleRate ?? 0 }

    /// 排障：声像没作用到输出时，先问清pan 值到底在不在节点上、另一条声道
    /// 有没有一起响（两条都在，单条淡出是量不出 −inf 的）。
    var debugLaneState: String {
        "编辑=\(editMode) 已装=\(editNodesAttached) "
        + "panNodeA.pan=\(panNodeA.pan) panNodeB.pan=\(panNodeB.pan) "
        + "A▶=\(isPlaying(.a)) B▶=\(isPlaying(.b)) "
        + "playerA.vol=\(playerA.volume) playerB.vol=\(playerB.volume) "
        + "laneVolA=\(laneVolumeA.outputVolume) preA=\(preGainA.outputVolume) "
        + "faderA=\(faderA.outputVolume) panA=\(panNodeA.pan) "
        + "panB=\(panNodeB.pan) laneVolB=\(laneVolumeB.outputVolume) "
        + "接格式=\(String(describing: connectionFormat))"
    }

    struct DebugCapture {
        let ch0: [Float]
        let ch1: [Float]
        let gaps: Int
        let callbacks: Int
        var frameCount: Int { ch0.count }
    }

    func debugStartCapture() {
        setup()
        captureLock.lock()
        captureCh0.removeAll()
        captureCh1.removeAll()
        captureActive = true
        captureGaps = 0
        captureNextSample = -1
        captureCallbacks = 0
        debugStartError = ""
        captureLock.unlock()
        guard !captureTapInstalled else { return }
        gainUnit.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, when in
            guard let self, let data = buf.floatChannelData else { return }
            let frames = Int(buf.frameLength)
            self.captureLock.lock()
            self.captureCallbacks += 1
            if self.captureActive {
                // Debug 构建的 CPU 余量小，渲染周期可能被跳过；一旦不连续，这一轮
                // 采样的比对就不可信，所以数着 gap，由调用方决定重采。
                if when.isSampleTimeValid {
                    if self.captureNextSample >= 0, when.sampleTime != self.captureNextSample {
                        self.captureGaps += 1
                    }
                    self.captureNextSample = when.sampleTime + AVAudioFramePosition(frames)
                } else {
                    self.captureGaps += 1
                }
                let c0 = UnsafeBufferPointer(start: data[0], count: frames)
                let c1 = buf.format.channelCount > 1
                    ? UnsafeBufferPointer(start: data[1], count: frames) : c0
                self.captureCh0.append(contentsOf: c0)
                self.captureCh1.append(contentsOf: c1)
            }
            self.captureLock.unlock()
        }
        captureTapInstalled = true
    }

    /// 直接从引擎问图形：从这一轨的通道音量节点往上游一跳一跳走回播放器，把每一跳的
    /// 节点名报出来。改的就是这一串的顺序，电平量得再多次也不如把它读出来。
    var debugLaneTrace: String {
        func name(_ n: AVAudioNode?) -> String {
            guard let n else { return "—" }
            for (node, tag) in [(playerA, "playerA"), (preGainA, "preA"), (panNodeA, "panA"),
                                (faderA, "faderA"), (laneVolumeA, "laneA"),
                                (playerB, "playerB"), (preGainB, "preB"), (panNodeB, "panB"),
                                (faderB, "faderB"), (laneVolumeB, "laneB"),
                                (engine.mainMixerNode, "mainMixer"), (gainUnit, "gain(EQ)")] {
                if n === node { return tag }
            }
            for side in [TrackSide.a, .b] {
                for slot in slots(side) {
                    if let unit = slot?.unit, unit === n { return "插件:\(unit.name)" }
                }
            }
            return "?\(type(of: n))"
        }
        var hops: [String] = []
        var cur: AVAudioNode? = laneVolumeA
        for _ in 0..<10 {
            guard let node = cur else { break }
            hops.append(name(node))
            cur = engine.inputConnectionPoint(for: node, inputBus: 0)?.node
        }
        return hops.joined(separator: " ← ")
    }

    /// 采满 `frames` 帧为止。渲染线程在别的核上跑，主线程空转等它。
    func debugWaitForCapture(frames: Int, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            captureLock.lock()
            let n = captureCh0.count
            captureLock.unlock()
            if n >= frames { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    func debugFinishCapture() -> DebugCapture {
        captureLock.lock()
        captureActive = false
        let r = DebugCapture(ch0: captureCh0, ch1: captureCh1,
                             gaps: captureGaps, callbacks: captureCallbacks)
        captureLock.unlock()
        return r
    }
    #endif

    // MARK: - Metadata

    func readMetadata(url: URL) -> (duration: TimeInterval, channels: Int, sampleRate: Double, bitrate: Int)? {
        // 时长/声道/采样率读的是「声音」：系统读不了的容器那里读不到，就用缓存里那一份
        // （转好了才有，没转就还是原文件，AVAudioFile 自己报打不开、交回 nil）。
        // 码率却始终按原文件算：那是用户要比对的那个数字，换成解出来的 wav 就等于
        // 拿 1411 kbps 冒充一支 320 kbps 的 mp3。
        guard let file = try? AVAudioFile(forReading: AudioFormatCache.audioURL(for: url)) else {
            return nil
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        let sampleRate = file.processingFormat.sampleRate

        var bitrate = 0
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        if duration > 0 {
            bitrate = Int(Double(fileSize) * 8 / duration / 1000)
        }
        return (duration, channels, sampleRate, bitrate)
    }

    func stop() {
        stopAll()
    }

    func reset() {
        stopAll()
        if engine.isRunning { engine.stop() }
    }
}

// MARK: - Mach time helper

private func secondsToHostTime(_ seconds: TimeInterval) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanos = UInt64(seconds * 1_000_000_000)
    return nanos * UInt64(info.denom) / UInt64(info.numer)
}
