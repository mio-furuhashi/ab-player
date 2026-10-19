import Foundation
import AVFoundation
import Combine
import SwiftUI

/// High-frequency playhead position lives here so only the playhead
/// subtree observes it; the full view tree does not rebuild 20x/sec.
final class PlayerClock: ObservableObject {
    @Published var posA: TimeInterval = 0
    @Published var posB: TimeInterval = 0

    func position(of side: TrackSide) -> TimeInterval {
        side == .a ? posA : posB
    }
}

class PlayerViewModel: ObservableObject {
    // MARK: - Published State

    @Published var tracks: [Track] = []
    @Published var backupTracks: [Track] = [] {
        didSet { BackupListStore.shared.save(backupTracks) }
    }
    @Published var selectedTrackIndex: Int? = nil
    @Published var mainMulti: Set<Int> = []
    @Published var backupSelectedIndex: Int? = nil
    @Published var backupMulti: Set<Int> = []
    @Published var trackA: Track? = nil
    @Published var trackB: Track? = nil
    @Published var activeTrack: TrackSide = .a
    @Published var isPlaying = false
    @Published var sidePlayingA = false
    @Published var sidePlayingB = false
    let clock = PlayerClock()
    var currentPosition: TimeInterval { clock.position(of: activeTrack) }
    @Published var compareMode: CompareMode = .versionCompare

    @Published var markers: [Marker] = []
    @Published var markersA: [Marker] = []
    @Published var markersB: [Marker] = []
    @Published var rangeA: ABRange? = nil
    @Published var rangeB: ABRange? = nil
    @Published var rangeCompareEnabled = false
    @Published var isSelectingRange = false

    @Published var waveformPeaksA: PeakData = .empty
    @Published var waveformPeaksB: PeakData = .empty
    /// Horizontal zoom factor, 1 … WaveformNSView.zoomMax.
    @Published var waveformHorizontalZoom: Float = 1.0

    @Published var chapters: [Chapter] = []
    /// 章节太多（≥50）时挂在这里，等主窗口那枚对话框点头。呈现用的是
    /// `showChapterPrompt` 那枚 Bool，两者分开是因为 SwiftUI 收对话框时会先把 Bool
    /// 写成 false：绑在一起的话「是」那颗按钮执行时载荷已经没了。
    @Published var chapterImportPrompt: ChapterImportPrompt? = nil
    @Published var showChapterPrompt = false

    // ABX
    @Published var abxIsActive = false
    @Published var abxRounds: [ABXRound] = []
    @Published var abxTotalRounds: Int = 0
    @Published var abxCurrentRoundIndex: Int = 0
    @Published var abxShowSetup = false
    @Published var abxShowConfirm = false
    @Published var abxSetupRoundText: String = "0"
    @Published var abxShowResult = false
    @Published var abxLastChoice: String? = nil

    // UI
    @Published var showInfoPanel = false
    @Published var showPlaylistSidebar = true
    @Published var showSettings = false
    @Published var showHelp = false
    @Published var timecodeEditing = false
    private var timecodeSyncBoth = false

    // MARK: - Engine

    private let engine = AudioEngine.shared
    private var displayTimer: Timer?
    private var pendingRangeStart: TimeInterval?
    @Published private(set) var loadPending = 0

    var duration: TimeInterval {
        activeTrack == .a ? engine.durationA : engine.durationB
    }

    var currentTrack: Track? {
        activeTrack == .a ? trackA : trackB
    }

    var selectedTrack: Track? {
        guard let idx = selectedTrackIndex, idx < tracks.count else { return nil }
        return tracks[idx]
    }

    // MARK: - Init

    init() {
        backupTracks = BackupListStore.shared.load()
        engine.onSideEnd = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleSideEnd()
            }
        }
        startDisplayTimer()
    }

    /// Monitoring gain for both lanes (the transport fader). Exports never see
    /// it: ffmpeg reads the source file directly. Deliberately does not call
    /// `engine.setup()` — building the graph (and touching the output device's
    /// format) at launch stalled the UI for seconds.
    func setOutputGain(_ db: Double) {
        engine.outputGainDB = Float(db)
    }

    // MARK: - 编辑模式（插件）

    /// 编辑模式只影响音频拓扑和走带栏配色，不参与撤销快照（快照里存的是用户内容，
    /// 模式是查看方式）。pre-gain 是通道条的一部分，所以它进快照。
    @Published private(set) var editMode = false
    @Published var preGainA: Double = Double(AudioEngine.preGainDefaultDB)
    @Published var preGainB: Double = Double(AudioEngine.preGainDefaultDB)
    @Published var showEditModeExitPrompt = false

    /// ⌘4：进模式直接进，退模式必须先提醒监听电平。
    /// 盲听进行中不改拓扑（菜单项和按键都汇到这儿，所以守卫写在动作里而不是 .disabled 上）。
    func toggleEditMode() {
        guard !abxIsActive else { return }
        if editMode {
            // 弹不弹由「设置 → 显示 → 退出编辑模式时弹窗提示」说了算（默认开）。
            if SettingsStore.shared.editModeExitPrompt { showEditModeExitPrompt = true }
            else { setEditMode(false) }
        } else { setEditMode(true) }
    }

    func setEditMode(_ on: Bool) {
        guard on != editMode else { return }
        showEditModeExitPrompt = false
        engine.setEditMode(on)
        editMode = on
        // 通道条的六格只在链路活着的时候有意义，进模式先把镜像对齐。
        refreshSlots()
        if !on {
            browserTarget = nil
            MixerPanelController.shared.editModeEnded()
            // 链路已经绕开插件了，浮窗上的读数会变成假的，跟着一起收。
            PluginEditorController.shared.editModeEnded()
        } else {
            // 编辑模式整个对视频无效（裁定）：链路一换，画面和声音的对应就不可信了，
            // 所以是「进模式」那一下收窗，和混音器「退模式」正好反过来。
            VideoPanelController.shared.videoInvalidated()
            if !Self.usedFirstEntryMixerOpening {
                // 会话里头一次进编辑模式就把混音器开起来：通道条、槽位、电平表都在那一扇窗里，
                // 先开着才不用人去菜单里找。一次性，之后再进出不自动开（规格裁定）。
                // 已经开着也算这一次用掉了 —— 不抢用户自己开的那扇窗。
                Self.usedFirstEntryMixerOpening = true
                if !MixerPanelController.shared.isVisible {
                    MixerPanelController.shared.open(vm: self)
                }
            }
        }
    }

    /// 「本会话有没有用掉头一次自动开混音器的那一下」。进程级：退出重开才算新的一轮。
    private static var usedFirstEntryMixerOpening = false

    /// 链首 trim，−60 … 0 dB。非编辑模式下它不在图里，所以数值只是攒着，
    /// 进模式时由 `applyPreGains()` 一次到位。
    func setPreGain(_ db: Double, for side: TrackSide) {
        let clamped = max(Double(AudioEngine.preGainMinDB), min(0, db))
        if side == .a {
            preGainA = clamped
            engine.preGainDBA = Float(clamped)
        } else {
            preGainB = clamped
            engine.preGainDBB = Float(clamped)
        }
    }

    // MARK: - 混音器通道条

    /// 通道推子和声像。推子在轨道链里，所以它和 pre-gain 一样会被烤进渲染；
    /// 与它相对的是走带栏那根只管监听的总推子。
    @Published var laneFaderA: Double = 0
    @Published var laneFaderB: Double = 0
    @Published var panA: Int = 0
    @Published var panB: Int = 0

    func setLaneFader(_ db: Double, for side: TrackSide) {
        let clamped = max(Double(AudioEngine.laneFaderMinDB),
                          min(Double(AudioEngine.laneFaderMaxDB), db))
        if side == .a {
            laneFaderA = clamped
            engine.laneFaderDBA = Float(clamped)
        } else {
            laneFaderB = clamped
            engine.laneFaderDBB = Float(clamped)
        }
    }

    func setPan(_ value: Int, for side: TrackSide) {
        if side == .a { panA = value } else { panB = value }
        engine.setPan(side, to: value)
    }

    /// 峰值电平从引擎的抽头里取，单位 dBFS；界面自己负责保持与回落。
    /// `fresh` 说这一拍到底有没有新样本可读 —— 抽头 91.9 ms 才来一包，空手那一趟绝不能
    /// 当成静音（那正是电平表闪烁的来处）。这里一次取空，给探针用；表走 `laneWindowsDB`。
    func lanePeakDB(_ side: TrackSide) -> (left: Double, right: Double, fresh: Bool) {
        let p = engine.drainLanePeak(side)
        func db(_ v: Float) -> Double { v <= 1e-7 ? -96 : 20 * log10(Double(v)) }
        return (db(p.left), db(p.right), p.fresh)
    }

    /// 电平表的取数口：按时间要 `count` 个 5 ms 子窗，合成一个读数（子窗里取最大）。
    /// `taken == 0` 是「抽头还没交付这一批」而不是静音，界面要留着上一读数；
    /// `windowSeconds` 是子窗时长，界面用它把取窗节奏对上真实时间。
    func laneWindowsDB(_ side: TrackSide, count: Int)
        -> (peakDB: Double, windowSeconds: Double, taken: Int) {
        let drained = engine.drainLaneWindows(side, count: count)
        guard drained.taken > 0 else { return (-96, drained.windowSeconds, 0) }
        var v: Float = 0
        for window in drained.windows { v = max(v, max(window.left, window.right)) }
        return (v <= 1e-7 ? -96 : 20 * log10(Double(v)), drained.windowSeconds, drained.taken)
    }

    func toggleMixer() {
        // 守卫写在动作里：菜单项挂 .disabled 会把它自己的 ⌘5 一起吞掉（实测）。
        guard editMode, !abxIsActive else { return }
        MixerPanelController.shared.toggle(vm: self)
    }

    /// ⌘6：视频窗口。和混音器同一套独立面板，但门槛相反 —— 编辑模式与盲听期间画面无效。
    func toggleVideo() {
        guard !abxIsActive, !editMode else { return }
        VideoPanelController.shared.toggle(vm: self)
    }

    /// [A→B] / [B→A]：搬 pre-gain、推子、声像，插件链整条跟着搬。
    /// 搬过去的那份要重新实例化（同一个 unit 不能同时挂在两条链上），所以是异步的。
    func copyChannelStrip(from: TrackSide, to: TrackSide) {
        guard from != to else { return }
        beginEdit()
        let dB = from == .a ? preGainA : preGainB
        let fader = from == .a ? laneFaderA : laneFaderB
        let pan = from == .a ? panA : panB
        setPreGain(dB, for: to)
        setLaneFader(fader, for: to)
        setPan(pan, for: to)
        let snapshots = engine.slotSnapshots(from)
        let laneOff = engine.isLaneBypassed(from)
        restoreSlots(snapshots, laneBypass: laneOff, for: to)
    }

    /// 把一轨的插件链换成快照里的样子。不自己记历史：撤销恢复由 applyEditState 管，
    /// [A→B] 在调用前已经 beginEdit 过一次。
    private func restoreSlots(_ snapshots: [SlotSnapshot?], laneBypass: Bool, for side: TrackSide) {
        engine.restoreSlots(snapshots, laneBypass: laneBypass, for: side) { [weak self] in
            self?.refreshSlots()
        }
        refreshSlots()
    }

    // MARK: 插件槽

    /// 六格的显示状态，从引擎的 slotStates 抄过来。unit 存在引擎里，这里只管画。
    @Published private(set) var slotsA: [SlotState] = Array(repeating: SlotState(),
                                                             count: AudioEngine.slotCount)
    @Published private(set) var slotsB: [SlotState] = Array(repeating: SlotState(),
                                                             count: AudioEngine.slotCount)
    @Published private(set) var laneBypassA = false
    @Published private(set) var laneBypassB = false
    /// 浏览器开在哪一格（nil = 没开）。
    @Published var browserTarget: SlotTarget?
    /// 装不上时的原话，由通道条顶部的提示条显示；再点别处就没了。
    @Published var pluginError: String?

    func slots(_ side: TrackSide) -> [SlotState] { side == .a ? slotsA : slotsB }
    func laneBypass(_ side: TrackSide) -> Bool { side == .a ? laneBypassA : laneBypassB }

    /// 装载、卸载、改 bypass 之后都要走一次，让界面和引擎对上。
    func refreshSlots() {
        slotsA = engine.slotStates(.a)
        slotsB = engine.slotStates(.b)
        laneBypassA = engine.isLaneBypassed(.a)
        laneBypassB = engine.isLaneBypassed(.b)
        // 浮窗认的是「开窗那一刻的插件」。换插件、撤销、[A→B] 都汇到这里，所以
        // 对不上号的窗口在这儿关，不用每个改动点各记一遍。
        PluginEditorController.shared.syncWithEngine()
    }

    /// 点空槽 / ⌘F 都从这里开浏览器。目标轨默认是活动轨。
    func openBrowser(for slot: Int, side: TrackSide? = nil) {
        guard editMode, slot < AudioEngine.slotCount, !slots(side ?? activeTrack)[slot].loading else { return }
        pluginError = nil
        browserTarget = SlotTarget(side: side ?? activeTrack, index: slot)
    }

    func closeBrowser() { browserTarget = nil }

    /// ⌘F（混音器里）：查找插件并插进活动轨从上往下第一个空槽（Logic 同款）。
    /// 浏览器是挂在混音器窗口上的一张 sheet，所以窗口没开时先把它开起来 ——
    /// 不这么办的话，六格插件的入口就只剩「点空槽」一条路，鼠标得先找到那一格。
    func openPluginSearch() {
        guard editMode else { return }
        let side = activeTrack
        guard let index = slots(side).firstIndex(where: { !$0.loading && $0.plugin == nil }) else {
            pluginError = "\(side == .a ? "A" : "B") 轨插件已满"
            return
        }
        if !MixerPanelController.shared.isVisible { MixerPanelController.shared.open(vm: self) }
        openBrowser(for: index, side: side)
    }

    /// 1…6 / ⇧1…⇧6：这一格的编辑浮窗。开着就收起，收着就打开。
    func toggleSlotEditor(_ index: Int, for side: TrackSide) {
        guard editMode, (0..<AudioEngine.slotCount).contains(index) else { return }
        PluginEditorController.shared.toggle(vm: self, side: side, index: index)
    }

    /// V：所有开着的插件页面一起收起 / 一起放回来。
    func toggleAllPluginPages() {
        guard editMode else { return }
        PluginEditorController.shared.toggleAllPages()
    }

    /// 装一个插件进指定的格子。异步：AU 的实例化可能在主线程外跑几秒。
    func loadPlugin(_ plugin: AUPlugin, at index: Int, for side: TrackSide) {
        guard editMode, slots(side).indices.contains(index), slots(side)[index].plugin == nil else { return }
        beginEdit()
        refreshSlots()
        engine.loadPlugin(plugin, at: index, for: side) { [weak self] result in
            guard let self else { return }
            switch result {
            case .loaded:
                // 装完就把它自己的界面开出来：选完插件还要再点一格才见着界面，多此一举。
                PluginEditorController.shared.open(vm: self, side: side, index: index)
            case .stale:
                break
            case .failed(let error):
                // 没落地的编辑不进历史：留着它，用户按一次撤销看到的是无关的变化。
                self.history.dropLastRecord()
                self.pluginError = error.localizedDescription
            }
            self.refreshSlots()
        }
    }

    func unloadSlot(_ index: Int, for side: TrackSide) {
        guard editMode, slots(side)[index].plugin != nil else { return }
        beginEdit()
        engine.unloadPlugin(at: index, for: side)
        pluginError = nil
        refreshSlots()
    }

    /// 单格旁通开关。
    func toggleSlotBypass(_ index: Int, for side: TrackSide) {
        guard slots(side)[index].plugin != nil else { return }
        beginEdit()
        engine.setSlotBypass(index, for: side, !slots(side)[index].bypass)
        refreshSlots()
    }

    /// 整条链的旁通开关（通道条底部那颗）。
    func toggleLaneBypass(_ side: TrackSide) {
        beginEdit()
        engine.setLaneBypass(!(side == .a ? laneBypassA : laneBypassB), for: side)
        refreshSlots()
    }

    // MARK: - 拖拽调序

    /// 拖拽落格，三条路：
    /// 1. 同轨搬（没按 ⌥）：两格内容对调。unit 一颗都不动，所以是同步的，参数、浮窗背后
    ///    那颗实例全都跟着走。
    /// 2. ⌥ 复制（同轨跨轨都算）：落点按源那一格的身份和参数**重新实例化**（同一个 unit
    ///    不能挂在两处），落点原本有插件就被盖掉，源不动。
    /// 3. 跨轨搬：先在落点装成，装成功才回头动源——落点空着就擦掉源格（移动），落点被占
    ///    就把落点那颗也按快照装到源格（调换）。装不成的那一头保持原样，链子上落地的
    ///    部分留着，那一笔历史也留着，撤销能整笔收回。
    func applySlotDrag(from source: SlotTarget, to target: SlotTarget, copy: Bool) {
        guard editMode, source != target,
              (0..<AudioEngine.slotCount).contains(source.index),
              (0..<AudioEngine.slotCount).contains(target.index),
              let moved = engine.slotSnapshots(source.side)[source.index],
              moved.plugin != nil,
              !slots(source.side)[source.index].loading,
              !slots(target.side)[target.index].loading else { return }
        beginEdit()
        pluginError = nil

        if !copy, source.side == target.side {
            engine.exchangeSlots(source.index, target.index, for: source.side)
            PluginEditorController.shared.remap(side: source.side, source.index, target.index)
            refreshSlots()
            return
        }

        // 落点那一格此刻的样子要先抄下来：跨轨调换要用它去填源格，而第一趟装载会把它盖掉。
        let overwritten = engine.slotSnapshots(target.side)[target.index]
        installSnapshot(moved, at: target) { [weak self] first in
            guard let self else { return }
            guard case .loaded = first else {
                // 一步都没落地：链子没变过，那笔历史是空转，退掉（stale 不退：
                // 在途时被改通常是撤销/重做干的，那一头的账本来就不归这次拖拽）。
                if case .failed = first { self.history.dropLastRecord() }
                return
            }
            if copy { return }
            if source.side == target.side { return }        // 同轨复制走的就是这一头
            guard let swapped = overwritten, swapped.plugin != nil else {
                // 落点是空的：搬完了，把源格擦掉（单元放手，接线重来）。
                self.engine.unloadPlugin(at: source.index, for: source.side)
                self.refreshSlots()
                return
            }
            // 调换：落点那颗装进源格。装不成的话就退化成「复制了一份过去、源格还留着」，
            // 插件一个不丢，报错也在那一趟里报。
            self.installSnapshot(swapped, at: source) { _ in }
        }
    }

    /// 按快照在某一格装一个插件。不走 `loadPlugin` 那条包装：那条要求落点是空的，
    /// 还要在装完自动把浮窗弹出来 —— 拖拽落格不该再糊一扇窗在鼠标上。
    /// 历史也不在这里记：一次拖拽只该有一笔。
    private func installSnapshot(_ snapshot: SlotSnapshot, at target: SlotTarget,
                                 then next: @escaping (AudioEngine.SlotLoadResult) -> Void) {
        guard let plugin = snapshot.plugin else {
            DispatchQueue.main.async { next(.stale) }
            return
        }
        engine.loadPlugin(plugin, at: target.index, for: target.side,
                          state: snapshot.state) { [weak self] result in
            guard let self else { return }
            if case .loaded = result {
                self.engine.setSlotBypass(target.index, for: target.side, snapshot.bypass)
            }
            if case .failed(let error) = result { self.pluginError = error.localizedDescription }
            self.refreshSlots()
            next(result)
        }
    }

    /// 通道条上改名要同步列表里那一行：列表是名字的存放处，只改 trackA 的话下次
    /// 从列表重新指派就把新名字盖掉了。
    func renameAssignedTrack(_ side: TrackSide, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        beginEdit()
        if side == .a { trackA?.displayName = trimmed } else { trackB?.displayName = trimmed }
        let id = (side == .a ? trackA : trackB)?.id
        if let id {
            if let i = tracks.firstIndex(where: { $0.id == id }) { tracks[i].displayName = trimmed }
            if let i = backupTracks.firstIndex(where: { $0.id == id }) { backupTracks[i].displayName = trimmed }
        }
    }

    // MARK: 轨道预设

    /// 一条通道条现在的样子：pre-gain、声道推子、声像、整轨旁通和六格插件链（连着
    /// 各自的旋钮位置）。撤销快照里本来就有这几样，预设就是同一份内容单独写进磁盘。
    func channelPreset(for side: TrackSide) -> ChannelPreset {
        ChannelPreset(preGainDB: side == .a ? preGainA : preGainB,
                      faderDB: side == .a ? laneFaderA : laneFaderB,
                      pan: side == .a ? panA : panB,
                      laneBypass: engine.isLaneBypassed(side),
                      slots: engine.slotSnapshots(side))
    }

    /// 载入一份预放到这一轨。记一笔历史再动手：它和 [A→B] 一样是一次可撤销的编辑。
    func applyChannelPreset(_ preset: ChannelPreset, for side: TrackSide) {
        beginEdit()
        apply(preset, to: side)
    }

    /// 预设落地的实际动作，工程恢复也走这里（那边不记历史，见 restore(_:from:)）。
    /// 本机没有的插件先摘掉并报名字：引擎是顺序装的，第一格撞空就会把后面几格一起带走。
    private func apply(_ preset: ChannelPreset, to side: TrackSide) {
        let resolved = ProjectStore.resolve(preset.slots, catalog: PluginCatalog.effects())
        pluginError = resolved.missing.isEmpty
            ? nil
            : "本机缺少：\(resolved.missing.joined(separator: "、"))"
        setPreGain(preset.preGainDB, for: side)
        setLaneFader(preset.faderDB, for: side)
        setPan(preset.pan, for: side)
        restoreSlots(resolved.slots, laneBypass: preset.laneBypass, for: side)
    }

    /// 「载入预设」二级菜单点进来的那一下：直接读文件落到这一轨，不再过访达。
    func applyChannelPreset(at url: URL, for side: TrackSide) {
        guard editMode else { return }
        do { applyChannelPreset(try ProjectStore.readPreset(from: url), for: side) }
        catch { ProjectStore.notify("无法读取预设：\(error.localizedDescription)") }
    }

    /// 「恢复默认预设」：这一轨那份默认档，没有就是没有（菜单里那颗是灰的）。
    func restoreDefaultPreset(for side: TrackSide) {
        guard ProjectStore.hasDefaultPreset(for: side) else { return }
        applyChannelPreset(at: ProjectStore.defaultPresetURL(for: side), for: side)
    }

    /// 「保存当前预设为默认」：固定落到 Application Support 的「轨道预设」，
    /// 不跟面板上次去过的地方走 —— 默认档会搬家就没法恢复了。
    func saveDefaultPreset(for side: TrackSide) {
        guard editMode else { return }
        let url = ProjectStore.defaultPresetURL(for: side)
        do { try ProjectStore.write(preset: channelPreset(for: side), to: url) }
        catch { ProjectStore.notify("默认预设保存失败：\(error.localizedDescription)") }
    }

    /// 「保存预设」：名字手写，落到「载入预设」读的那一格文件夹，
    /// 同名先问覆盖。存的内容和默认档一模一样 —— 差别的只有名字和落点。
    func saveChannelPresetNamed(for side: TrackSide) {
        guard editMode, let name = ProjectStore.askPresetName() else { return }
        let url = ProjectStore.presetDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(ProjectStore.presetExtension)
        if FileManager.default.fileExists(atPath: url.path),
           !ProjectStore.confirmPresetOverwrite(name) { return }
        do { try ProjectStore.write(preset: channelPreset(for: side), to: url) }
        catch { ProjectStore.notify("预设「\(name)」保存失败：\(error.localizedDescription)") }
    }

    /// 「移除全部插件」：六格一次清干净，只记一笔历史。逐格调 unloadSlot 会记成六笔，
    /// 撤销一次只掉一格，那不是「移除全部」该有的样子。
    func removeAllPlugins(for side: TrackSide) {
        guard editMode, slots(side).contains(where: { $0.plugin != nil }) else { return }
        beginEdit()
        for index in 0..<AudioEngine.slotCount where slots(side)[index].plugin != nil {
            engine.unloadPlugin(at: index, for: side)
        }
        pluginError = nil
        refreshSlots()
    }

    // MARK: 工程文件

    /// 现在挂着的那份工程。nil = 这个会话还没 ⌘S 过，那一下先开面板（就是「存储为…」）。
    @Published private(set) var projectURL: URL?

    /// 会话此刻的存档形状。播放头、选中行、缩放和动态深度不进来：那是「怎么看」，
    /// 不是「在做什么」，和撤销快照的取舍一致。
    func projectFile() -> ProjectFile {
        let size = WindowDefaults.target?.frame.size
        return ProjectFile(tracks: tracks,
                           backupTracks: backupTracks,
                           trackAID: trackA?.id,
                           trackBID: trackB?.id,
                           markers: MarkerStore.shared.allMarkers,
                           rangeA: rangeA,
                           rangeB: rangeB,
                           trimA: timeTrim(.a),
                           trimB: timeTrim(.b),
                           outputGainDB: SettingsStore.shared.outputGainDB,
                           compareMode: compareMode,
                           editMode: editMode,
                           laneA: channelPreset(for: .a),
                           laneB: channelPreset(for: .b),
                           windowWidth: size.map { Double($0.width) },
                           windowHeight: size.map { Double($0.height) })
    }

    /// ⌘S：认得路径就直接写回去，不认得才问地方。
    func saveProject() {
        if let url = projectURL { writeProject(to: url) } else { saveProjectAs() }
    }

    /// ⇧⌘S：每次都问。
    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedProjectName()
        panel.directoryURL = ProjectStore.projectDirectory
        panel.allowedContentTypes = ProjectStore.contentTypes(ProjectStore.projectExtension)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProjectStore.projectDirectory = url.deletingLastPathComponent()
        writeProject(to: url)
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = ProjectStore.projectDirectory
        panel.allowedContentTypes = ProjectStore.contentTypes(ProjectStore.projectExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProjectStore.projectDirectory = url.deletingLastPathComponent()
        loadProject(from: url)
    }

    func loadProject(from url: URL) {
        do { restore(try ProjectStore.readProject(from: url), from: url) }
        catch { ProjectStore.notify("无法读取工程：\(error.localizedDescription)") }
    }

    /// 启动时把上一次 ⌘S 存过的那份直接恢复回来（「下次打开直接恢复」）。
    /// 文件没了就当用户已经换过环境，只把这条记忆清掉，不弹窗拦启动。
    func restoreLastProjectAtLaunch() {
        guard let url = ProjectStore.lastProjectURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        loadProject(from: url)
    }

    /// 真正落盘的那一步。「存储为…」选好路径也是走到这儿：路径一确认就当工程挂上了，
    /// 之后的 ⌘S 不再问地方。
    func writeProject(to url: URL) {
        do {
            try ProjectStore.write(project: projectFile(), to: url)
            projectURL = url
            ProjectStore.lastProjectURL = url
            ProjectStore.applyIcon(to: url)
        } catch {
            ProjectStore.notify("工程保存失败：\(error.localizedDescription)")
        }
    }

    private func suggestedProjectName() -> String {
        let raw = trackA?.displayName ?? ""
        let base = (raw as NSString).deletingPathExtension
        return "\(base.isEmpty ? "未命名工程" : base).\(ProjectStore.projectExtension)"
    }

    /// 恢复的次序是有讲究的：先把两条列表和标记摆好，再把 A/B 交出去解（异步，界面
    /// 等 loadPending 归零），然后立起编辑模式，最后才灌通道条 —— 插件链活在编辑模式
    /// 那条拓扑上，模式没进来就接线会接空。
    /// 载入工程不是「一次可撤销的编辑」：它换的是整个会话，和换曲一样把历史清掉。
    private func restore(_ project: ProjectFile, from url: URL) {
        pause()
        tracks = Self.revived(project.tracks)
        backupTracks = Self.revived(project.backupTracks)
        MarkerStore.shared.restoreAll(project.markers)
        SettingsStore.shared.outputGainDB = project.outputGainDB
        setOutputGain(project.outputGainDB)
        // 一份存档不该自动把人拉进一轮盲听：那一档回落到版本对比，其余照旧。
        setCompareMode(project.compareMode == .abx ? .versionCompare : project.compareMode)
        rangeA = project.rangeA
        rangeB = project.rangeB

        var gone: [String] = []
        if let a = track(matching: project.trackAID) {
            if FileManager.default.fileExists(atPath: a.url.path) { loadTrackAFromTrack(a) }
            else { markMissing(a.id); gone.append("A 轨 \(a.displayName)") }
        }
        if let b = track(matching: project.trackBID) {
            if FileManager.default.fileExists(atPath: b.url.path) { loadTrackBFromTrack(b) }
            else { markMissing(b.id); gone.append("B 轨 \(b.displayName)") }
        }
        selectedTrackIndex = tracks.firstIndex { $0.id == project.trackAID }
        projectURL = url
        ProjectStore.lastProjectURL = url

        setEditMode(project.editMode)
        apply(project.laneA, to: .a)
        apply(project.laneB, to: .b)
        // 偏移排在通道条之后：解轨那一步会把这一轨的 trim 归零（同步做完），
        // 存档里的值盖在它后面才对。这里也不等那 300 ms，当场灌给引擎。
        setTimeTrim(project.trimA, for: .a, recordHistory: false)
        setTimeTrim(project.trimB, for: .b, recordHistory: false)
        flushTimeTrim()
        if let width = project.windowWidth, let height = project.windowHeight, width > 0, height > 0 {
            WindowDefaults.apply(size: CGSize(width: width, height: height))
        }
        refreshMarkers()
        clearEditHistory()
        if !gone.isEmpty {
            ProjectStore.notify("无法找到：\n\(gone.joined(separator: "\n"))\n"
                                + "列表中对应条目已标灰，插件正常恢复。")
        }
    }

    /// A/B 存的是列表里的 id：它可能只存在于备用列表（那边也能设为轨道），所以两张表都找。
    private func track(matching id: UUID?) -> Track? {
        guard let id else { return nil }
        return tracks.first { $0.id == id } ?? backupTracks.first { $0.id == id }
    }

    private func markMissing(_ id: UUID) {
        if let i = tracks.firstIndex(where: { $0.id == id }) { tracks[i].missing = true }
        if let i = backupTracks.firstIndex(where: { $0.id == id }) { backupTracks[i].missing = true }
    }

    /// 「文件没了」是打开那一刻的事，不跟着存档走：和备用列表恢复的规矩一致。
    private static func revived(_ list: [Track]) -> [Track] {
        list.map { var track = $0; track.missing = false; return track }
    }

    /// Push engine positions into the observable clock (drives playheads).
    func refreshClock() {
        let a = engine.position(of: .a)
        let b = engine.position(of: .b)
        if clock.posA != a { clock.posA = a }
        if clock.posB != b { clock.posB = b }
    }


    // MARK: - 撤销 / 重做

    let history = EditHistory()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// 撤销能回到的状态：只有用户内容进快照。播放头、选中行、缩放、深度、模式
    /// 都不在里头，A/B 换了曲子更是直接把栈清掉。
    func editState() -> EditState {
        EditState(tracks: tracks,
                  backupTracks: backupTracks,
                  markers: MarkerStore.shared.allMarkers,
                  rangeA: rangeA,
                  rangeB: rangeB,
                  trimA: timeTrim(.a),
                  trimB: timeTrim(.b),
                  outputGainDB: SettingsStore.shared.outputGainDB,
                  preGainA: preGainA,
                  preGainB: preGainB,
                  laneFaderA: laneFaderA,
                  laneFaderB: laneFaderB,
                  panA: panA,
                  panB: panB,
                  slotsA: engine.slotSnapshots(.a),
                  slotsB: engine.slotSnapshots(.b),
                  laneBypassA: engine.isLaneBypassed(.a),
                  laneBypassB: engine.isLaneBypassed(.b))
    }

    /// Call before an edit so 撤销 has the state to return to.
    func beginEdit() {
        history.record(editState())
        refreshHistoryFlags()
    }

    /// 换曲 is not undoable, and a snapshot taken against the old pair of songs
    /// would restore markers and ranges onto the wrong files.
    func clearEditHistory() {
        history.clear()
        refreshHistoryFlags()
    }

    func undoEdit() {
        guard let before = history.undo(current: editState()) else { return }
        applyEditState(before)
        refreshHistoryFlags()
    }

    func redoEdit() {
        guard let after = history.redo(current: editState()) else { return }
        applyEditState(after)
        refreshHistoryFlags()
    }

    private func applyEditState(_ s: EditState) {
        tracks = s.tracks
        backupTracks = s.backupTracks
        MarkerStore.shared.restoreAll(s.markers)
        rangeA = s.rangeA
        rangeB = s.rangeB
        // 撤销/重做要立刻听见结果，所以不走那 300 ms 的沉降：记历史也交给这一步之外
        // （快照本身已经是历史的一环，再记一次会多出一格空档）。
        setTimeTrim(s.trimA, for: .a, recordHistory: false)
        setTimeTrim(s.trimB, for: .b, recordHistory: false)
        flushTimeTrim()
        SettingsStore.shared.outputGainDB = s.outputGainDB
        setOutputGain(s.outputGainDB)
        setPreGain(s.preGainA, for: .a)
        setPreGain(s.preGainB, for: .b)
        setLaneFader(s.laneFaderA, for: .a)
        setLaneFader(s.laneFaderB, for: .b)
        setPan(s.panA, for: .a)
        setPan(s.panB, for: .b)
        // 插件链要重新接线、可能还要重新实例化；unit 还在路上的那几格由引擎自己
        // 记账，界面等它的 completion。
        restoreSlots(s.slotsA, laneBypass: s.laneBypassA, for: .a)
        restoreSlots(s.slotsB, laneBypass: s.laneBypassB, for: .b)
        // Rows shift under a selection the snapshot deliberately does not carry.
        if let i = selectedTrackIndex, i >= tracks.count {
            selectedTrackIndex = nil
            mainMulti = []
        }
        if let i = backupSelectedIndex, i >= backupTracks.count {
            backupSelectedIndex = nil
            backupMulti = []
        }
        refreshMarkers()
    }

    private func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: - File Loading

    /// Security-scoped access is kept for the app lifetime: decoding happens
    /// asynchronously and tracks can be re-loaded from the playlist later.
    private var scopedURLs = Set<String>()

    func openFiles(urls: [URL]) {
        beginEdit()
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                scopedURLs.insert(url.path)
            }
            var track = Track(url: url)
            if let meta = engine.readMetadata(url: url) {
                track.updateMetadata(duration: meta.duration, channels: meta.channels,
                                    sampleRate: meta.sampleRate, bitrate: meta.bitrate)
            }
            tracks.append(track)
            if trackA == nil {
                loadTrackAFromTrack(track)
            } else if trackB == nil {
                loadTrackBFromTrack(track)
            }
        }

        if selectedTrackIndex == nil && !tracks.isEmpty {
            selectedTrackIndex = 0
        }
    }

    func loadTrackAFromTrack(_ track: Track) {
        loadSide(.a, track: track)
    }

    func loadTrackBFromTrack(_ track: Track) {
        loadSide(.b, track: track)
    }

    private func loadSide(_ side: TrackSide, track: Track) {
        let url = track.url
        // 重新指派 = 这一轨立刻停。只停被指派那一条，另一条接着放；
        // 停走的是 H 那套（`engine.stopSide`：播放头归零），不是界面那颗 `stopSide`，
        // 它在同步模式下会把两轨一起停掉。引擎里的节点不会自己停 —— 换缓冲只是把
        // 下一份排上去，旧的那一趟还在跑，直到下一次走带才被动改。
        // 顺带占住装载闸门：新文件解码完之前这一轨的播放指令一律忽略，那时节点上
        // 挂的还是上一份，一放就播旧文件。这一轨停在这儿就停到使用者自己再按一下播放 ——
        // 装完不自动接回去（只说了停，没说停多久）。
        engine.stopSide(side)
        engine.beginLoad(side)
        refreshPlayStateFlags()
        refreshClock()
        // Assign the slot synchronously so the next dropped file targets the other side
        if side == .a { trackA = track } else { trackB = track }
        // 换曲就把这一轨的偏移清掉：它是「这两条轨怎么对齐」的参数，曲目一换就没有
        // 旧意义了。同步做，赶在任何异步回话之前 —— 工程恢复在那之后自己把值灌回来。
        setTimeTrim(0, for: side, recordHistory: false)
        applyTimeTrim(0, for: side)
        loadPending += 1
        Task {
            // 解码在前：系统读不了的容器（ogg/opus/wma/ape/wv/dsf）先要一份缓存 wav，转完
            // 整条链拿它当普通 wav 用，只有轨道行、章节、导出名仍旧跟着原文件（实测那支
            // 3 分 49 秒的 opus 转完 0.6 秒，所以这一趟不该挂在主线程上）。
            let decoded: (audio: URL, failure: String?) =
                await Task.detached(priority: .userInitiated) {
                    do { return (try AudioFormatCache.resolve(url), nil) }
                    catch { return (url, error.localizedDescription) }
                }.value

            // 时长、采样率这些只有解码好的那份才读得出来（原容器 AVAudioFile 开不了），
            // 所以行上先空着，解码一完就补：不补的话信息面板、章节转标记的落点判断都拿到 0。
            let loaded: Track
            if let meta = engine.readMetadata(url: url) {
                var updated = track
                updated.updateMetadata(duration: meta.duration, channels: meta.channels,
                                       sampleRate: meta.sampleRate, bitrate: meta.bitrate)
                // 补出来的元数据要回行上，但只能在主线程回：这一趟是后台任务，主线程同
                // 一刻正在 `openFiles` 里往 tracks 追加，两边同抢 Combine 的发信锁 —— 实测
                // 一次拖两个文件就双双停在锁上，主线程再也醒不过来。
                let refreshed = updated
                await MainActor.run { self.refreshRow(refreshed) }
                loaded = updated
            } else {
                loaded = track
            }

            let result: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    if side == .a { try AudioEngine.shared.loadTrackA(url: decoded.audio) }
                    else { try AudioEngine.shared.loadTrackB(url: decoded.audio) }
                    return nil
                } catch {
                    return error
                }
            }.value

            // 闸门在旧缓冲被换掉这一刻就放，不等波形：新文件已经挂在节点上了，
            // 多等那几秒解码峰只是白按住这一轨（章节、峰仍旧在路上补）。
            await MainActor.run { self.engine.endLoad(side) }

            // 章节在波形解码之前就到手：一首曲子解码要跑好几秒，标记跟着解码走的话，
            // 点完文件得空等好几秒才看见 ▲。读元数据不碰解码，单独一个子任务。
            // 读的始终是原文件：缓存那份 wav 里没有章节。
            let fileChapters = await Task.detached(priority: .userInitiated) {
                PlayerViewModel.readChapters(from: url)
            }.value

            await MainActor.run {
                // 章节有两个读者：进度条上的章节菜单只认 A 轨那份（老行为，没动），
                // 转标记只认「落点」那一轨。
                if side == .a { self.chapters = fileChapters }
                if let landing = self.chapterLanding(for: side) {
                    self.importChapters(fileChapters, onto: landing, fileLength: loaded.duration)
                }
            }

            let peaks = await Task.detached(priority: .utility) {
                WaveformGenerator.generate(url: decoded.audio)
            }.value

            await MainActor.run {
                if let result { print("Failed to load track \(side.rawValue): \(result)") }
                #if DEBUG
                // AB_PEAKLOG：装载那一趟的三本账（解码用的是哪份、元数据、峰）。波形画不出来
                // 时先分清是没解出来、还是解出来了没画。
                if ProcessInfo.processInfo.environment["AB_PEAKLOG"] != nil {
                    FileHandle.standardError.write(("PEAK \(side.rawValue) 解码=\(decoded.audio.lastPathComponent) "
                            + "元数据=\(loaded.duration > 0 ? String(format: "%.3f", loaded.duration) : "无") "
                            + "峰=\(peaks.map { "\(Int($0.binCount)) bin / \($0.channelCount) ch / \(String(format: "%.3f", $0.duration)) s" } ?? "nil")\n")
                        .data(using: .utf8)!)
                }
                #endif
                self.loadPending -= 1
                if side == .a {
                    self.waveformPeaksA = peaks ?? .empty
                } else {
                    self.waveformPeaksB = peaks ?? .empty
                }
                // 这一句把三个 markers 数组按 MarkerStore 重建：转来的标记就存在 MarkerStore
                // 里，所以刷一遍照样在。
                self.refreshMarkers()
                // 解不开、或者机器上没装 ffmpeg：这一轨现在是静音的空轨，得说一声。
                // 只在「这一轨此刻还挂着那个文件」时说，一次拖十个坏文件不会弹十层。
                if let failure = decoded.failure,
                   (side == .a ? trackA?.url : trackB?.url) == url {
                    ProjectStore.notify("\(url.lastPathComponent)：\(failure)")
                }
            }
        }
    }

    /// 把补好元数据的那一份放回它来的地方：两条列表里的同一行，还有此刻挂着它的 A/B 轨。
    /// 按 id 认，不按 url —— 同一首歌可以同时在两条列表里。
    private func refreshRow(_ updated: Track) {
        if let i = tracks.firstIndex(where: { $0.id == updated.id }) { tracks[i] = updated }
        if let i = backupTracks.firstIndex(where: { $0.id == updated.id }) { backupTracks[i] = updated }
        if trackA?.id == updated.id { trackA = updated }
        if trackB?.id == updated.id { trackB = updated }
    }

    func setTrackA(index: Int) {
        guard index < tracks.count else { return }
        clearEditHistory()
        guard ensureFilePresent(isMain: true, index: index) else { return }
        loadTrackAFromTrack(tracks[index])
    }

    func setTrackB(index: Int) {
        guard index < tracks.count else { return }
        clearEditHistory()
        guard ensureFilePresent(isMain: true, index: index) else { return }
        loadTrackBFromTrack(tracks[index])
    }

    /// Assigning to A/B is the only moment we check the file on disk
    /// (restored backup-list rows are not validated at launch).
    /// Returns false and greys the row out when the file is gone.
    private func ensureFilePresent(isMain: Bool, index: Int) -> Bool {
        let exists: Bool
        if isMain {
            exists = FileManager.default.fileExists(atPath: tracks[index].url.path)
            if tracks[index].missing != !exists { tracks[index].missing = !exists }
        } else {
            exists = FileManager.default.fileExists(atPath: backupTracks[index].url.path)
            if backupTracks[index].missing != !exists { backupTracks[index].missing = !exists }
        }
        return exists
    }

    // MARK: - Playback

    /// Reference mode drives each side independently; other modes keep A/B synced.
    private var independentSides: Bool { compareMode == .reference }

    // MARK: - 时间偏移（time trim）

    /// 每一轨在刻度上的错位，秒。引擎那一份是「音频已经在用」的值，界面上这一份是
    /// 你正在拧的值：拖动途中只动界面，松手或停步 300 ms 之后才重排一次音频。
    /// 参数式 —— 样本一个都不搬，改的是排期起点和映射。
    @Published private(set) var timeTrimA: TimeInterval = 0
    @Published private(set) var timeTrimB: TimeInterval = 0
    private var trimSettle: [TrackSide: DispatchWorkItem] = [:]
    private static let trimSettleDelay = 0.3
    /// 一笔拖拽只记一次历史：按下时起头，中途每一步都不再记。
    private var trimDragRecorded = false

    func timeTrim(_ side: TrackSide) -> TimeInterval { side == .a ? timeTrimA : timeTrimB }

    /// 这一轨在刻度上占多长（进度条、波形、时间读数的跨度）。
    func laneDuration(_ side: TrackSide) -> TimeInterval {
        max(0, (side == .a ? engine.durationA : engine.durationB) + timeTrim(side))
    }

    /// 旋钮要按「一个样本」那一档走，采样率得交给它自己算步长。
    func trimSampleRate(for side: TrackSide) -> Double { engine.sampleRate(for: side) }

    /// 界面上的时间（刻度、播放头）→ 文件里的时间。标记、区间、章节、导出都认文件时间，
    /// 偏移只影响监听和显示，所以只有画在条上和从条上点回来的那两处要换算。
    func fileTime(_ lane: TimeInterval, side: TrackSide) -> TimeInterval {
        lane - timeTrim(side)
    }

    func laneTime(_ file: TimeInterval, side: TrackSide) -> TimeInterval {
        file + timeTrim(side)
    }

    /// 拖拽的一小步（滚轮状按钮）、输入框给的一个数、换曲时的归零，都从这一入口进来。
    /// `recordHistory` 只有按下那一步给 true：一笔拖拽撤销一次就回到起手的偏移。
    func setTimeTrim(_ raw: TimeInterval, for side: TrackSide, recordHistory: Bool = true) {
        let fileDuration = side == .a ? engine.durationA : engine.durationB
        let rate = engine.sampleRate(for: side)
        // 样本精度那一档给的是 1/48000 秒这种数：先折到整帧上，界面上才不会挂着一个
        // 转不回样本的零头。量程卡在 ±文件时长 —— 最多把刻度拉长一倍，或缩到没有；
        // 还没解出时长的空轨不认任何偏移。
        var value = rate > 0 ? (raw * rate).rounded() / rate : raw
        value = fileDuration > 0 ? min(max(value, -fileDuration), fileDuration) : 0
        guard abs(value - timeTrim(side)) > (rate > 0 ? 0.5 / rate : 0.000001) else { return }
        if recordHistory { beginEdit() }
        if side == .a { timeTrimA = value } else { timeTrimB = value }
        trimSettle[side]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyTimeTrim(value, for: side) }
        trimSettle[side] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.trimSettleDelay, execute: work)
    }

    /// ⌥ 点按：归零。走的是同一个入口，所以也一样 300 ms 之后才重排。
    func resetTimeTrim(_ side: TrackSide) {
        setTimeTrim(0, for: side)
    }

    func beginTimeTrimDrag() {
        if !trimDragRecorded { beginEdit(); trimDragRecorded = true }
    }

    func endTimeTrimDrag() {
        trimDragRecorded = false
    }

    /// 停手 300 ms（或换曲、恢复工程那类要立即生效的场合）才把偏移交给引擎：引擎那头
    /// 若在放，会从轨内当前位置重排一次。值没变就不写 —— 写一次就重排一次，白出一声。
    /// 不清 `trimSettle` 里那一条：它是这次派出去的活儿，留着才能让下一步把它撤销；
    /// 做完的活儿再 cancel 一次也只是空转。
    private func applyTimeTrim(_ value: TimeInterval, for side: TrackSide) {
        guard engine.trim(side) != value else { return }
        if side == .a { engine.trimA = value } else { engine.trimB = value }
    }

    /// 动走带之前先把在途的偏移落地：不然「你在条上点的那一格」和「音频此刻在哪」
    /// 会差着那 300 ms 里没交出去的零头。没在途时这是个空操作（也不重排，不出声）。
    private func flushTimeTrim() {
        for side in [TrackSide.a, .b] {
            trimSettle[side]?.cancel()
            trimSettle[side] = nil
            applyTimeTrim(timeTrim(side), for: side)
        }
    }

    func position(of side: TrackSide) -> TimeInterval {
        engine.position(of: side)
    }

    func sideIsPlaying(_ side: TrackSide) -> Bool {
        // Always the lane's own state. The old read used `isPlaying` outside 参考曲,
        // and that is A OR B: with one lane only loaded, or one already finished, the
        // transport button answered for the other lane and looked frozen.
        side == .a ? sidePlayingA : sidePlayingB
    }

    /// Mirror the engine into the three published flags. Every transport call takes
    /// its state from here rather than waiting for the 20 Hz tick, so the button
    /// changes in the same runloop turn as the key press.
    private func refreshPlayStateFlags() {
        isPlaying = engine.isPlaying
        sidePlayingA = engine.isPlaying(.a)
        sidePlayingB = engine.isPlaying(.b)
    }

    /// 走带上的播放/暂停按「两条腿是不是都在放」判，不按选中轨判。
    /// 在版本对比里换曲那一拍只停被指派的那一轨，另一轨还在放，
    /// 这时按下走带键按选中轨判就会走到「全停」那一路 —— 全停了，新那份又还没起来，
    /// 十轮重载里有五轮两头一起停在 0（`放0/界面0`、`峰=0.0000`），就是反馈里那句
    /// 「随便重载入几次视频就全播不了」。同步模式下走带是一整条，半停半放不该算「在放」。
    private var transportAllPlaying: Bool { engine.isPlaying(.a) && engine.isPlaying(.b) }

    func toggleSide(_ side: TrackSide) {
        flushTimeTrim()
        if independentSides {
            engine.toggleSide(side)
        } else {
            setActiveTrack(side)
            engine.togglePlayPauseAll()
        }
        refreshPlayStateFlags()
    }

    func stopSide(_ side: TrackSide) {
        flushTimeTrim()
        if independentSides {
            engine.stopSide(side)
        } else {
            engine.stopAll()
        }
        refreshPlayStateFlags()
        refreshClock()
    }

    /// `time` 是轨内时间（条上点哪儿就是哪儿）。
    func seekSide(_ side: TrackSide, to time: TimeInterval) {
        flushTimeTrim()
        if independentSides {
            engine.seekSide(side, to: time)
        } else {
            engine.seekAll(to: time)
        }
        refreshClock()
    }

    func play() {
        // 「在放」按整条走带算：半停半放时（换曲那一拍）这一按得把停着的那一腿接起来，
        // 读「或」就直接 return 了 —— 见 `transportAllPlaying`。
        if transportAllPlaying { return }
        flushTimeTrim()
        engine.playAll()
        refreshPlayStateFlags()
    }

    func playFromStart() {
        flushTimeTrim()
        engine.seekAll(to: 0)
        engine.playAll()
        refreshPlayStateFlags()
    }

    func pause() {
        flushTimeTrim()
        engine.pauseAll()
        refreshPlayStateFlags()
    }

    func togglePlayPause() {
        if independentSides {
            toggleSide(activeTrack)
            return
        }
        flushTimeTrim()
        // 空格跟走带按钮读同一件事 —— 整条走带。原来只读选中轨：半停半放那一下（换曲
        // 那一拍就是这个形状）会走到 pauseAll，新文件永远起不来，见 `transportAllPlaying`。
        // 用整体 isPlaying（取或）判也不行 —— 选中轨已停、另一轨还在播，那一下按下去
        // 只会 pauseAll，按钮一动不动。
        if transportAllPlaying {
            engine.pauseAll()
        } else {
            engine.playAll()
        }
        refreshPlayStateFlags()
    }

    func stopPlayback() {
        flushTimeTrim()
        engine.stopAll()
        refreshPlayStateFlags()
        refreshClock()
    }

    func seek(to time: TimeInterval) {
        seekSide(activeTrack, to: time)
    }

    /// Z — 复位视图：横向缩放回 1×，动态深度回到默认档。
    func resetWaveformView() {
        waveformHorizontalZoom = 1
        SettingsStore.shared.waveformDepthDB = SettingsStore.defaultDepthDB
    }

    /// Pointer-driven seek on a progress bar. ⇧ takes the other lane to the same
    /// time point too; each lane still stops at its own file end, and in 版本对比
    /// the lanes are locked anyway so ⇧ changes nothing there.
    func pointerSeek(_ side: TrackSide, to time: TimeInterval, bothLanes: Bool) {
        flushTimeTrim()
        guard bothLanes, independentSides else {
            seekSide(side, to: time)
            return
        }
        // ⇧ 那一枪带着另一轨落到刻度的同一个位置：两条轨各自的偏移不同，所以文件里
        // 的落点也不同 —— 对齐的是「看起来的那一格」，不是文件里的同一秒。
        engine.seekSide(.a, to: time)
        engine.seekSide(.b, to: time)
        refreshClock()
    }

    // MARK: - Timecode entry

    func beginTimecodeEntry(syncBoth: Bool) {
        guard currentTrack != nil else { return }
        timecodeSyncBoth = syncBoth
        timecodeEditing = true
    }

    /// Space-separated groups, most-significant first: `2` = 2:00, `2 3` = 2:03,
    /// `1 2 3` = 1:02:03. Anything past the end of the track is a silent no-op.
    func commitTimecode(_ raw: String) {
        timecodeEditing = false
        let groups = raw.split(whereSeparator: { $0 == " " }).map(String.init)
        guard !groups.isEmpty, groups.count <= 3,
              groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return }
        var nums: [Int] = []
        for group in groups { guard let n = Int(group) else { return }; nums.append(n) }

        var h = 0, m = 0, s = 0
        switch nums.count {
        case 1: m = nums[0]
        case 2: m = nums[0]; s = nums[1]
        default: h = nums[0]; m = nums[1]; s = nums[2]
        }
        let target = TimeInterval(h * 3600 + m * 60 + s)

        // 大时钟写的就是轨内时间，所以打进去的那一串也是：夹在轨内跨度上，不是文件长度。
        if timecodeSyncBoth {
            guard target <= Swift.max(laneDuration(.a), laneDuration(.b)) else { return }
            flushTimeTrim()
            engine.seekAll(to: target)
            refreshClock()
        } else {
            guard target <= laneDuration(activeTrack) else { return }
            seekSide(activeTrack, to: target)
        }
    }

    func switchTrack() {
        engine.switchTrack()
        activeTrack = engine.activeTrack
        loadMarkers(for: currentTrack?.url)
        refreshClock()
    }

    func setActiveTrack(_ side: TrackSide) {
        engine.setActiveTrack(side)
        activeTrack = engine.activeTrack
        loadMarkers(for: currentTrack?.url)
        refreshClock()
    }

    // MARK: - Nudge / Sync / Remove

    /// Within this of the top, Enter counts as "already at the beginning".
    static let startTolerance: TimeInterval = 0.05

    /// J / L and their ⇧ fine variants. 版本对比 keeps both lanes locked, so ⌃ is
    /// meaningless there; in 参考曲 each lane moves by the same delta from its own
    /// position unless ⌃ narrows it to the current one.
    func nudge(by delta: TimeInterval, currentTrackOnly: Bool) {
        guard independentSides, !currentTrackOnly else {
            seek(to: max(0, min(laneDuration(activeTrack), currentPosition + delta)))
            return
        }
        flushTimeTrim()
        for side in [TrackSide.a, .b] {
            engine.seekSide(side, to: position(of: side) + delta)
        }
        refreshClock()
    }

    /// K: play/pause both lanes; ⌃ in 参考曲 narrows it to the current lane.
    func syncTogglePlayPause(currentTrackOnly: Bool) {
        if independentSides && currentTrackOnly {
            toggleSide(activeTrack)
            refreshClock()
            return
        }
        flushTimeTrim()
        // 基准是「整条走带」：两条腿都在放才一起停，只要有一腿停着（换曲那一拍就是这样）
        // 这一按就是起播两条腿。原来读的是 engine.togglePlayPauseAll 里的「或」，另一轨
        // 还在放时，这一按只会再停一次，选中轨看起来永远停在播放。
        if transportAllPlaying {
            engine.pauseAll()
        } else {
            engine.playAll()
        }
        refreshPlayStateFlags()
        refreshClock()
    }

    /// Enter. 版本对比 sends both playheads to the top; 参考曲 resets the current
    /// lane, and once that one is already at the top it takes the other lane too.
    func rewindToStart() {
        flushTimeTrim()
        guard independentSides else {
            engine.seekAll(to: 0)
            refreshClock()
            return
        }
        let sides: [TrackSide] = position(of: activeTrack) < Self.startTolerance
            ? [.a, .b] : [activeTrack]
        for side in sides { engine.seekSide(side, to: 0) }
        refreshClock()
    }

    /// ⇧↩: 无条件两条腿一起回开头。↩ 在参考曲下要先空按一次才带走另一轨，
    /// 这个键就是省掉那一次。
    func rewindAllToStart() {
        flushTimeTrim()
        engine.seekAll(to: 0)
        refreshClock()
    }

    func removeTrack(index: Int) {
        guard index < tracks.count else { return }
        beginEdit()
        tracks.remove(at: index)
        mainMulti = []
        if selectedTrackIndex == index { selectedTrackIndex = nil }
        else if let sel = selectedTrackIndex, sel > index { selectedTrackIndex = sel - 1 }
    }

    func removeBackupTrack(index: Int) {
        guard index < backupTracks.count else { return }
        beginEdit()
        backupTracks.remove(at: index)
        backupMulti = []
        if backupSelectedIndex == index { backupSelectedIndex = nil }
        else if let sel = backupSelectedIndex, sel > index { backupSelectedIndex = sel - 1 }
    }

    func removeSelectedTrack() {
        removeSelected(isMain: true)
    }

    // MARK: - Markers

    // 标记存的是文件时间（跟着曲目走，偏移变了也不该挪），所以「记下现在」和「跳到它」
    // 都要过一次轨内 ⇄ 文件的换算；条上画的那一截跟着挪，见 ContentView 的 trackSection。

    /// Backtick: a global marker on BOTH loaded tracks (drawn above the bars).
    func addGlobalMarkerAtCurrentPosition() {
        guard trackA != nil || trackB != nil else { return }
        beginEdit()
        if let a = trackA {
            MarkerStore.shared.addMarker(at: fileTime(position(of: .a), side: .a),
                                         for: a.url, kind: .global)
        }
        if let b = trackB {
            MarkerStore.shared.addMarker(at: fileTime(position(of: .b), side: .b),
                                         for: b.url, kind: .global)
        }
        refreshMarkers()
    }

    /// M: a side marker only on the track shown in the A/B indicator (below the bar).
    func addSideMarkerAtCurrentPosition() {
        guard let track = currentTrack else { return }
        beginEdit()
        let kind: MarkerKind = activeTrack == .a ? .sideA : .sideB
        MarkerStore.shared.addMarker(at: fileTime(currentPosition, side: activeTrack),
                                     for: track.url, kind: kind)
        refreshMarkers()
    }

    func deleteNearestMarker() {
        guard let track = currentTrack else { return }
        let allMarkers = MarkerStore.shared.markers(for: track.url)
        guard !allMarkers.isEmpty else { return }

        // Find the nearest marker to current position（两边都换成文件时间再比）
        let pos = fileTime(currentPosition, side: activeTrack)
        let nearest = allMarkers.min(by: { abs($0.position - pos) < abs($1.position - pos) })
        guard let markerToDelete = nearest else { return }

        beginEdit()
        MarkerStore.shared.removeMarker(markerToDelete, for: track.url)
        refreshMarkers()
    }

    func refreshMarkers() {
        markersA = trackA.map { MarkerStore.shared.markers(for: $0.url) } ?? []
        markersB = trackB.map { MarkerStore.shared.markers(for: $0.url) } ?? []
        loadMarkers(for: currentTrack?.url)
    }

    func loadMarkers(for url: URL?) {
        guard let url else { markers = []; return }
        markers = MarkerStore.shared.markers(for: url)
    }

    func jumpToPrevMarker() {
        guard !markers.isEmpty else { return }
        let pos = fileTime(currentPosition, side: activeTrack)
        let prev = markers.filter { $0.position < pos - 0.1 }.last
            ?? markers.last
        if let m = prev {
            seek(to: laneTime(m.position, side: activeTrack))
        }
    }

    func jumpToNextMarker() {
        guard !markers.isEmpty else { return }
        let pos = fileTime(currentPosition, side: activeTrack)
        let next = markers.filter { $0.position > pos + 0.1 }.first
            ?? markers.first
        if let m = next {
            seek(to: laneTime(m.position, side: activeTrack))
        }
    }

    /// ⇧, / ⇧. 两条腿一起跳到上/下一枚橙色标记（▼ 那种，`.global`；
    /// M 标记的亮青 ▲ 不算）。认的是当前选中轨自己那串标记，落的是同一个全局时刻。
    /// 和 , / . 的分别是：那一双没找到会回绕，这一双没有就站着不动。
    func jumpToMarkerBothLanes(earlier: Bool) {
        let pos = fileTime(currentPosition, side: activeTrack)
        let orange = markers.filter { $0.kind == .global }
        let target = earlier ? orange.last(where: { $0.position < pos - 0.1 })
                             : orange.first(where: { $0.position > pos + 0.1 })
        guard let m = target else { return }
        // 跳到条上「那一枚标记画在哪儿」的位置：另一轨跟着到同一个刻度点。
        pointerSeek(activeTrack, to: laneTime(m.position, side: activeTrack), bothLanes: true)
    }

    // MARK: - Range Compare

    func toggleRangeCompare() {
        rangeCompareEnabled.toggle()
    }

    func toggleRangeSelection() {
        isSelectingRange.toggle()
        if !isSelectingRange {
            pendingRangeStart = nil
        }
    }

    func beginRangeSelection() {
        isSelectingRange = true
        pendingRangeStart = nil
    }

    /// 条上按下那一点（轨内时间）。区间存文件时间，所以落盘前在 `confirmRangeSelection`
    /// 里减掉这一轨的偏移；`side` 就是被点的那条轨，⇧ 与否都要它才知道该减哪个偏移。
    func setRangeStart(at time: TimeInterval, side: TrackSide, bothLanes: Bool = false) {
        pendingRangeStart = time
    }

    func updateRangeSelection(at time: TimeInterval, side: TrackSide, bothLanes: Bool = false) {
        // Called during drag to update end position
        // pendingRangeStart should already be set
    }

    func confirmRangeSelection(endTime: TimeInterval, side: TrackSide, bothLanes: Bool = false) {
        guard let start = pendingRangeStart else { return }
        let range = ABRange(start: fileTime(min(start, endTime), side: side),
                            end: fileTime(max(start, endTime), side: side))
        applyRange(range, bothLanes: bothLanes, side: side)
        isSelectingRange = false
        pendingRangeStart = nil
    }

    /// In 版本对比 both lanes share one range, but the two files can differ in
    /// length: the shorter lane's end is clipped to its own file end, so its
    /// loop closes at the曲尾 instead of never reaching the shared end point.
    /// ⇧ on the bar writes one range onto both lanes, which is what 版本对比 always
    /// does; without it a 参考曲 range only touches the lane being dragged.
    private func applyRange(_ range: ABRange, bothLanes: Bool = false, side explicitSide: TrackSide? = nil,
                            recordHistory: Bool = true) {
        if recordHistory { beginEdit() }
        if compareMode == .versionCompare || bothLanes {
            rangeA = clipped(range, to: .a)
            rangeB = clipped(range, to: .b)
        } else {
            switch explicitSide ?? activeTrack {
            case .a: rangeA = clipped(range, to: .a)
            case .b: rangeB = clipped(range, to: .b)
            }
        }
    }

    private func clipped(_ range: ABRange, to side: TrackSide) -> ABRange {
        let duration = side == .a ? engine.durationA : engine.durationB
        guard duration > 0 else { return range }
        let end = min(range.end, duration)
        // A range that starts past the end of this file would collapse; let the
        // whole file loop instead of parking the playhead at曲尾.
        let start = min(range.start, end)
        return ABRange(start: start < end ? start : 0, end: end)
    }

    func cancelRangeSelection() {
        isSelectingRange = false
        pendingRangeStart = nil
    }

    /// `[` — pin the loop range's start at the playhead.
    func setRangeStartAtPlayhead() { setRangeEdge(start: true) }

    /// `]` — pin the loop range's end at the playhead.
    func setRangeEndAtPlayhead() { setRangeEdge(start: false) }

    /// The untouched edge keeps its current value; with no range yet it defaults
    /// to the far end of the file, so a single key press always yields a
    /// playable span. Crossing the other edge swaps them.
    private func setRangeEdge(start: Bool) {
        let side = activeTrack
        let duration = side == .a ? engine.durationA : engine.durationB
        guard duration > 0 else { return }
        // 播放头是轨内时间，先按轨内跨度夹住，再回到文件时间记账。
        let t = min(max(fileTime(position(of: side), side: side), 0), duration)
        let existing = side == .a ? rangeA : rangeB
        var range = existing ?? (start ? ABRange(start: t, end: duration)
                                       : ABRange(start: 0, end: t))
        if existing != nil {
            if start { range.start = t } else { range.end = t }
        }
        if range.start > range.end { range = ABRange(start: range.end, end: range.start) }
        applyRange(range)
    }

    /// 拖条上的范围手柄：一端跟着指针走，另一端不动，超过另一端就交换。
    /// 一笔拖到底只记一次历史（第一下记），所以撤销一次就回到按下前的范围。
    private var edgeDragRecorded = false

    func dragRangeEdge(side: TrackSide, startEdge: Bool, to lane: TimeInterval) {
        let duration = side == .a ? engine.durationA : engine.durationB
        guard duration > 0 else { return }
        if !edgeDragRecorded { beginEdit(); edgeDragRecorded = true }
        let t = min(max(fileTime(lane, side: side), 0), duration)
        var range = (side == .a ? rangeA : rangeB) ?? ABRange(start: 0, end: duration)
        if startEdge { range.start = t } else { range.end = t }
        if range.start > range.end { range = ABRange(start: range.end, end: range.start) }
        applyRange(range, side: side, recordHistory: false)
    }

    func endRangeEdgeDrag() {
        edgeDragRecorded = false
    }
    
    func clearAllTracks() {
        beginEdit()
        tracks.removeAll()
        trackA = nil
        trackB = nil
        selectedTrackIndex = nil
        waveformPeaksA = .empty
        waveformPeaksB = .empty
        waveformHorizontalZoom = 1.0
        markers = []
        chapters = []
        AudioEngine.shared.stop()
        refreshPlayStateFlags()
        refreshClock()
    }

    func clearBackupTracks() {
        beginEdit()
        backupTracks.removeAll()
    }

    func setTrackAFromBackup(index: Int) {
        guard index < backupTracks.count else { return }
        clearEditHistory()
        guard ensureFilePresent(isMain: false, index: index) else { return }
        loadTrackAFromTrack(backupTracks[index])
    }

    func setTrackBFromBackup(index: Int) {
        guard index < backupTracks.count else { return }
        clearEditHistory()
        guard ensureFilePresent(isMain: false, index: index) else { return }
        loadTrackBFromTrack(backupTracks[index])
    }

    func moveToBackup(index: Int) {
        guard index < tracks.count else { return }
        beginEdit()
        let track = tracks.remove(at: index)
        backupTracks.append(track)
        if selectedTrackIndex == index { selectedTrackIndex = nil }
        else if let sel = selectedTrackIndex, sel > index { selectedTrackIndex = sel - 1 }
        mainMulti = []
    }

    func moveToMain(index: Int) {
        guard index < backupTracks.count else { return }
        beginEdit()
        let track = backupTracks.remove(at: index)
        tracks.append(track)
        backupMulti = []
        if let sel = backupSelectedIndex, sel >= backupTracks.count {
            backupSelectedIndex = backupTracks.isEmpty ? nil : backupTracks.count - 1
        }
    }

    // MARK: - Multi-selection & list transfer

    func mainSelectedIndices() -> [Int] {
        var set = mainMulti
        if let i = selectedTrackIndex { set.insert(i) }
        return set.filter { $0 < tracks.count }.sorted()
    }

    func backupSelectedIndices() -> [Int] {
        var set = backupMulti
        if let i = backupSelectedIndex { set.insert(i) }
        return set.filter { $0 < backupTracks.count }.sorted()
    }

    func selectTrackRow(index: Int, shift: Bool) {
        if shift, let anchor = selectedTrackIndex {
            mainMulti = Set(min(anchor, index)...max(anchor, index))
        } else {
            mainMulti = []
            selectedTrackIndex = index
        }
    }

    func selectBackupRow(index: Int, shift: Bool) {
        if shift, let anchor = backupSelectedIndex {
            backupMulti = Set(min(anchor, index)...max(anchor, index))
        } else {
            backupMulti = []
            backupSelectedIndex = index
        }
    }

    private func cloneTrack(_ t: Track) -> Track {
        var c = Track(url: t.url)
        c.displayName = t.displayName
        c.duration = t.duration
        c.channelInfo = t.channelInfo
        c.sampleRateInfo = t.sampleRateInfo
        c.bitrateInfo = t.bitrateInfo
        return c
    }

    /// T: move ALL selected main-list files to the backup list
    func moveSelectedToBackup() {
        guard !mainSelectedIndices().isEmpty else { return }
        beginEdit()
        let idxs = mainSelectedIndices().reversed()
        for i in idxs where i < tracks.count {
            let t = tracks.remove(at: i)
            backupTracks.append(t)
        }
        selectedTrackIndex = nil
        mainMulti = []
    }

    /// Cmd+T: copy (duplicate) selected main-list files into the backup list
    func copySelectedToBackup() {
        guard !mainSelectedIndices().isEmpty else { return }
        beginEdit()
        for i in mainSelectedIndices() where i < tracks.count {
            backupTracks.append(cloneTrack(tracks[i]))
        }
    }

    /// G: copy selected backup-list files into the main playlist
    func copySelectedBackupToMain() {
        guard !backupSelectedIndices().isEmpty else { return }
        beginEdit()
        for i in backupSelectedIndices() where i < backupTracks.count {
            tracks.append(cloneTrack(backupTracks[i]))
        }
    }

    /// Shift+G style move: cut selected backup-list files into the main playlist
    func moveSelectedBackupToMain() {
        guard !backupSelectedIndices().isEmpty else { return }
        beginEdit()
        for i in backupSelectedIndices().reversed() where i < backupTracks.count {
            tracks.append(backupTracks.remove(at: i))
        }
        backupSelectedIndex = nil
        backupMulti = []
    }

    // MARK: 列表调序（播放列表/备用列表按住 ⌘ 拖文件名）

    /// 一次拖拽算一步撤销：中途的视觉位移不进历史，落定这一下才 `beginEdit()`。
    /// 列表顺序就是数组顺序，可除了 A/B（认 id）之外，选中全是按序号记的
    /// （selectedTrackIndex / mainMulti / backupSelectedIndex / backupMulti），
    /// 所以挪完必须把这些指针一起搬到新序号上 —— 不搬的话「设为 A 轨道」会打到
    /// 别的行上，撤销时 clamp 也救不回来（那是越界才走的兜底）。
    func reorderTrack(from source: Int, to destination: Int, isMain: Bool) {
        let count = isMain ? tracks.count : backupTracks.count
        guard source != destination, source >= 0, destination >= 0, source < count, destination < count else { return }
        beginEdit()
        if isMain {
            let track = tracks.remove(at: source)
            tracks.insert(track, at: destination)
            if let i = selectedTrackIndex { selectedTrackIndex = Self.remappedIndex(i, from: source, to: destination) }
            mainMulti = Set(mainMulti.map { Self.remappedIndex($0, from: source, to: destination) })
        } else {
            let track = backupTracks.remove(at: source)
            backupTracks.insert(track, at: destination)
            if let i = backupSelectedIndex { backupSelectedIndex = Self.remappedIndex(i, from: source, to: destination) }
            backupMulti = Set(backupMulti.map { Self.remappedIndex($0, from: source, to: destination) })
        }
    }

    /// 换位之后这一行落在哪儿：被拖那一行自己搬到落点；夹在中间那一截各让一位；
    /// 其余不动。
    static func remappedIndex(_ index: Int, from source: Int, to destination: Int) -> Int {
        if index == source { return destination }
        if source < destination, index > source, index <= destination { return index - 1 }
        if source > destination, index >= destination, index < source { return index + 1 }
        return index
    }

    func removeSelected(isMain: Bool) {
        guard !(isMain ? mainSelectedIndices() : backupSelectedIndices()).isEmpty else { return }
        beginEdit()
        if isMain {
            for i in mainSelectedIndices().reversed() where i < tracks.count {
                tracks.remove(at: i)
            }
            selectedTrackIndex = nil
            mainMulti = []
        } else {
            for i in backupSelectedIndices().reversed() where i < backupTracks.count {
                backupTracks.remove(at: i)
            }
            backupSelectedIndex = nil
            backupMulti = []
        }
    }

    /// ← / → in backup list: assign the selected backup file to A / B track
    func setTrackAFromBackupSelected() {
        let idx = backupSelectedIndex ?? backupSelectedIndices().first
        if let i = idx { setTrackAFromBackup(index: i) }
    }

    func setTrackBFromBackupSelected() {
        let idx = backupSelectedIndex ?? backupSelectedIndices().first
        if let i = idx { setTrackBFromBackup(index: i) }
    }

    func selectPrevBackup() {
        guard !backupTracks.isEmpty else { return }
        backupMulti = []
        if let i = backupSelectedIndex {
            backupSelectedIndex = i > 0 ? i - 1 : backupTracks.count - 1
        } else {
            backupSelectedIndex = 0
        }
    }

    func selectNextBackup() {
        guard !backupTracks.isEmpty else { return }
        backupMulti = []
        if let i = backupSelectedIndex {
            backupSelectedIndex = i < backupTracks.count - 1 ? i + 1 : 0
        } else {
            backupSelectedIndex = 0
        }
    }

    // MARK: - Range clearing (取消选择 / Cmd+R)

    func clearAllRanges() {
        beginEdit()
        rangeA = nil
        rangeB = nil
        isSelectingRange = false
        pendingRangeStart = nil
    }

    // MARK: - Playlist Navigation

    func selectPrevTrack() {
        guard !tracks.isEmpty else { return }
        mainMulti = []
        if let idx = selectedTrackIndex {
            selectedTrackIndex = idx > 0 ? idx - 1 : tracks.count - 1
        } else {
            selectedTrackIndex = 0
        }
    }

    func selectNextTrack() {
        guard !tracks.isEmpty else { return }
        mainMulti = []
        if let idx = selectedTrackIndex {
            selectedTrackIndex = idx < tracks.count - 1 ? idx + 1 : 0
        } else {
            selectedTrackIndex = 0
        }
    }

    // MARK: - Chapters

    /// 读一份文件自带的章节。菜单和「章节转标记」共用这一份读法，所以把它从赋值里
    /// 拆出来：调用方自己决定要不要动 `chapters`。
    ///
    /// `chapterMetadataGroups(withTitleLocale:)` 认的是**精确** locale：章节标题写的是
    /// `und`（未定语言，ffmpeg 和不少压制工具都这么写）时，拿系统 locale 和 `en` 去问
    /// 都是 0 组 —— 实测本机 locale 是 zh-Hans_JP，两份 locale 各问一次，只有 `und`
    /// 交回 3 组。所以三级都问，问着为止。
    ///
    /// 系统这条路对 FLAC 整块失灵（一份带 4 格章节的 FLAC，ffprobe 数得出 4 格，
    /// AVFoundation 的 `asset.metadata` 是 0 条），所以问不着的时候再自己读一次
    /// 文件头 —— 见 `FlacChapters`。MP3 的 ID3v2 CHAP 系统读得到，不用自己动。
    static func readChapters(from url: URL) -> [Chapter] {
        let asset = AVURLAsset(url: url)
        let locales = [Locale.current, Locale(identifier: "en"), Locale(identifier: "und")]
        // 两轮：先只要「带标题的章节」，一轮都不中就放宽成「任何章节」。有些压制只给
        // 时间轴不给标题（空键这一档实测照样取得到那 7 格），那种时间点也该跳、也该转标记，
        // 不该因为没名字就被当成没有章节。
        for keys in [[AVMetadataKey.commonKeyTitle], [AVMetadataKey]()] {
            for locale in locales {
                let groups = asset.chapterMetadataGroups(withTitleLocale: locale,
                                                         containingItemsWithCommonKeys: keys)
                guard !groups.isEmpty else { continue }
                return groups.map { group in
                    let title = AVMetadataItem.metadataItems(from: group.items, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common)
                        .first?.stringValue ?? "Chapter"
                    return Chapter(title: title, startTime: CMTimeGetSeconds(group.timeRange.start))
                }.sorted { $0.startTime < $1.startTime }
            }
        }
        return FlacChapters.read(from: url)
    }

    // MARK: 信息面板的「编码」

    /// `AVAudioFile` 只交回解码后的 PCM，看不出容器里装的是 aac 还是 alac，所以「编码」
    /// 这一格另问一次 `AVURLAsset` 的格式描述。这是一份旁账：不进轨道、不进撤销快照、
    /// 也不写进工程文件 —— 面板打开才读，读到一次就记住。
    @Published private(set) var codecNames: [String: String] = [:]

    func ensureCodec(for url: URL?) async {
        guard let url, codecNames[url.path] == nil else { return }
        let name = await Task.detached(priority: .utility) { Self.readCodec(from: url) }.value
        guard !Task.isCancelled, codecNames[url.path] == nil else { return }
        // 和 videoFacts 同一趟后台，写 @Published 也要回主线程；少了这一跳，面板上这一格
        // 会一直停在「…」——值其实读到了，只是没在主线程上通知出去。
        await MainActor.run { self.codecNames[url.path] = name }
    }

    /// 一个文件里两条音轨（少见）就报第一条，和「声道」那一格同一把尺。
    static func readCodec(from url: URL) -> String {
        let asset = AVURLAsset(url: url)
        if let audio = asset.tracks(withMediaType: .audio).first,
           let desc = (audio.formatDescriptions as? [CMFormatDescription])?.first {
            return codecName(CMFormatDescriptionGetMediaSubType(desc))
        }
        // 系统连音轨都数不出来的那批容器（ogg / opus / wma / ape / wv / dsf）：编码名
        // 改问 ffmpeg，不然这一格永远是「—」，看着像没读出来。
        return AudioFormatCache.needsConversion(url) ? AudioFormatCache.codecName(of: url) ?? "—" : "—"
    }

    /// fourcc → 面板上那一格。认不出的把四个字母原样吐出去，总好过空着。
    /// 容器里的编码名两头都见过：`aac `（末尾一个空格）和 `.mp3`（开头一个点），
    /// 所以先拿掉这两头的填充再认。
    static func codecName(_ subType: OSType) -> String {
        let raw = PluginCatalog.string(subType)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            .lowercased()
        switch raw {
        case "aac", "aace", "aach", "aacl": return "aac"
        case "mp1", "mp2", "mp3": return raw
        case "ac-3": return "ac-3"
        case "ec-3": return "ec-3"
        case "alac": return "alac"
        case "opus": return "opus"
        case "flac": return "flac"
        case "lpcm", "twos", "sowt", "in24", "i24f", "fl32", "f32", "i839", "raw": return "pcm"
        default: return raw.isEmpty ? "—" : raw
        }
    }

    // MARK: 信息面板的「视频」

    /// 视频那一列的五格 + 视频窗口要的帧率/宽高。和「编码」同一类旁账：读一次记住，
    /// 不进轨道、不进快照、不进工程文件。`AVURLAsset` 数轨是同步阻塞的，丢到后台去。
    @Published private(set) var videoFacts: [String: VideoFacts] = [:]

    /// 钉在 `@MainActor`：两头查的那一下 `videoFacts[...]` 也是读 @Published，
    /// 不加隔离的 `async` 方法会在并发执行器上读它（和视频面板那一次段错误同类）。
    /// 真正阻塞的 `VideoProbe.read` 自己丢 detached 出去了，主线程只等不干活。
    @MainActor
    func ensureVideoFacts(for url: URL?) async {
        guard let url, videoFacts[url.path] == nil else { return }
        let facts = await Task.detached(priority: .utility) { VideoProbe.read(from: url) }.value
        guard !Task.isCancelled, videoFacts[url.path] == nil else { return }
        videoFacts[url.path] = facts
    }

    // MARK: 章节转标记

    /// 一次要倒进来的标记到这个数就先问一句（默认按钮是「否」）。
    static let chapterPromptThreshold = 50

    /// 章节标记落在哪一轨：落在「这一份文件所在的那一轨」。
    /// 以前认的是状态指示那一轨，于是选中 B 时往 A 轨开的文件，它的章节一个都不进来、
    /// 也不说一声 —— 看着就是「标记没载入」。章节是这份文件自带的东西，就该画在这份
    /// 文件的条上；版本对比只画 A 轨那一条进度条，所以那一档仍旧只认 A。
    private func chapterLanding(for side: TrackSide) -> TrackSide? {
        if compareMode == .versionCompare && side != .a { return nil }
        return side
    }

    /// 开文件自动转：章节时间点变成这一轨的 M 标记（亮青 ▲，进度条下方）。
    private func importChapters(_ fileChapters: [Chapter], onto landing: TrackSide, fileLength: TimeInterval) {
        guard let track = landing == .a ? trackA : trackB, !fileChapters.isEmpty else { return }
        let existing = MarkerStore.shared.markers(for: track.url)
        var fresh: [TimeInterval] = []
        for time in fileChapters.map(\.startTime).sorted() {
            guard time.isFinite, time >= 0, fileLength <= 0 || time <= fileLength else { continue }
            // 已有标记（手点的、上一次转的）±0.01 秒内不再放第二枚：同一个文件反复开不翻倍。
            if existing.contains(where: { abs($0.position - time) < 0.01 }) { continue }
            if let last = fresh.last, time - last < 0.01 { continue }
            fresh.append(time)
        }
        guard !fresh.isEmpty else { return }
        let kind: MarkerKind = landing == .a ? .sideA : .sideB
        guard fresh.count >= Self.chapterPromptThreshold else {
            writeChapterMarkers(fresh, to: track.url, kind: kind)
            return
        }
        chapterImportPrompt = ChapterImportPrompt(url: track.url, kind: kind, positions: fresh)
        showChapterPrompt = true
    }

    private func writeChapterMarkers(_ positions: [TimeInterval], to url: URL, kind: MarkerKind) {
        beginEdit()
        var merged = MarkerStore.shared.markers(for: url)
        merged.append(contentsOf: positions.map { Marker(position: $0, kind: kind) })
        merged.sort { $0.position < $1.position }
        MarkerStore.shared.setMarkers(merged, for: url)
        refreshMarkers()
    }

    func confirmChapterImport() {
        defer { chapterImportPrompt = nil }
        guard let prompt = chapterImportPrompt else { return }
        writeChapterMarkers(prompt.positions, to: prompt.url, kind: prompt.kind)
    }

    /// 「否」和直接把弹窗关掉是一件事：这一份就不要了，下次开同一个文件还会再问。
    func cancelChapterImport() { chapterImportPrompt = nil }

    // MARK: - Mode

    func setCompareMode(_ mode: CompareMode) {
        flushTimeTrim()
        compareMode = mode
        if mode != .reference {
            // Leaving reference mode: re-sync both sides to the active position
            engine.pauseAll()
            engine.seekAll(to: currentPosition)
            refreshClock()
        }
        if mode == .abx {
            abxIsActive = true
            abxShowSetup = true
            abxShowResult = false
            // 盲听要的是「只听不看」，画面整块无效（裁定）；退出 ABX 不自动重开。
            VideoPanelController.shared.videoInvalidated()
        } else {
            abxIsActive = false
            abxShowSetup = false
            abxShowResult = false
        }
    }

    // MARK: - ABX

    func startABX() {
        let rounds = Int(abxSetupRoundText) ?? 0
        abxTotalRounds = rounds
        abxRounds = []
        abxCurrentRoundIndex = 0
        abxShowSetup = false
        abxShowConfirm = false
        abxShowResult = false
        abxIsActive = true
        startNewABXRound()
    }

    private func startNewABXRound() {
        let xIsA = Bool.random()
        let roundNum = abxRounds.count + 1
        abxRounds.append(ABXRound(roundNumber: roundNum, xIsA: xIsA, userAnswer: nil))
        abxCurrentRoundIndex = abxRounds.count - 1
        abxLastChoice = nil

        if xIsA {
            engine.setActiveTrack(.a)
        } else {
            engine.setActiveTrack(.b)
        }
        activeTrack = engine.activeTrack
    }

    var abxCurrentRound: ABXRound? {
        abxRounds.indices.contains(abxCurrentRoundIndex) ? abxRounds[abxCurrentRoundIndex] : nil
    }

    /// Route audio to one side, and make sure it is actually audible:
    /// if the engine is running but this side's schedule already ended,
    /// restart it from the other side's live position.
    private func abxRoute(to side: TrackSide) {
        engine.setActiveTrack(side)
        activeTrack = engine.activeTrack
        loadMarkers(for: currentTrack?.url)
        if engine.isPlaying && !engine.isPlaying(side) {
            let other: TrackSide = side == .a ? .b : .a
            engine.playSide(side, from: engine.position(of: other))
        }
    }

    func abxSelectA() { abxRoute(to: .a); abxLastChoice = "A" }

    func abxSelectB() { abxRoute(to: .b); abxLastChoice = "B" }

    func abxSelectX() {
        guard let round = abxCurrentRound else { return }
        abxRoute(to: round.xIsA ? .a : .b)
        abxLastChoice = "X"
    }

    func abxAnswer(_ isA: Bool) {
        guard abxRounds.indices.contains(abxCurrentRoundIndex) else { return }
        abxRounds[abxCurrentRoundIndex].userAnswer = isA
    }

    func abxContinue() {
        if abxTotalRounds > 0 && abxRounds.count >= abxTotalRounds {
            abxShowResult = true
            return
        }
        startNewABXRound()
    }

    func abxEnd() {
        abxShowResult = true
    }

    func abxCloseResult() {
        abxIsActive = false
        abxShowResult = false
        abxShowSetup = false
        abxShowConfirm = false
        abxRounds = []
        abxCurrentRoundIndex = 0
        abxTotalRounds = 0
        compareMode = .versionCompare
    }

    var abxCorrectCount: Int {
        abxRounds.filter { $0.isCorrect == true }.count
    }

    // MARK: - Export

    func exportCurrentTrack() {
        guard let lane = currentTrimLane() else { return }
        let panel = NSSavePanel()
        // 这一条本来就忽略手打的名字（写出去的是 clipFileName 那串），
        // 所以名字栏摆在哪儿都只是预览。AppKit 没有「名字栏不可编辑」这一档 API，
        // 打进去的字也一样进不了盘 —— 真正落笔认的是 outputDirectory + clipFileName。
        panel.nameFieldStringValue = FFmpegService.clipFileName(inputURL: lane.url,
                                                                startTime: lane.start,
                                                                endTime: lane.end)
        panel.canCreateDirectories = true
        // 输出目录选过一次就一直沿用。
        panel.directoryURL = SettingsStore.shared.exportDirectory
        guard panel.runModal() == .OK, let outputDir = panel.directoryURL else { return }
        SettingsStore.shared.exportDirectory = outputDir
        trim([lane], to: outputDir)
    }

    func exportAllTracks() {
        let lanes = allTrimLanes()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SettingsStore.shared.exportDirectory
        guard panel.runModal() == .OK, let outputDir = panel.url else { return }
        SettingsStore.shared.exportDirectory = outputDir
        trim(lanes, to: outputDir)
    }

    private func currentTrimLane() -> ExportLane? {
        guard let track = currentTrack, let url = track.url as URL? else { return nil }
        let range = activeTrack == .a ? rangeA : rangeB
        return ExportLane(side: activeTrack, url: url,
                          start: range?.start ?? 0, end: range?.end ?? duration)
    }

    private func allTrimLanes() -> [ExportLane] {
        var lanes: [ExportLane] = []
        if let trackA = trackA, let rangeA = rangeA {
            lanes.append(ExportLane(side: .a, url: trackA.url, start: rangeA.start, end: rangeA.end))
        }
        if let trackB = trackB, let rangeB = rangeB {
            lanes.append(ExportLane(side: .b, url: trackB.url, start: rangeB.start, end: rangeB.end))
        }
        return lanes
    }

    /// 一条轨道裁完之后要报的账。
    struct TrimResult {
        var title: String
        /// 这一份是「AVFoundation 用不了、改由 ffmpeg 裁的」；开关关着直接走 ffmpeg 不算。
        var fallback: Bool
        var error: Error?
    }

    /// 逐条串行裁切，跑完按口径报一次。返回给调用方的 Bool = 是不是全成了
    /// （对话框拿它决定留不留着；菜单那两条不管）。
    private func trim(_ lanes: [ExportLane], to directory: URL,
                      completion: ((Bool) -> Void)? = nil) {
        guard !lanes.isEmpty else { completion?(true); return }
        var results: [TrimResult] = []
        var index = 0
        func next() {
            guard index < lanes.count else {
                // 先算再传：`completion?(reportTrim(...))` 在 completion 为 nil 时连参数
                // 都不求值 —— 菜单那两条不带回调，提示就会被这一句吞掉（实测抓到）。
                let allSucceeded = reportTrim(results)
                completion?(allSucceeded)
                return
            }
            let lane = lanes[index]
            index += 1
            FFmpegService.exportClip(inputURL: lane.url, startTime: lane.start,
                                     endTime: lane.end, outputDirectory: directory) { result, fallback in
                var error: Error?
                if case .failure(let failure) = result { error = failure }
                results.append(TrimResult(title: self.trimTitle(lane), fallback: fallback, error: error))
                next()
            }
        }
        next()
    }

    private func trimTitle(_ lane: ExportLane) -> String {
        "\(lane.side == .a ? "A" : "B") 轨 \(lane.url.lastPathComponent)"
    }

    /// 裁定的口径：完全成功只有提示音、不弹窗；AV 用不了但 ffmpeg 裁成了，
    /// 弹「✅已使用ffmpeg导出（AV不可用）」；只要有一条没成，就在一个窗口里逐轨写成败
    /// （成了的那几条也一并点名）。弹窗用平时那一只。
    private func reportTrim(_ results: [TrimResult]) -> Bool {
        let failed = results.contains { $0.error != nil }
#if DEBUG
        // 验收用的一行账：三种反馈各是一档，拍照前得先确认口径分支真的走到了。
        let line = "TRIMFB: 条数=\(results.count) 有败=\(failed) 回落=\(results.filter { $0.fallback }.count)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
#endif
        if failed {
            let text = results.map { result -> String in
                guard let error = result.error else {
                    return "✅\(result.title)：已导出" + (result.fallback ? "（AV不可用，已使用ffmpeg）" : "")
                }
                return "❌\(result.title)：\(error.localizedDescription)"
            }.joined(separator: "\n")
            ProjectStore.notify(text)
        } else if results.contains(where: { $0.fallback }) {
            ProjectStore.notify("✅已使用ffmpeg导出（AV不可用）")
        }
        return !failed
    }

#if DEBUG
    /// 探针（验收）：菜单那两条第一步是弹面板选目录，这台机器注入不了鼠标，所以从
    /// 「选完目录」那一步起跑 —— 走的还是同一条 `trim`，连反馈口径一起验。
    func checkTrimMenuFeedback(currentOnly: Bool, to directory: URL) {
        trim(currentOnly ? [currentTrimLane()].compactMap { $0 } : allTrimLanes(), to: directory)
    }
#endif

    // MARK: 导出对话框

    /// 「导出…」（⌘E）和两条「渲染后导出…」开的是同一张对话框，区别只在预选项。
    struct ExportRequest: Identifiable {
        let id = UUID()
        var scope: ExportScope
        var mode: ExportMode
    }

    @Published var exportRequest: ExportRequest?

    /// 一条轨道要导出的东西：文件本身，和那一段 —— 没选范围就是整首
    /// （「如果没有选择就是全部」）。
    struct ExportLane {
        var side: TrackSide
        var url: URL
        var start: TimeInterval
        var end: TimeInterval
    }

    func exportLanes(for scope: ExportScope) -> [ExportLane] {
        func lane(_ side: TrackSide) -> ExportLane? {
            guard let track = side == .a ? trackA : trackB, !track.missing else { return nil }
            let range = side == .a ? rangeA : rangeB
            let fileLength = side == .a ? engine.durationA : engine.durationB
            let end = range?.end ?? max(fileLength, track.duration)
            let start = min(range?.start ?? 0, end)
            guard end > start else { return nil }
            return ExportLane(side: side, url: track.url, start: start, end: end)
        }
        let sides: [TrackSide] = scope == .current ? [activeTrack] : [.a, .b]
        return sides.compactMap(lane)
    }

    func openExportDialog(scope: ExportScope, mode: ExportMode) {
        guard !exportLanes(for: scope).isEmpty else { return }
        exportRequest = ExportRequest(scope: scope, mode: mode)
    }

    /// 渲染任务：通道条和插件链在这一刻定格，输出名从对话框里那一个基础名派生。
    /// 只在编辑模式里算通道条 —— 1.x 那条链路绕过 pre-gain 和插件，导出要是照
    /// 它们衰减，用户拿到的文件就比自己听见的低了 6 dB。
    func renderRequests(for scope: ExportScope, typedName: String,
                        bitDepth: ExportBitDepth,
                        directory: URL) -> [RenderExportService.Request] {
        let lanes = exportLanes(for: scope)
        var requests: [RenderExportService.Request] = lanes.map { lane in
            RenderExportService.Request(
                sourceURL: lane.url,
                start: lane.start,
                end: lane.end,
                preGainDB: editMode ? (lane.side == .a ? preGainA : preGainB) : 0,
                faderDB: editMode ? (lane.side == .a ? laneFaderA : laneFaderB) : 0,
                panTicks: editMode ? (lane.side == .a ? panA : panB) : 0,
                slots: editMode ? engine.slotSnapshots(lane.side) : [],
                laneBypass: editMode && engine.isLaneBypassed(lane.side),
                bitDepth: bitDepth,
                outputURL: RenderExportService.outputURL(typedName: typedName,
                                                         sourceURL: lane.url,
                                                         bitDepth: bitDepth,
                                                         directory: directory))
        }
        // 同一个文件放在 A 和 B 时两条默认名会撞车，给各自挂上轨道字母。
        let paths = Set(requests.map { $0.outputURL.path })
        if requests.count > 1, paths.count < requests.count {
            for index in requests.indices {
                requests[index].outputURL = RenderExportService.outputURL(
                    typedName: typedName,
                    sourceURL: requests[index].sourceURL,
                    bitDepth: bitDepth,
                    directory: directory,
                    laneTag: lanes[index].side == .a ? "A" : "B")
            }
        }
        return requests
    }

    /// 「裁切，旁通所有插件」：还是那两路引擎（AVFoundation 优先、回落 ffmpeg -c copy），
    /// 所以插件一律不算，文件名也由它自己的区间戳决定（对话框里输的那个名字不用）。
    /// 成败的报法走 `reportTrim`，对话框只在没全成的时候留着。
    func runTrimExport(for scope: ExportScope, directory: URL,
                       completion: @escaping (Bool) -> Void) {
        trim(exportLanes(for: scope), to: directory, completion: completion)
    }

    // MARK: - 响度检测

    @Published private(set) var isDetectingLoudness = false

    /// 「文件」→「检测响度」, on the A and B tracks and always the whole file: the
    /// automation it comes from had no range to work with. Both lanes are measured
    /// by their own ffmpeg process, and one dialog is shown once both are back,
    /// listing A before B.
    func detectLoudness() {
        guard !isDetectingLoudness else { return }
        var urls: [URL] = []
        if let a = trackA { urls.append(a.url) }
        if let b = trackB { urls.append(b.url) }
        guard !urls.isEmpty else { return }

        isDetectingLoudness = true
        let reportURL = LoudnessService.reportURL(forFirstFile: urls[0])
        LoudnessService.analyze(urls: urls) { [weak self] result in
            guard let self = self else { return }
            self.isDetectingLoudness = false
            switch result {
            case .failure(let error): LoudnessService.show(error: error)
            case .success(let readings): LoudnessService.show(readings: readings, reportURL: reportURL)
            }
        }
    }

    // MARK: - Display Timer

    private func startDisplayTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.engine.isPlaying(.a) { self.engine.tickSide(.a) }
                if self.engine.isPlaying(.b) { self.engine.tickSide(.b) }
                self.refreshClock()
                let pa = self.engine.isPlaying(.a)
                let pb = self.engine.isPlaying(.b)
                if self.sidePlayingA != pa { self.sidePlayingA = pa }
                if self.sidePlayingB != pb { self.sidePlayingB = pb }
                if self.isPlaying != self.engine.isPlaying {
                    self.isPlaying = self.engine.isPlaying
                }
                if self.engine.isPlaying {
                    self.handleRangeLoop()
                }
            }
        }
    }

    private func handleRangeLoop() {
        guard rangeCompareEnabled else { return }
        let side = activeTrack
        guard let r = side == .a ? rangeA : rangeB else { return }
        // 区间记的是文件时间，播放头读的是轨内时间：比之前先换一次口径。
        let pos = fileTime(position(of: side), side: side)
        if pos >= r.end || pos < r.start - 0.02 {
            seekSide(side, to: laneTime(r.start, side: side))
        }
    }

    private func handleSideEnd() {
        refreshClock()
        refreshPlayStateFlags()
    }

    // MARK: - Settings

    func clearAllMarkers() {
        beginEdit()
        MarkerStore.shared.clearAll()
        refreshMarkers()
    }
}
