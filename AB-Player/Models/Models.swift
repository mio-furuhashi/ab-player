import Foundation
import AVFoundation
import AppKit
import Combine
import SwiftUI

// MARK: - Theme Colors (sRGB)

extension NSColor {
    static let abGreen = NSColor(srgbRed: 0x30/255.0, green: 0x94/255.0, blue: 0x3A/255.0, alpha: 1)
    static let abOrange = NSColor(srgbRed: 0xD1/255.0, green: 0x81/255.0, blue: 0x2C/255.0, alpha: 1)
    static let abCyan = NSColor(srgbRed: 0x40/255.0, green: 0xE8/255.0, blue: 0xFF/255.0, alpha: 1)
    /// 编辑模式的标识色：播放/暂停按钮那一圈描边，时钟进模式也借这一圈
    /// （改亮，原 #AF52DE）。「跟随」启用色已经分出去单立 barFollowOn。
    static let abModePurple = NSColor(srgbRed: 0.807, green: 0.592, blue: 1.000, alpha: 1.000)
    /// 混音器里声像与已加载插件槽的底色。
    static let abMixBlue = NSColor(srgbRed: 0x26/255.0, green: 0x6E/255.0, blue: 0xB8/255.0, alpha: 1)

    // MARK: 走带配色（量表取自 UI 测试台的 ProgressBarLab）
    // 名字跟着那张表，改一处两轨的条、波形、时钟就都跟着变。
    // systemYellow / systemOrange / systemBlue 在这台机器上量出来正好就是 #FFD60A、
    // #FF9F0A、#0A84FF，所以这三项是把现用的系统色写成了固定的数。
    static let barBackdrop = NSColor(srgbRed: 0.150, green: 0.150, blue: 0.150, alpha: 1.000)
    static let barWaveform = NSColor(srgbRed: 0.120, green: 0.120, blue: 0.120, alpha: 1.000)
    /// 两轨波形的着色（WaveLab 调定，感知亮度对齐；把 B 提亮到和 A 同 L*=54.1，
    /// 原来那支 #1C62D1 只有 43.7，看着就是暗一截）。A 这支换成 255 制正好就是 .abGreen，
    /// 所以真动起来的只有 B。进度条的填充是 barFill / barFillB，不跟着变。
    static let abWaveA = NSColor(srgbRed: 0.188, green: 0.580, blue: 0.227, alpha: 1.000)
    static let abWaveB = NSColor(srgbRed: 0.160, green: 0.509, blue: 0.900, alpha: 1.000)
    static let barTrack = NSColor(srgbRed: 0.180, green: 0.180, blue: 0.180, alpha: 1.000)
    static let barFill = NSColor(srgbRed: 0.188, green: 0.580, blue: 0.227, alpha: 1.000)
    static let barRangefill = NSColor(srgbRed: 0.820, green: 0.506, blue: 0.173, alpha: 0.704)
    static let barRangestroke = NSColor(srgbRed: 0.820, green: 0.506, blue: 0.173, alpha: 1.000)
    static let barSelection = NSColor(srgbRed: 0.769, green: 0.898, blue: 1.000, alpha: 0.500)
    static let barArmed = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.000, alpha: 0.900)
    static let barPlayhead = NSColor(srgbRed: 1.000, green: 0.839, blue: 0.039, alpha: 1.000)
    static let barMarkerglobal = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.039, alpha: 1.000)
    static let barMarkerside = NSColor(srgbRed: 0.251, green: 0.910, blue: 1.000, alpha: 1.000)
    static let barHandle = NSColor(srgbRed: 0.962, green: 0.680, blue: 0.268, alpha: 1.000)

    // MARK: 走带栏其余角色（UI测试工具4/TransportLab 的量表）
    // 表里和已有常量重名的：abModePurple 按 A 的新值改了（上面注释了为什么改得起）；
    // abOrange 不改 —— 它同时是混音器 Bypass、单格 ⏻ 和电平表渐变第三档在用，那三处
    // 未要求改动。所以「范围播放」和「跟随·启用」各另立一支（两支现值不同：
    // 范围播放改深橙，跟随仍是 #F5AD44）。
    static let barButtonBase = NSColor(srgbRed: 0.250, green: 0.250, blue: 0.250, alpha: 1.000)
    static let barIcon = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 0.847)
    static let barButtonStroke = NSColor(srgbRed: 0.000, green: 0.000, blue: 0.000, alpha: 0.000)
    /// 播放/暂停按钮的底色三态：停 = barButtonBase；模式内播放 = 深紫；模式外播放 = 绿
    /// （新增，模式外这一档只上底色、不描边）。
    static let barPlayBgEdit = NSColor(srgbRed: 0.447, green: 0.247, blue: 0.612, alpha: 1.000)
    static let barPlayBgNormal = NSColor(srgbRed: 0.000, green: 0.624, blue: 0.000, alpha: 1.000)
    static let barChipA = NSColor(srgbRed: 0.000, green: 0.724, blue: 0.363, alpha: 1.000)
    static let barChipB = NSColor(srgbRed: 0.000, green: 0.655, blue: 0.995, alpha: 1.000)
    static let barChipText = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.000)
    static let barClockBg = NSColor(srgbRed: 0.150, green: 0.150, blue: 0.150, alpha: 1.000)
    static let barClockText = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.000)
    /// 「选择」按下与「范围播放」开启（一起改深橙 #C27800）。范围播放这一枚走的是
    /// 自己的 barRangePlayOn，不是 abOrange —— 后者还管着混音器 Bypass、单格 ⏻ 和电平表
    /// 渐变第三档，那三处未要求改动。
    static let barRangeOn = NSColor(srgbRed: 0.761, green: 0.469, blue: 0.000, alpha: 1.000)
    static let barDeselectFlash = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.000, alpha: 1.000)
    static let barRangePlayOn = NSColor(srgbRed: 0.761, green: 0.469, blue: 0.000, alpha: 1.000)
    /// 跟随·启用（改橙，不再跟描边共用 abModePurple）。
    static let barFollowOn = NSColor(srgbRed: 0.962, green: 0.680, blue: 0.268, alpha: 1.000)
    static let barFollowOff = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 0.549)
    static let barSplitIcon = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 0.549)
    static let barDivider = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 0.098)
    static let barFaderGroove = NSColor(srgbRed: 0.300, green: 0.300, blue: 0.300, alpha: 1.000)
    static let barFaderFill = NSColor(srgbRed: 0.620, green: 0.620, blue: 0.620, alpha: 1.000)
    static let barFaderHandle = NSColor(srgbRed: 0.860, green: 0.860, blue: 0.860, alpha: 1.000)
    static let barFaderKnurl = NSColor(srgbRed: 0.420, green: 0.420, blue: 0.420, alpha: 1.000)
    static let barReadoutText = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.000)
    /// B 轨进度条的已播放填充（A 轨继续用上面那支 barFill 的绿）。
    static let barFillB = NSColor(srgbRed: 0x0A/255.0, green: 0x80/255.0, blue: 0xC4/255.0, alpha: 1)
    /// ABX 盲听时进度条的已播放填充：那一条画的是当前路由到的那一轨，
    /// 照旧绿／蓝分轨就等于把 X 是 A 还是 B 直接写在脸上，所以两轨共用这一支粉。
    static let abxPlayed = NSColor(srgbRed: 0xD8/255.0, green: 0x6C/255.0, blue: 0x8F/255.0, alpha: 1)

    // MARK: 时间偏移弹框
    /// 三格之间的分隔点。原来跟着 abCyan，改白 —— abCyan 别处还在用（走带栏、
    /// 信息面板那些），所以这里另立一支，只给这一扇窗。
    static let trimDot = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.000)
    /// 「(+N 个样本)」那一截：换算出来的次级读数，比左边的秒数退一层。
    static let trimSample = NSColor(srgbRed: 0.760, green: 0.760, blue: 0.760, alpha: 1.000)
}

extension Color {
    static let abGreen = Color(NSColor.abGreen)
    static let abOrange = Color(NSColor.abOrange)
    static let abCyan = Color(NSColor.abCyan)
    static let abModePurple = Color(NSColor.abModePurple)
    static let abMixBlue = Color(NSColor.abMixBlue)
    static let barBackdrop = Color(NSColor.barBackdrop)
    static let barButtonBase = Color(NSColor.barButtonBase)
    static let barIcon = Color(NSColor.barIcon)
    static let barPlayBgEdit = Color(NSColor.barPlayBgEdit)
    static let barPlayBgNormal = Color(NSColor.barPlayBgNormal)
    static let barChipA = Color(NSColor.barChipA)
    static let barChipB = Color(NSColor.barChipB)
    static let barChipText = Color(NSColor.barChipText)
    static let barClockBg = Color(NSColor.barClockBg)
    static let barClockText = Color(NSColor.barClockText)
    static let barRangeOn = Color(NSColor.barRangeOn)
    static let barDeselectFlash = Color(NSColor.barDeselectFlash)
    static let barRangePlayOn = Color(NSColor.barRangePlayOn)
    static let barFollowOn = Color(NSColor.barFollowOn)
    static let barFollowOff = Color(NSColor.barFollowOff)
    static let barSplitIcon = Color(NSColor.barSplitIcon)
    static let barDivider = Color(NSColor.barDivider)
    static let barReadoutText = Color(NSColor.barReadoutText)
}

// MARK: - Track

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var displayName: String
    var duration: TimeInterval
    var channelInfo: String
    var sampleRateInfo: String
    var bitrateInfo: String
    /// 面板上「容器」那一格：带点的扩展名（`.m4a`）。
    /// 算出来的、不存进轨道：容器本来就是文件名那一段，存了反倒让旧工程文件读不进来。
    var containerInfo: String { "." + url.pathExtension.lowercased() }
    /// Set when the file is assigned to A/B but no longer exists on disk;
    /// the row renders greyed out. Never persisted as true.
    var missing: Bool = false

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.displayName = url.lastPathComponent
        self.duration = 0
        self.channelInfo = ""
        self.sampleRateInfo = ""
        self.bitrateInfo = ""
    }

    mutating func updateMetadata(duration: TimeInterval, channels: Int, sampleRate: Double, bitrate: Int) {
        self.duration = duration
        self.channelInfo = channels == 1 ? "mono" : "stereo"
        self.sampleRateInfo = String(format: "%.1f kHz", sampleRate / 1000.0)
        self.bitrateInfo = "\(bitrate) kbps"
    }
}

// MARK: - Marker

enum MarkerKind: String, Codable {
    case global   // backtick: shown above the bar on both tracks
    case sideA    // M on track A: shown below the A bar
    case sideB    // M on track B: shown below the B bar
}

struct Marker: Identifiable, Codable, Equatable {
    let id: UUID
    var position: TimeInterval
    var kind: MarkerKind

    init(position: TimeInterval, kind: MarkerKind = .global) {
        self.id = UUID()
        self.position = position
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, position, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        position = try c.decode(TimeInterval.self, forKey: .position)
        kind = (try? c.decode(MarkerKind.self, forKey: .kind)) ?? .global
    }
}

// MARK: - ABRange

struct ABRange: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }
}

// MARK: - Chapter

struct Chapter: Identifiable {
    let id = UUID()
    let title: String
    let startTime: TimeInterval
}

/// 一次「章节 → 标记」的待确认写入（新增功能）。章节多到 50 个以上时
/// 不直接倒进轨道，先把这一份挂起来问一句；否、或者把弹窗关掉都等于丢弃。
struct ChapterImportPrompt {
    let url: URL
    let kind: MarkerKind
    let positions: [TimeInterval]
    /// 文件名只用来写标题，真正落笔认的是 url。
    var fileName: String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - ABXRound

struct ABXRound: Identifiable {
    let id = UUID()
    let roundNumber: Int
    let xIsA: Bool
    var userAnswer: Bool?

    var isCorrect: Bool? {
        guard let answer = userAnswer else { return nil }
        return answer == xIsA
    }
}

// MARK: - CompareMode

/// 显示名就是这一层的名字（版本对比 → 单轨视图、参考曲 → 双轨视图）。
/// 分支只认 case，不认字符串；旧工程文件里写的旧名字不做映射，已经裁决过「当新的
/// 东西看待」。case 名留着，是为了满屏的 `.versionCompare`／`.reference` 不用跟着改。
enum CompareMode: String, CaseIterable, Codable {
    case versionCompare = "单轨视图"
    case reference = "双轨视图"
    case abx = "ABX"
}

// MARK: - TrackSide

enum TrackSide: String {
    case a = "A"
    case b = "B"
}

// MARK: 鼠标 / 触控板

/// 当前这一次滚动来自哪种指针。不做开关、也不查设备表：每枚事件自带身份 ——
/// 触控板给的是连续像素位移（`hasPreciseScrollingDeltas`），鼠标滚轮给的是一格一格的
/// line 位移。所以同一台机器上插着鼠标又用触控板，也各按各的规矩走。
enum PointerInput {
    case mouse, trackpad

    static func detect(_ event: NSEvent) -> PointerInput {
        event.hasPreciseScrollingDeltas ? .trackpad : .mouse
    }

    /// 竖向滚动量，统一成「往上为正」（推子的老规矩：往上 = 增益加）。
    /// 触控板的位移是跟着手指走的（两指往上给的是负值），这一路把符号翻回来；
    /// 滚轮往上滚本来就是正，原样交回。
    static func up(_ event: NSEvent) -> CGFloat {
        detect(event) == .trackpad ? -event.scrollingDeltaY : event.scrollingDeltaY
    }
}

// MARK: - ShortcutAction

enum ShortcutAction: String, CaseIterable, Codable {
    case setTrackA = "设为A轨道"
    case setTrackB = "设为B轨道"
    case switchTrack = "切换播放轨道"
    case playPause = "播放/暂停"
    case rangeCompare = "范围对比开关"
    case prevMarker = "上一标记"
    case nextMarker = "下一标记"
    /// ⇧, / ⇧. 两条腿一起跳到上/下一枚橙色标记。
    case prevMarkerBothLanes = "上一标记（两轨）"
    case nextMarkerBothLanes = "下一标记（两轨）"
    case prevTrack = "上一轨道"
    case nextTrack = "下一轨道"
    case abxSwitchA = "ABX切换A"
    case abxSwitchB = "ABX切换B"
    case abxSwitchX = "ABX切换X"
    case deleteMarker = "删除当前标记"
    case clearMarkers = "清空所有标记"
    case markSide = "M标记(仅当前轨道)"
    case rewind = "后退3秒"
    case forward = "前进3秒"
    case rewindFine = "微调后退0.1秒"
    case forwardFine = "微调前进0.1秒"
    case skipBack = "后退10秒"
    case skipForward = "前进10秒"
    case syncPlayPause = "同步播放/暂停"
    case stopAll = "停止播放（两轨）"
    case stopCurrentLane = "停止当前轨道"
    case rewindToStart = "回到开头"
    case removeTrack = "移除选中文件"
    case moveToBackupList = "移至备用列表"
    case copyToBackupList = "复制到备用列表"
    case copyToMainList = "复制到播放列表"
    case prevBackup = "备用列表上一项"
    case nextBackup = "备用列表下一项"
    case rangeSelectMode = "范围选择模式"
    case clearRanges = "清除范围选择"
    case abxConfirmContinue = "ABX确认答案并继续"
    case setAFromBackup = "备用列表选中设为A轨道"
    case setBFromBackup = "备用列表选中设为B轨道"
    case toggleInfo = "信息窗口开关"
    case togglePlaylist = "播放列表开关"
    case toggleFollowPlayhead = "画面跟随播放头开关"
    case toggleSplitStereo = "分声道显示开关"
    case setRangeStartHere = "以播放头设范围起点"
    case setRangeEndHere = "以播放头设范围终点"
    case enterTimecode = "输入时间码跳转"
    /// 1.x 的裸键 / 本来就是这一条（只跳当前选中轨）；⌘/ 那一条管两轨一起跳。
    case enterTimecodeCurrent = "输入时间码跳转（当前轨）"
    case rewindAllToStart = "双轨回到开头"
    case undoEdit = "撤销"
    case redoEdit = "重做"
    case toggleEditMode = "编辑模式（插件）"
    /// 混音器窗口。以前和 ABX 的 X 共用一把裸键，靠 allCases 顺序决定归谁；
    /// 现在自己占 ⌘5，那套顺序上的讲究就没有了。
    case toggleMixer = "混音器窗口"
    /// 视频窗口。和混音器同一类独立面板，但反过来：
    /// 编辑模式与 ABX 期间整块无效，所以排在 ⌘4/⌘5 之后占 ⌘6。
    case toggleVideo = "视频窗口"

    /// Empty means deliberately unbound — the user assigns it in 快捷键设置 if wanted.
    var defaultKey: String {
        switch self {
        case .setTrackA: return "q"
        case .setTrackB: return "e"
        case .switchTrack: return "f"
        case .playPause: return " "
        case .rangeCompare: return "c"
        case .prevMarker: return ","
        case .nextMarker: return "."
        // ⇧, / ⇧.。这两把键在英文键盘上是 < >，和 , / . 同一档。
        case .prevMarkerBothLanes: return "\u{21E7},"
        case .nextMarkerBothLanes: return "\u{21E7}."
        case .prevTrack: return "w"
        case .nextTrack: return "s"
        case .abxSwitchA: return "a"
        case .abxSwitchB: return "d"
        case .abxSwitchX: return "x"
        case .deleteMarker: return "\u{8}" // backspace
        case .clearMarkers: return "\u{7f}" // delete
        case .markSide: return "m"
        case .rewind: return "j"
        case .forward: return "l"
        case .rewindFine: return "J" // shift + j
        case .forwardFine: return "L" // shift + l
        case .skipBack: return "\u{2318}j"
        case .skipForward: return "\u{2318}l"
        case .syncPlayPause: return "k"
        // H 停止两轨，⌃H 只停当前轨（模式2）。查表用的 signature 把
        // 基键统一转小写（signature 末尾 base.lowercased()），所以裸键写 "h"、
        // 和 q/k/i 同一档；带 ⌃ 的那条写全称 —— ⌃ 按在 h 上送来的是控制字符 \u{8}，
        // 和退格键撞同一个字节，靠 keyCode 才分得开（见 signature 里 keyCode != 51 那条）。
        case .stopAll: return "h"
        case .stopCurrentLane: return "\u{2303}H"
        case .rewindToStart: return ShortcutStore.returnKey
        // ⌃M, spelled out: the recorder used to hand back the raw \r that both
        // ⌃M and the Return key send, which made the two indistinguishable.
        case .removeTrack: return "\u{2303}M"
        case .moveToBackupList: return "t"
        case .copyToBackupList: return "t" // command + t
        case .copyToMainList: return "g"
        case .prevBackup: return "\u{F700}" // up arrow
        case .nextBackup: return "\u{F701}" // down arrow
        case .rangeSelectMode: return "r"
        case .clearRanges: return "r" // command + r
        case .abxConfirmContinue: return "z"
        case .setAFromBackup: return "\u{F702}" // left arrow
        case .setBFromBackup: return "\u{F703}" // right arrow
        case .toggleInfo: return "i"
        case .togglePlaylist: return "p"
        case .toggleFollowPlayhead: return "⌃⇧F"
        case .toggleSplitStereo: return "⇧S"
        case .setRangeStartHere: return "["
        case .setRangeEndHere: return "]"
        case .enterTimecode: return "⌘/" // command + slash, seeks both lanes
        // 1.x 的默认值，被 supersededDefaults 从 enterTimecode 那行让出来之后放回这里。
        case .enterTimecodeCurrent: return "/" // bare slash, seeks only the selected lane
        // ⇧↩: the same key code as ↩, so the glyph is prefixed rather than reused —
        // 参考曲's ↩ only resets both lanes once the current one is already at the top.
        case .rewindAllToStart: return "\u{21E7}\u{21A9}"
        // The full signature is the binding: unlike ⌘T these must never answer to
        // a bare letter, and z on its own still belongs to ABX.
        case .undoEdit: return "⌘Z"
        case .redoEdit: return "⌘⇧Z"
        case .toggleEditMode: return "\u{2318}4" // sits beside the ⌘1/2/3 mode items
        case .toggleMixer: return "\u{2318}5"    // 接着排，和菜单里 ⌘1/2/3 一样的写法
        case .toggleVideo: return "\u{2318}6"    // 再往后一格；视频窗口在模式菜单底部
        }
    }
}

// MARK: - Shortcut settings sections

struct ShortcutSection {
    let title: String
    let actions: [ShortcutAction]
}

extension ShortcutAction {
    /// How 快捷键设置 lays the table out: 先按模式分组，再按功能区域。Display only —
    /// the bindings, their order in the table on disk and the dispatch path are all
    /// untouched. Every action has to appear exactly once; the selftest's shortcuts
    /// suite checks that, so a new row can't quietly go missing from the panel.
    static let settingsSections: [ShortcutSection] = [
        ShortcutSection(title: "走带 · 两种视图通用", actions: [
            .playPause, .stopAll, .rewind, .forward, .rewindFine, .forwardFine,
            .skipBack, .skipForward, .rewindToStart, .rewindAllToStart,
            .enterTimecodeCurrent, .enterTimecode,
        ]),
        ShortcutSection(title: "双轨视图", actions: [
            .syncPlayPause, .stopCurrentLane, .switchTrack,
        ]),
        ShortcutSection(title: "标记", actions: [
            .markSide, .prevMarker, .nextMarker,
            .prevMarkerBothLanes, .nextMarkerBothLanes, .deleteMarker, .clearMarkers,
        ]),
        ShortcutSection(title: "范围", actions: [
            .rangeCompare, .rangeSelectMode, .setRangeStartHere, .setRangeEndHere, .clearRanges,
        ]),
        ShortcutSection(title: "播放列表与备用列表", actions: [
            .togglePlaylist,
            .setTrackA, .setTrackB, .prevTrack, .nextTrack, .removeTrack,
            .moveToBackupList, .copyToBackupList, .copyToMainList,
            .prevBackup, .nextBackup, .setAFromBackup, .setBFromBackup,
        ]),
        ShortcutSection(title: "视图与信息", actions: [
            .toggleInfo, .toggleFollowPlayhead, .toggleSplitStereo, .toggleVideo,
        ]),
        ShortcutSection(title: "ABX · 盲听", actions: [
            .abxSwitchA, .abxSwitchB, .abxSwitchX, .abxConfirmContinue,
        ]),
        ShortcutSection(title: "编辑模式 · 插件", actions: [
            .toggleEditMode, .toggleMixer,
        ]),
        ShortcutSection(title: "编辑", actions: [
            .undoEdit, .redoEdit,
        ]),
    ]
}

// MARK: - ShortcutStore

class ShortcutStore {
    static let shared = ShortcutStore()
    private let key = "customShortcuts"

    /// Matched only inside the ⌘ branch, so their bare letter must never win the
    /// plain-key lookup (⌘T and T are two different actions that share "t").
    static let commandOnly: Set<ShortcutAction> = [.copyToBackupList, .clearRanges]

    /// The transport keys ⌃ narrows to the current lane in 参考曲. These and only
    /// these may also answer a press read without its ⌃, so a stray ⌃ can never
    /// steal a binding that has one of its own — ⌃M (移除选中文件) and the ⌘ combos
    /// stay on the first pass.
    static let controlNarrows: Set<ShortcutAction> = [
        .rewind, .forward, .rewindFine, .forwardFine,
        .skipBack, .skipForward, .syncPlayPause,
    ]

    /// Return and keypad Enter are recorded as this glyph: both send \r, which is
    /// also what ⌃M sends, so the key code is the only way to tell them apart.
    static let returnKey = "\u{21A9}"

    var bindings: [ShortcutAction: String]

    /// Bindings earlier builds shipped as defaults. The table below is written to
    /// disk in full, so anyone who never touched a row still has those values
    /// stored, and they would shadow this round's defaults. An entry that still
    /// matches its old default is treated as "never customised".
    private static let supersededDefaults: [ShortcutAction: String] = [
        .toggleFollowPlayhead: "f",
        .toggleSplitStereo: "s",
        .enterTimecode: "/",
        // 混音器原来占的是裸 x（和 ABX 共用一把，靠查表顺序分）。改绑 ⌘5 之后
        // 那份存量默认值要放行，不然它会盖住新的。
        .toggleMixer: "x",
    ]

    init() {
        var defaults: [ShortcutAction: String] = [:]
        for action in ShortcutAction.allCases {
            defaults[action] = action.defaultKey
        }
        var migrated = false
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            for (rawKey, value) in decoded {
                guard let action = ShortcutAction(rawValue: rawKey) else { continue }
                let canonical = ShortcutStore.normalize(value)
                if canonical != value { migrated = true }
                if let stale = ShortcutStore.supersededDefaults[action],
                   canonical == ShortcutStore.normalize(stale) {
                    defaults[action] = action.defaultKey
                    migrated = true
                    continue
                }
                defaults[action] = canonical
            }
        }
        self.bindings = defaults.mapValues { ShortcutStore.normalize($0) }
        // Write the canonical form back once so the migration runs only the first time.
        if migrated { save() }
    }

    /// 「将本页设置恢复默认」（快捷键页）：整张表回到出厂键位，落盘一次。
    func resetToDefaults() {
        for action in ShortcutAction.allCases { bindings[action] = action.defaultKey }
        save()
    }

    /// The recorder used to drop modifiers, so old preferences store the shifted
    /// glyph ("J" really meant ⇧J) or a control character ("\r" meant ⌃M). Read
    /// them back into the canonical form instead of asking for a re-record.
    static func normalize(_ raw: String) -> String {
        // Already a signature: the recorder writes the base as it arrives from
        // charactersIgnoringModifiers, which is lowercase for letters.
        if let first = raw.first, "⌘⌃⌥⇧".contains(first) {
            let mods = raw.prefix { "⌘⌃⌥⇧".contains($0) }
            return String(mods) + raw.dropFirst(mods.count).lowercased()
        }
        guard raw.count == 1, let u = raw.unicodeScalars.first else { return raw }
        if u.value == 0x08 || u.value == 0x7F { return raw }              // ⌫ / 删除
        if u.value >= 1 && u.value <= 26 {
            return "⌃" + String(UnicodeScalar(u.value + 64)!)             // ⌃A…⌃Z
        }
        if u.value >= 0xF700 && u.value <= 0xF7FF { return raw }          // 方向键等
        if Character(raw).isUppercase { return "⇧" + raw.lowercased() }
        return raw
    }

    /// 上档面的符号 → 同一枚键未上档那个字符（ANSI 键位）。只给 `signature` 用。
    static let unshifted: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Canonical text for a key press: ⌘⌃⌥⇧ in that order, then the key.
    /// The ⌘-only legacy bindings are dispatched in their own branch, so a signature
    /// carries ⌘ only when the user recorded one (⌘/).
    ///
    /// `droppingControl` keeps ⌃ out of the *glyph* only. ⌃ still shapes the base,
    /// because a real ⌃J arrives as the control character \n and only ⌃ can turn it
    /// back into "j" — drop the flag outright and the press decodes to nothing.
    static func signature(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                          charactersIgnoringModifiers: String,
                          droppingControl: Bool = false) -> String {
        var base: String
        if keyCode == 36 || keyCode == 76 {
            // Return sends \r, the same byte ⌃M sends, so it has to be read from the
            // key code — otherwise Enter fires whatever ⌃M is bound to.
            base = returnKey
        } else {
            base = charactersIgnoringModifiers
            // Control letters arrive as the control character itself (⌃M comes in as \r).
            if modifiers.contains(.control), base.count == 1,
               let u = base.unicodeScalars.first, u.value >= 1, u.value <= 26, u.value != 8 {
                base = String(UnicodeScalar(u.value + 64)!)
            }
            // ⌃H 是上面唯一被排除掉的那一个：\u{8} 正是退格键自己送来的字节，两者
            // 靠字节分不开。照 ↩ 那条反着认 —— 不是退格键（keyCode 51）按出来的
            // \u{8}，就是 ⌃H。这里不写死 H 的 keyCode，别的键盘布局上 H 不在那个位置。
            if modifiers.contains(.control), base == "\u{8}", keyCode != 51 { base = "h" }
            // ⇧ 不参与「忽略修饰键」：charactersIgnoringModifiers 送来的已经是上档那一面
            // 的符号（⇧, 给 "<"、⇧. 给 ">"，规格里那句「即 <>」就是这把键的真面目；
            // 1…6 那一路早就踩过，所以插槽键改按 keyCode 认）。按字符查表的绑定如果不
            // 管 ⇧1…⇧6，就得把符号折回键面上未上档的那个字符 —— ⇧ 本身照旧留在前缀里，
            // 和字母那一路（⇧J 读成 ⇧j）同一套规矩。表是 ANSI 键位；换布局上档面不同的
            // 键，用户重绑一次即可，这里不猜。
            if modifiers.contains(.shift), base.count == 1,
               let folded = Self.unshifted[base] { base = folded }
        }
        guard !base.isEmpty else { return "" }
        var sig = ""
        if modifiers.contains(.command) { sig += "\u{2318}" }
        if modifiers.contains(.control) && !droppingControl { sig += "\u{2303}" }
        if modifiers.contains(.option) { sig += "\u{2325}" }
        if modifiers.contains(.shift) { sig += "\u{21e7}" }
        return sig + base.lowercased()
    }

    static func signature(for event: NSEvent) -> String {
        signature(keyCode: event.keyCode,
                  modifiers: event.modifierFlags,
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "")
    }

    /// The press read without its ⌃, for the fallback pass in `action(forPress:)`.
    static func signatureWithoutControl(for event: NSEvent) -> String {
        signature(keyCode: event.keyCode,
                  modifiers: event.modifierFlags,
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                  droppingControl: true)
    }

    func save() {
        var dict: [String: String] = [:]
        for (action, key) in bindings {
            dict[action.rawValue] = key
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: self.key)
        }
    }

    func key(for action: ShortcutAction) -> String {
        bindings[action] ?? action.defaultKey
    }

    /// The binding as the menu bar shows it: signatures keep the base lowercase.
    func displayKey(for action: ShortcutAction) -> String {
        key(for: action).uppercased()
    }

    /// 菜单项右侧那一截按键，用来和 ⌘1/2/3 一样右对齐。只认带 ⌘ 的绑定：裸字母挂进
    /// 菜单就成了全局 key equivalent，用户在输入框里打个字都被它抢走。绑成别的（裸字母、
    /// 方向键、↩）返回 nil，菜单退回把键名写在标题里。按下反正由本地监视器派发，这里只管显示。
    func menuCommandShortcut(for action: ShortcutAction) -> (KeyEquivalent, EventModifiers)? {
        let sig = key(for: action)
        let mods = sig.prefix { "⌘⌃⌥⇧".contains($0) }
        let base = sig.dropFirst(mods.count)
        guard mods.contains("⌘"), base.count == 1, let char = base.first, char.isASCII else { return nil }
        var flags: EventModifiers = [.command]
        if mods.contains("⌃") { flags.insert(.control) }
        if mods.contains("⌥") { flags.insert(.option) }
        if mods.contains("⇧") { flags.insert(.shift) }
        return (KeyEquivalent(char), flags)
    }

    /// Reverse lookup for a captured key event. Enum order decides when two
    /// actions share a binding, which matches how the old switch behaved.
    func action(forSignature sig: String, excluding: Set<ShortcutAction> = []) -> ShortcutAction? {
        guard !sig.isEmpty else { return nil }
        for action in ShortcutAction.allCases where !Self.commandOnly.contains(action) {
            guard !excluding.contains(action) else { continue }
            let bound = bindings[action] ?? action.defaultKey
            if !bound.isEmpty, bound == sig { return action }
        }
        return nil
    }

    /// Reverse lookup for a press that actually happened, ⌃ included. Two passes:
    /// the binding as recorded, then — only when ⌃ is held and the first pass came
    /// up empty — the same press read without its ⌃. That second pass is what makes
    /// ⌃J/⌃K/⌃L and ⌃⌘J reach the keys they narrow; the table itself has no ⌃ rows,
    /// so a single pass could only ever find nothing and drop the whole press.
    func action(forPress event: NSEvent) -> ShortcutAction? {
        action(forPressWithKeyCode: event.keyCode,
               modifiers: event.modifierFlags,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "")
    }

    /// The lookup with its event inputs spelled out, so the same code can be driven
    /// with hand-built presses: this machine drops every synthetic key event, which
    /// leaves no other way to show the wiring answers inside the app.
    func action(forPressWithKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                charactersIgnoringModifiers: String,
                excluding: Set<ShortcutAction> = []) -> ShortcutAction? {
        let full = Self.signature(keyCode: keyCode, modifiers: modifiers,
                                  charactersIgnoringModifiers: charactersIgnoringModifiers)
        if let action = action(forSignature: full, excluding: excluding) { return action }
        guard modifiers.contains(.control) else { return nil }
        let narrowed = Self.signature(keyCode: keyCode, modifiers: modifiers,
                                      charactersIgnoringModifiers: charactersIgnoringModifiers,
                                      droppingControl: true)
        guard let action = action(forSignature: narrowed, excluding: excluding),
              Self.controlNarrows.contains(action) else { return nil }
        return action
    }
}

// MARK: - 插件槽

/// 快照里的一格：插件身份、它自己的 bypass，外加 AU 自己的状态（参数）。
/// AVAudioUnit 不进快照 —— 撤销恢复时按这份身份重新实例化（引擎会尽量把还能用的
/// unit 就地留下），再把 state 灌回去。state 就是 AUAudioUnit.fullState 的二进制
/// plist（实测 Apple AUDelay 183 B，新实例 applyState 之后延迟时间照回 0.25 秒）。
struct SlotSnapshot: Equatable, Codable {
    var plugin: AUPlugin?
    var bypass: Bool
    var state: Data?
}

/// 通道条一格的显示状态。`loading` 是「AU 正在主线程外实例化」的临时状态，
/// 所以它不属于快照：快照里出现一个永远转不完的圈，就没有意义了。
struct SlotState: Equatable {
    var plugin: AUPlugin?
    var bypass = false
    var loading = false

    init(plugin: AUPlugin? = nil, bypass: Bool = false, loading: Bool = false) {
        self.plugin = plugin
        self.bypass = bypass
        self.loading = loading
    }
}

/// 浏览器/通道条要找哪一格：哪一轨、第几槽（0 起）。id 带上轨，
/// 从 A 的第 1 格切到 B 的第 1 格时 .sheet(item:) 才会重新弹一次。
struct SlotTarget: Identifiable, Equatable {
    var side: TrackSide
    var index: Int
    var id: String { "\(side)-\(index)" }
}

// MARK: - Edit history

/// Everything 撤销 / 重做 can bring back: the two lists, every marker on file,
/// the loop ranges, the monitoring gain, the two channel strips' pre-gain and the
/// two plugin chains.
/// Deliberately absent: which songs sit in the A/B slots (换曲 clears the stack
/// instead), playhead, selection, zoom, depth and the mode.
struct EditState: Equatable {
    var tracks: [Track]
    var backupTracks: [Track]
    var markers: [String: [Marker]]
    var rangeA: ABRange?
    var rangeB: ABRange?
    /// 两轨的时间偏移（秒）。它算「这一段怎么对齐」的一部分，所以进撤销栈；
    /// 但不进通道条预设 —— 预设换个曲子也该成立，偏移恰恰只在这两首之间有意义。
    var trimA: TimeInterval
    var trimB: TimeInterval
    var outputGainDB: Double
    var preGainA: Double
    var preGainB: Double
    var laneFaderA: Double
    var laneFaderB: Double
    var panA: Int
    var panB: Int
    /// 六格插件链的快照，nil = 空槽。装插件是编辑，所以它进撤销栈。
    var slotsA: [SlotSnapshot?]
    var slotsB: [SlotSnapshot?]
    var laneBypassA: Bool
    var laneBypassB: Bool
}

/// A pair of snapshot stacks, 30 entries deep. Only the undo stack is kept across
/// a session's lifetime; both are dropped when the app quits.
final class EditHistory {
    static let limit = 30

    private(set) var undoStack: [EditState] = []
    private(set) var redoStack: [EditState] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state an edit is about to destroy.
    func record(_ before: EditState) {
        undoStack.append(before)
        trim(&undoStack)
        redoStack.removeAll()
    }

    /// 编辑没落地（插件装不上就是这种）时把刚记下的那条撤掉，别留一步假的撤销。
    func dropLastRecord() {
        undoStack.removeLast()
    }

    /// Returns the state to step back to, remembering the current one for 重做.
    func undo(current: EditState) -> EditState? {
        guard let before = undoStack.popLast() else { return nil }
        redoStack.append(current)
        trim(&redoStack)
        return before
    }

    func redo(current: EditState) -> EditState? {
        guard let after = redoStack.popLast() else { return nil }
        undoStack.append(current)
        trim(&undoStack)
        return after
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func trim(_ stack: inout [EditState]) {
        if stack.count > EditHistory.limit { stack.removeFirst(stack.count - EditHistory.limit) }
    }
}

// MARK: - SettingsStore

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var invertWheel: Bool {
        didSet { UserDefaults.standard.set(invertWheel, forKey: "invertWheel") }
    }
    /// ABX 的字号改为跟随播放列表之后，18 的基准偏小，统一抬到 20。
    static let defaultPlaylistFontSize: Double = 20
    @Published var playlistFontSize: Double {
        didSet { UserDefaults.standard.set(playlistFontSize, forKey: "playlistFontSize") }
    }
    /// Vertical axis depth below full scale, stored positive (30 = -30 dBFS floor).
    static let defaultDepthDB: Double = 30
    @Published var waveformDepthDB: Double {
        didSet { UserDefaults.standard.set(waveformDepthDB, forKey: "waveformDepthDB") }
    }
    @Published var waveformSplitStereo: Bool {
        didSet { UserDefaults.standard.set(waveformSplitStereo, forKey: "waveformSplitStereo") }
    }
    @Published var waveformFollowPlayhead: Bool {
        didSet { UserDefaults.standard.set(waveformFollowPlayhead, forKey: "waveformFollowPlayhead") }
    }
    /// One wheel notch pans 1/N of the visible waveform width.
    static let defaultWaveformPanDivisor: Double = 4
    @Published var waveformPanDivisor: Double {
        didSet { UserDefaults.standard.set(waveformPanDivisor, forKey: "waveformPanDivisor") }
    }
    /// The size 「保存当前窗口大小为默认」 writes and 「应用默认窗口大小」 reads.
    /// Only the size is remembered; the window keeps whatever corner it is at.
    @Published var savedWindowSize: CGSize? {
        didSet {
            guard let size = savedWindowSize else {
                UserDefaults.standard.removeObject(forKey: "savedWindowSize")
                return
            }
            UserDefaults.standard.set([size.width, size.height], forKey: "savedWindowSize")
        }
    }
    /// 播放列表栏的宽度：只有用户真的拖过分隔条才有值。没拖过就是 nil，
    /// HSplitView 继续按它自己的默认铺，首次启动的样子一点不变。P 键把栏收掉再
    /// 打开时，靠这一份把上次的宽还原。
    static let playlistWidthMin: Double = 150
    static let playlistWidthMax: Double = 500
    @Published var playlistSidebarWidth: Double? {
        didSet {
            guard let width = playlistSidebarWidth else {
                UserDefaults.standard.removeObject(forKey: "playlistSidebarWidth")
                return
            }
            UserDefaults.standard.set(width, forKey: "playlistSidebarWidth")
        }
    }
    /// 打开程序后要不要把上一次 ⌘S 的那份工程自动载回来。默认关 ——
    /// 冷启动应该是一个干净的窗口，想接着上次干就在设置里拨开这一条。
    @Published var autoRestoreSession: Bool {
        didSet { UserDefaults.standard.set(autoRestoreSession, forKey: "autoRestoreSession") }
    }
    /// Monitoring gain for the transport fader. Not persisted: it goes back to
    /// ±00.00 on every launch. -96 stands in for -∞, and exports never see it
    /// because ffmpeg reads the source file directly.
    @Published var outputGainDB: Double = 0
    /// 毛玻璃界面开关：走带栏和列表栏各一枚，互不影响。默认开 ——
    /// 开着那一块透出桌面磨砂；用户在设置里关掉就退回实色（barBackdrop / 列表那层白 0.13）。
    @Published var transportGlass: Bool {
        didSet { UserDefaults.standard.set(transportGlass, forKey: "transportGlass") }
    }
    @Published var listGlass: Bool {
        didSet { UserDefaults.standard.set(listGlass, forKey: "listGlass") }
    }
    /// 无缝切换视频轨：开着时看不见那一轨的播放器一直挂在自己的
    /// `AVPlayerLayer` 上、由 `warm` 提前摆准，换轨只把那一层提到上头 —— 不再有「先黑一下
    /// 等 seek 落地」那一段。代价是两台解码器同时干活，所以给了注释、也给了关掉的路：
    /// 关着 = 2.2.0 老办法（只挂摆着那一台）。默认开。
    @Published var seamlessVideoSwitch: Bool {
        didSet { UserDefaults.standard.set(seamlessVideoSwitch, forKey: "seamlessVideoSwitch") }
    }
    /// 裁切导出的引擎。开着先走 AVFoundation（Passthrough，入点帧精确、
    /// 不重编码），读不了或写不出的容器回落 ffmpeg -c copy。默认开。
    @Published var preferAVFoundationTrim: Bool {
        didSet { UserDefaults.standard.set(preferAVFoundationTrim, forKey: "preferAVFoundationTrim") }
    }
    /// 退出编辑模式前先弹那一句「请先降低监听设备音量」。默认开；关掉就直接退。
    @Published var editModeExitPrompt: Bool {
        didSet { UserDefaults.standard.set(editModeExitPrompt, forKey: "editModeExitPrompt") }
    }
    /// Where the export panels open. Chosen once, then every panel (导出… / 导出当前
    /// 轨道范围 / 导出全部轨道范围) starts here until it is pointed somewhere else.
    @Published var exportDirectory: URL? {
        didSet {
            guard let path = exportDirectory?.path else {
                UserDefaults.standard.removeObject(forKey: "exportDirectory")
                return
            }
            UserDefaults.standard.set(path, forKey: "exportDirectory")
        }
    }

    /// 没存过 = 用默认值，存过 = 听那一份的。`bool(forKey:)` 给不了前者（缺键一律 false），
    /// 而要的是「默认开、用户关掉的那格保持关掉」。
    private static func boolOr(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    private init() {
        invertWheel = UserDefaults.standard.bool(forKey: "invertWheel")
        let saved = UserDefaults.standard.double(forKey: "playlistFontSize")
        // Pre-v18 builds defaulted to 11 pt; treat anything below 12 as "never chosen".
        // The raise to 20 runs exactly once, then the stored value is left alone.
        if UserDefaults.standard.bool(forKey: "playlistFontRaisedTo20") {
            playlistFontSize = saved >= 12 ? saved : Self.defaultPlaylistFontSize
        } else {
            UserDefaults.standard.set(true, forKey: "playlistFontRaisedTo20")
            playlistFontSize = Self.defaultPlaylistFontSize
        }

        let savedDepth = UserDefaults.standard.double(forKey: "waveformDepthDB")
        waveformDepthDB = savedDepth >= 12 ? min(savedDepth, 96) : Self.defaultDepthDB
        let savedFrame = UserDefaults.standard.array(forKey: "savedWindowSize") as? [Double]
        savedWindowSize = savedFrame?.count == 2
            ? CGSize(width: savedFrame![0], height: savedFrame![1]) : nil
        // 栏宽：0（没存过）或者落在栏本身允许的范围外，都当成「没拖过」。
        let savedSidebar = UserDefaults.standard.double(forKey: "playlistSidebarWidth")
        playlistSidebarWidth = savedSidebar >= Self.playlistWidthMin
            && savedSidebar <= Self.playlistWidthMax ? savedSidebar : nil
        waveformSplitStereo = UserDefaults.standard.bool(forKey: "waveformSplitStereo")
        waveformFollowPlayhead = UserDefaults.standard.bool(forKey: "waveformFollowPlayhead")
        // 没存过就是 false：默认不自动恢复上次会话。
        autoRestoreSession = UserDefaults.standard.bool(forKey: "autoRestoreSession")
        // 毛玻璃：默认开（两栏都开）。存过就听存过的 —— 用户在设置里亲手
        // 关掉的那一格，不能让这次改动把使用者自己的选择盖回去。
        transportGlass = Self.boolOr("transportGlass", default: true)
        listGlass = Self.boolOr("listGlass", default: true)
        // 无缝切轨：默认开，关过一次就记住关过。
        seamlessVideoSwitch = Self.boolOr("seamlessVideoSwitch", default: true)
        // 裁切引擎：默认开，关过一次就记住关过。
        preferAVFoundationTrim = Self.boolOr("preferAVFoundationTrim", default: true)
        editModeExitPrompt = Self.boolOr("editModeExitPrompt", default: true)
        let savedPan = UserDefaults.standard.double(forKey: "waveformPanDivisor")
        waveformPanDivisor = savedPan >= 1 ? min(savedPan, 20) : Self.defaultWaveformPanDivisor
        if let path = UserDefaults.standard.string(forKey: "exportDirectory") {
            exportDirectory = URL(fileURLWithPath: path)
        }
    }

    func bumpPlaylistFont(by delta: Double) {
        playlistFontSize = max(9, min(28, playlistFontSize + delta))
    }

    /// 分隔条每移动一像素都会报一次宽度。测量值先落在一个不发布的变量上：写进
    /// @Published 就等于让整扇主界面跟着重排（波形和走带栏都在同一棵树里），
    /// 拖一下变得很卡。静默 0.4 秒之后再抄一次 —— 那时候手已经停了，一次就够。
    ///
    /// 闸门（复核「记忆没生效」查出来的）：栏刚立起来那一阵，那一格的宽是
    /// HSplitView 按比例给的，不是用户给的，可它和真拖一下走的是同一个回报。照单全收
    /// 就等于每次启动都拿「程序给的比例」把用户记住的那个数冲掉。所以这一栏立起来时
    /// 闸先关（armPlaylistWidthGate），等 SidebarWidthRestorer 把记住的宽摆稳了才开
    /// （settlePlaylistWidthGate）。
    ///
    /// 没记住过宽（头一回）那一趟：闸门开了但没有东西可摆，于是把「开闸那一刻的宽」当
    /// 底子挡一次（baseline）—— 那还是比例给的数，记下来就等于凭空造出一条记忆。
    private var acceptsPlaylistWidthReport = false
    private var playlistWidthBaseline: Double?

    func armPlaylistWidthGate() {
        acceptsPlaylistWidthReport = false
        playlistWidthFlush?.cancel()
        measuredPlaylistWidth = nil
    }

    func settlePlaylistWidthGate(baseline: Double?) {
        playlistWidthFlush?.cancel()
        measuredPlaylistWidth = nil
        playlistWidthBaseline = baseline
        acceptsPlaylistWidthReport = true
    }

    func measurePlaylistWidth(_ width: Double) {
        guard acceptsPlaylistWidthReport,
              width >= SettingsStore.playlistWidthMin, width <= SettingsStore.playlistWidthMax else { return }
        if let base = playlistWidthBaseline, abs(width - base) <= 1 { return }
        playlistWidthBaseline = nil
        measuredPlaylistWidth = width
        playlistWidthFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPlaylistWidth() }
        playlistWidthFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushPlaylistWidth() {
        guard let width = measuredPlaylistWidth,
              abs(width - (playlistSidebarWidth ?? -1)) > 0.5 else { return }
        playlistSidebarWidth = width
    }

    private var measuredPlaylistWidth: Double?
    private var playlistWidthFlush: DispatchWorkItem?

    func resetPlaylistFont() {
        playlistFontSize = Self.defaultPlaylistFontSize
    }

    /// 「将本页设置恢复默认」：只回这一页摆着的那些项。
    /// 显示页 —— 滚轮、波形四格、界面三格，加新的那枚退出编辑模式提示。
    func resetDisplaySettings() {
        invertWheel = false
        waveformDepthDB = Self.defaultDepthDB
        waveformPanDivisor = Self.defaultWaveformPanDivisor
        waveformSplitStereo = false
        waveformFollowPlayhead = false
        transportGlass = true
        listGlass = true
        seamlessVideoSwitch = true
        editModeExitPrompt = true
    }

    /// 数据页 —— 会话恢复和列表字号，加新的裁切引擎；缓存、标记、导出目录不在这一页上，
    /// 也就一颗都不碰。
    func resetDataSettings() {
        autoRestoreSession = false
        playlistFontSize = Self.defaultPlaylistFontSize
        preferAVFoundationTrim = true
    }

    /// 播放列表字号 13 时 ABX 的字就是设计基准；1.25 让 ABX 永远比列表大一档。
    var abxFontScale: CGFloat { CGFloat(playlistFontSize) * 1.25 / 13 }
}
