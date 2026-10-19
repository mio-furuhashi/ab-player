import SwiftUI
import AppKit

// MARK: - Vertical Slider

struct VerticalSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tintColor: NSColor = .systemBlue
    /// When set, ⌥-click snaps to this value.
    var resetValue: Double? = nil

    func makeNSView(context: Context) -> VerticalSliderNSView {
        let v = VerticalSliderNSView()
        v.minValue = range.lowerBound
        v.maxValue = range.upperBound
        v.currentValue = value
        v.tintColor = tintColor
        v.resetValue = resetValue
        v.onValueChanged = { self.value = $0 }
        return v
    }
    func updateNSView(_ v: VerticalSliderNSView, context: Context) {
        v.currentValue = value
        v.tintColor = tintColor
        v.resetValue = resetValue
        v.onValueChanged = { self.value = $0 }
        v.needsDisplay = true
    }
}

class VerticalSliderNSView: NSView {
    var minValue: Double = 0
    var maxValue: Double = 1
    var currentValue: Double = 0.5
    var tintColor: NSColor = .systemBlue
    var resetValue: Double?
    var onValueChanged: ((Double) -> Void)?
    private var dragging = false

    override var isFlipped: Bool { true }

    override func draw(_ r: NSRect) {
        let tw: CGFloat = 4
        let tr = NSRect(x: bounds.midX - tw/2, y: 4, width: tw, height: bounds.height - 8)
        NSColor(white: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: tr, xRadius: 2, yRadius: 2).fill()

        let ratio = CGFloat((currentValue - minValue) / (maxValue - minValue))
        let fillH = tr.height * (1 - ratio)
        let fr = NSRect(x: tr.minX, y: tr.minY + fillH, width: tw, height: tr.height - fillH)
        tintColor.setFill()
        NSBezierPath(roundedRect: fr, xRadius: 2, yRadius: 2).fill()

        let ty = tr.minY + fillH
        let ts: CGFloat = 10
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - ts/2, y: ty - ts/2, width: ts, height: ts)).fill()
    }

    override func mouseDown(with e: NSEvent) {
        if let reset = resetValue, e.modifierFlags.contains(.option) {
            currentValue = reset
            onValueChanged?(currentValue)
            needsDisplay = true
            return
        }
        dragging = true; update(e)
    }
    override func mouseDragged(with e: NSEvent) { if dragging { update(e) } }
    override func mouseUp(with e: NSEvent) { dragging = false }

    private func update(_ e: NSEvent) {
        let loc = convert(e.locationInWindow, from: nil)
        let ratio = 1.0 - max(0, min(1, loc.y / bounds.height))
        currentValue = minValue + Double(ratio) * (maxValue - minValue)
        onValueChanged?(currentValue)
        needsDisplay = true
    }
}

// MARK: - 毛玻璃底色

/// 一块贴在内容后面的磨砂。blendingMode 是 behindWindow，所以透上来的是桌面，不是本窗口
/// 别处的颜色（跟 Quick Look 预览那张参考图对得上）；state 钉在 .active，窗口失焦时
/// 也不让它退回纯灰。开关在「设置 → 显示 → 界面」，走带栏和列表栏各一枚。
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.autoresizingMask = [.width, .height]
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Clock-scoped subviews
// These observe only PlayerClock, so 20 Hz position updates
// do not rebuild the full view tree.

struct LiveWaveform: View {
    @ObservedObject var clock: PlayerClock
    let side: TrackSide
    /// 刻度上的跨度（文件时长 + 偏移），不是文件时长：播放头的比值按这把尺算。
    let duration: TimeInterval
    let peaks: PeakData
    let floorDB: Double
    let horizontalZoom: Float
    let tintColor: NSColor
    var splitStereo = false
    var followPlayhead = false
    var scrollInverted = false
    var panNotchDivisor: Double = 4
    /// 这一轨在不在播（父视图从 vm 现读，不观察 clock）。停着的那一轨播放头当场吸附。
    var lanePlaying = true
    /// 这一轨的时间偏移：包络照旧按文件时间存，画的时候横轴跟着它挪。
    var trimSeconds: Double = 0
    var onZoomChange: ((Float) -> Void)?
    var onFloorChange: ((Double) -> Void)?

    var body: some View {
        let position = clock.position(of: side)
        let playhead: CGFloat = duration > 0 ? CGFloat(position / duration) : 0
        return WaveformView(peaks: peaks, floorDB: floorDB, horizontalZoom: horizontalZoom,
                            playheadPosition: playhead, tintColor: tintColor,
                            splitStereo: splitStereo, followPlayhead: followPlayhead,
                            scrollInverted: scrollInverted, panNotchDivisor: panNotchDivisor,
                            lanePlaying: lanePlaying,
                            trimSeconds: trimSeconds,
                            onZoomChange: onZoomChange, onFloorChange: onFloorChange)
            .frame(minHeight: 60, maxHeight: .infinity)
    }
}

struct LiveProgress: View {
    @ObservedObject var clock: PlayerClock
    let side: TrackSide
    let duration: TimeInterval
    let markers: [Marker]
    let range: ABRange?
    let isSelectingRange: Bool
    /// 覆盖「已播放」那一段的颜色。ABX 盲听要用固定色，见 ABXTestView。
    var fillColor: NSColor? = nil
    var onSeek: ((TimeInterval, Bool) -> Void)?
    var onRangeStart: ((TimeInterval, Bool) -> Void)?
    var onRangeUpdate: ((TimeInterval, Bool) -> Void)?
    var onRangeEnd: ((TimeInterval, Bool) -> Void)?
    var onEdgeDrag: ((Bool, TimeInterval) -> Void)?
    var onEdgeDragEnd: (() -> Void)?

    var body: some View {
        ProgressBarView(duration: duration, position: clock.position(of: side), markers: markers,
                        range: range, isSelectingRange: isSelectingRange,
                        fillColor: fillColor ?? (side == .a ? .barFill : .barFillB),
                        onSeek: onSeek, onRangeStart: onRangeStart,
                        onRangeUpdate: onRangeUpdate, onRangeEnd: onRangeEnd,
                        onEdgeDrag: onEdgeDrag, onEdgeDragEnd: onEdgeDragEnd)
    }
}

struct LiveTimeRow: View {
    @ObservedObject var clock: PlayerClock
    let side: TrackSide
    let duration: TimeInterval
    var chapters: [Chapter] = []
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        let position = clock.position(of: side)
        let m = Int(position) / 60
        let s = Int(position) % 60
        return HStack(spacing: 4) {
            Text(String(format: "%d:%02d", m, s))
            Spacer()
            if !chapters.isEmpty {
                Menu {
                    ForEach(chapters) { chapter in
                        Button(chapter.title) { onSeek(chapter.startTime) }
                    }
                } label: {
                    Image(systemName: "list.bullet").font(.caption)
                }
            }
            Text(formatTimeStatic(duration))
        }
        .font(.caption.monospaced())
        .foregroundColor(.secondary)
    }
}

func formatTimeStatic(_ t: TimeInterval) -> String {
    let m = Int(t) / 60
    let s = Int(t) % 60
    return String(format: "%d:%02d", m, s)
}

/// Large HH:MM:SS playhead readout for the transport bar.
/// Double-click opens the timecode field; ⌘+double-click seeks both lanes.
struct LiveBigClock: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var clock: PlayerClock
    let side: TrackSide
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if vm.timecodeEditing {
                TextField("", text: $text, prompt: Text("时分秒"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundColor(.barClockText)
                    .frame(width: 137)
                    .focused($focused)
                    .onSubmit { vm.commitTimecode(text) }
                    .onExitCommand { vm.timecodeEditing = false }
            } else {
                Text(timeString)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundColor(.barClockText)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        vm.beginTimecodeEntry(syncBoth: NSEvent.modifierFlags.contains(.command))
                    }
                    .help("双击输入时间码跳转（⌘双击同步 A/B）")
            }
        }
        .padding(.leading, 8)
        .onChange(of: vm.timecodeEditing) { editing in
            if editing { text = ""; focused = true } else { focused = false }
        }
    }

    private var timeString: String {
        let t = Int(clock.position(of: side))
        return String(format: "%02d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
    }
}

// MARK: - ContentView

/// 把主窗口交给 MainWindow（「关掉再呼回来」要自己留着那一扇）。SwiftUI
/// 不把窗口引用递给内容，只有塞进层级里的这一小片 NSView 知道自己挂在哪一扇上。
/// 接上一次就够了，所以 updateNSView 在已经接上之后直接返回，不跟着 20 Hz 那一拍跑。
private struct MainWindowLink: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { MainWindow.adopt(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !MainWindow.isWired else { return }
        DispatchQueue.main.async { MainWindow.adopt(nsView.window) }
    }
}

struct ContentView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @State private var deselectFlash = false

    var body: some View {
        Group {
            if vm.abxIsActive {
                ABXTestView(vm: vm)
            } else {
                mainLayout
            }
        }
        // Tab 循环早就收掉了，但这个框不是 Tab 画的：SwiftUI 的控件被点一下
        // 也拿到键盘焦点（焦点环是「它当前是焦点」的画法），点空白处又不像 NSTextField
        // 那样把焦点交出去，所以框留下就擦不掉。这一句只关掉那圈高亮效果，键盘焦点
        // 本身照旧，⌘ 快捷键、文本框光标都不受影响。
        .focusEffectDisabled()
        // 窗口引用交给 MainWindow（ABX 页面也在同一条路径上，所以挂在根视图，不挂进
        // mainLayout 里面）。它是零尺寸的，不参与绘制，只负责知道自己在哪一扇窗口里。
        .background(MainWindowLink())
        // 「操作后提示检测中」：测量要跑一阵子，菜单里的「检测中…」又要重新展开菜单才看
        // 得见，所以点完立刻在窗口顶部挂一枚胶囊，跑完自己收。它是纯提示，不吃点击。
        .overlay(alignment: .top) {
            if vm.isDetectingLoudness {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("响度检测中…")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.25), in: Capsule())
                .padding(.top, 10)
                .allowsHitTesting(false)
            }
        }
        .alert("⚠️ 请先降低监听设备音量，再确认退出", isPresented: $vm.showEditModeExitPrompt) {
            Button("确认退出") { vm.setEditMode(false) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("退出后 pre-gain 失效，监听电平立刻抬升！")
        }
    }

    /// The transport bar sits below the split view, so its width is the window's
    /// width: inside the left pane it would also depend on how wide the playlist
    /// happens to be, and the bar then fed back into that split. The pane minimum
    /// is kept under the bar's floor so the bar is what stops the window shrinking.
    private var mainLayout: some View {
        VStack(spacing: 0) {
            HSplitView {
                leftPanel
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                if vm.showPlaylistSidebar {
                    PlaylistSidebar(vm: vm)
                        // 上下限是真的（HSplitView 认），恢复那一格不认 —— 见 SidebarWidthRestorer。
                        .frame(minWidth: PlaylistSidebar.widthFloor,
                               idealWidth: settings.playlistSidebarWidth.map { CGFloat($0) },
                               maxWidth: PlaylistSidebar.widthCeil)
                        // 宽度回报也走这一枚视图：它自己就嵌在那一栏里，`layout()` 里的
                        // bounds 就是这一栏的宽。原先改成走 GeometryReader + PreferenceKey
                        // 那条链，一像素一次穿过 SwiftUI／AppKit 边界，太脆；这一条一路都在
                        // AppKit 侧，摆完就是摆完的数。
                        .background(SidebarWidthRestorer(
                            width: CGFloat(settings.playlistSidebarWidth ?? 0),
                            arm: settings.armPlaylistWidthGate,
                            settle: { settings.settlePlaylistWidthGate(baseline: $0.map { Double($0) }) },
                            measured: { settings.measurePlaylistWidth(Double($0)) }))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            transportBar
        }
        .background(Color(white: 0.1))
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        // 章节转标记的确认：一次要倒进来 ≥50 枚才走到这里。它挂在
        // mainLayout 而不是根视图上，是因为根视图已经有一枚退出编辑模式的 alert，
        // 同一个视图上叠两枚 alert 只认一枚。默认按钮停在「否」。
        .alert("《\(vm.chapterImportPrompt?.fileName ?? "")》自带 \(vm.chapterImportPrompt?.positions.count ?? 0) 个章节",
               isPresented: $vm.showChapterPrompt) {
            Button("否") { vm.cancelChapterImport() }
            Button("是") { vm.confirmChapterImport() }
        } message: {
            Text("要转换为 \(vm.chapterImportPrompt?.kind == .sideB ? "B" : "A") 轨 ▲ 标记吗？该步骤可以撤销。")
        }
    }

    private var leftPanel: some View {
        VStack(spacing: 0) {
            // No Spacer: the waveform lanes absorb every extra vertical pixel,
            // so raising the window raises the waveforms.
            if vm.compareMode == .reference {
                // 模式2（参考曲）：两条各占一节，没被走带那颗章点名的那一节整块略暗
                // （最终轮：0.55），好一眼看出空格和指针此刻归谁。
                trackSection(side: .b).opacity(vm.activeTrack == .b ? 1 : 0.55)
                Divider()
                trackSection(side: .a).opacity(vm.activeTrack == .a ? 1 : 0.55)
            } else {
                // 模式1（版本对比）：波形图和进度条都跟着选中的那一轨走，和走带上那台
                // 时钟同一个口径。两轨同曲时，切换只体现为进度条的颜色（绿 ⇄ 蓝）。
                trackSection(side: vm.activeTrack)
            }
        }
        .background(Color(white: 0.1))
    }

    // MARK: - Track Section

    private func trackSection(side: TrackSide) -> some View {
        let peaks = side == .a ? vm.waveformPeaksA : vm.waveformPeaksB
        // 条、波形、读数这一整列都按轨内刻度量（文件时长 + 偏移）；存的还是文件时间，
        // 画到条上之前先跟着偏移挪一格。见 PlayerViewModel 的「时间偏移」一节。
        let trim = vm.timeTrim(side)
        let duration = vm.laneDuration(side)
        let range = (side == .a ? vm.rangeA : vm.rangeB).map {
            ABRange(start: $0.start + trim, end: $0.end + trim)
        }
        let sideMarkers = (side == .a ? vm.markersA : vm.markersB).map { marker -> Marker in
            var shifted = marker
            shifted.position = vm.laneTime(marker.position, side: side)
            return shifted
        }
        let tintColor: NSColor = side == .a ? .abWaveA : .abWaveB
        let independent = vm.compareMode == .reference

        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                LiveWaveform(clock: vm.clock, side: side, duration: duration, peaks: peaks,
                             floorDB: -settings.waveformDepthDB,
                             horizontalZoom: vm.waveformHorizontalZoom,
                             tintColor: tintColor,
                             splitStereo: settings.waveformSplitStereo,
                             followPlayhead: settings.waveformFollowPlayhead,
                             scrollInverted: settings.invertWheel,
                             panNotchDivisor: settings.waveformPanDivisor,
                             lanePlaying: vm.sideIsPlaying(side),
                             trimSeconds: trim,
                             onZoomChange: { vm.waveformHorizontalZoom = $0 },
                             onFloorChange: { settings.waveformDepthDB = -$0 })

                VStack(spacing: 2) {
                    // Both sliders are log-scaled: equal travel = equal perceptual change.
                    Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(.blue)
                        .help("动态深度：上=看微弱的信号(至 -96 dBFS)，下=看响的信号(-12 dBFS)；⌥点按恢复 -30")
                    VerticalSlider(value: Binding(get: { log2(settings.waveformDepthDB) },
                                                  set: { settings.waveformDepthDB = exp2($0) }),
                                   range: log2(12.0)...log2(96.0), tintColor: .systemBlue,
                                   resetValue: log2(30.0))
                        .frame(width: 18)
                        .frame(maxHeight: .infinity)
                    Image(systemName: "arrow.left.and.right").font(.system(size: 9)).foregroundColor(.orange)
                        .help("横向缩放倍率：⌥ 点按恢复")
                    VerticalSlider(value: Binding(get: { log2(Double(max(1, vm.waveformHorizontalZoom))) },
                                                  set: { vm.waveformHorizontalZoom = Float(exp2($0)) }),
                                   range: 0...log2(Double(WaveformNSView.zoomMax)), tintColor: .systemOrange,
                                   resetValue: 0)
                        .frame(width: 18)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 24)

                if independent {
                    VStack(spacing: 2) {
                        Button {
                            vm.toggleSide(side)
                        } label: {
                            Image(systemName: vm.sideIsPlaying(side) ? "pause.fill" : "play.fill")
                                .font(.body)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.25))
                        .cornerRadius(6)
                        Button {
                            vm.stopSide(side)
                        } label: {
                            Image(systemName: "stop.fill").font(.body)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.25))
                        .cornerRadius(6)
                        // 时间偏移：小停止按钮下面一枚，两轨各一颗、各管各的。
                        TimeTrimControl(vm: vm, side: side)
                    }
                    .fixedSize()
                }
            }
            .frame(maxHeight: .infinity)

            // Match the waveform width: trailing inset = slider column (24+4) [+ side buttons (34+4)]
            LiveProgress(clock: vm.clock, side: side, duration: duration, markers: sideMarkers, range: range,
                         isSelectingRange: vm.isSelectingRange,
                         onSeek: { vm.pointerSeek(side, to: $0, bothLanes: $1) },
                         onRangeStart: { vm.setRangeStart(at: $0, side: side, bothLanes: $1) },
                         onRangeUpdate: { vm.updateRangeSelection(at: $0, side: side, bothLanes: $1) },
                         onRangeEnd: { vm.confirmRangeSelection(endTime: $0, side: side, bothLanes: $1) },
                         onEdgeDrag: { vm.dragRangeEdge(side: side, startEdge: $0, to: $1) },
                         onEdgeDragEnd: { vm.endRangeEdgeDrag() })
                .frame(height: 32)
                .padding(.trailing, independent ? 66 : 28)

            // 章节给的是文件时间，走带走的是轨内时间，这里换算一次。
            LiveTimeRow(clock: vm.clock, side: side, duration: duration, chapters: vm.chapters,
                        onSeek: { vm.seekSide(side, to: vm.laneTime($0, side: side)) })
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// 根视图的最小高，也就是窗口那块地板。SwiftUI 会在声明值上再加标题栏那 28 点：
    /// 声明 400 → 实测 `contentMinSize` 428，而真正留给界面排的是 400 那一格。
    ///
    /// 这块地板必须盖得住最高的那一档，否则走带栏那 60 点会被顶到窗外。最高的就是
    /// 双轨视图：整棵根视图实测要 443 点（`AB_PANEL=layout`，613 与 900 两种宽度、
    /// 列表栏收掉与不收，抄出来都是 443）。老规矩 400 是从单轨那一档量下来的，差 43 点，
    /// 所以窗口一收缩到地板，双轨的走带栏就掉半截出去（反馈的那张图：量到 21.5）。
    /// 裁定：两档一起抬到 445（窗口 473），单轨双轨同一块地板，切模式不跳尺寸。
    static let rootMinHeight: CGFloat = 445

    // MARK: - Transport Bar

    /// Elements the bar gives up when the window gets narrow, right to left:
    /// 分声道 → 跟随 → 侧栏 → 信息 → 范围播放 → 取消选择 → 选择. Widening the
    /// window puts them back in the opposite order. The A/B chip, stop, play,
    /// the clock, the fader and its readout are never in this set.
    struct TransportSlot: OptionSet {
        let rawValue: Int
        static let range      = TransportSlot(rawValue: 1 << 0)
        static let clearRange = TransportSlot(rawValue: 1 << 1)
        static let rangePlay  = TransportSlot(rawValue: 1 << 2)
        static let info       = TransportSlot(rawValue: 1 << 3)
        static let sidebar    = TransportSlot(rawValue: 1 << 4)
        static let follow     = TransportSlot(rawValue: 1 << 5)
        static let split      = TransportSlot(rawValue: 1 << 6)

        /// Right to left, the order the elements are given up in.
        static let dropOrder: [TransportSlot] = [.split, .follow, .sidebar, .info,
                                                 .rangePlay, .clearRange, .range]
        static let droppable: TransportSlot = [.split, .follow, .sidebar, .info,
                                               .rangePlay, .clearRange, .range]
        static let rangeGroup: [TransportSlot] = [.range, .clearRange, .rangePlay]
        static let panelGroup: [TransportSlot] = [.info, .sidebar]
        static let spacing: CGFloat = 12

        // The bar lays these out at exactly these widths, so the estimate below
        // cannot under-shoot and clip a control. Eight digits at 26 pt monospaced
        // measure 129 pt; the clock gets a fixed 145 pt so it is never truncated.
        static let buttonWidth: CGFloat = 48
        static let clockWidth: CGFloat = 145
        static let faderWidth: CGFloat = 150
        static let readoutWidth: CGFloat = 74
        static let dividerWidth: CGFloat = 1
        static let spacerWidth: CGFloat = 12

        static func anyVisible(_ hidden: TransportSlot, _ group: [TransportSlot]) -> Bool {
            group.contains { !hidden.contains($0) }
        }

        /// Width the bar needs for a given set of hidden elements.
        static func neededWidth(hidden: TransportSlot) -> CGFloat {
            var items: [CGFloat] = [buttonWidth, buttonWidth, buttonWidth]
            if anyVisible(hidden, rangeGroup) { items.append(dividerWidth) }
            if !hidden.contains(.range) { items.append(64) }
            if !hidden.contains(.clearRange) { items.append(84) }
            if !hidden.contains(.rangePlay) { items.append(90) }
            if anyVisible(hidden, panelGroup) { items.append(dividerWidth) }
            if !hidden.contains(.info) { items.append(buttonWidth) }
            if !hidden.contains(.sidebar) { items.append(buttonWidth) }
            items.append(clockWidth)
            if !hidden.contains(.follow) { items.append(40) }
            if !hidden.contains(.split) { items.append(40) }
            items.append(spacerWidth)
            items.append(faderWidth)
            items.append(readoutWidth)
            return 16 + items.reduce(0, +) + spacing * CGFloat(items.count - 1)
        }

        static func hiddenItems(forWidth width: CGFloat) -> TransportSlot {
            var hidden = TransportSlot()
            for slot in dropOrder where neededWidth(hidden: hidden) > width {
                hidden.insert(slot)
            }
            return hidden
        }

        /// Smallest the window may get: 3 按钮 + 时钟 + 推子/增益数字.
        static let floorWidth = neededWidth(hidden: droppable)
    }

    /// 走带按钮读的是「当前选中轨在不在播」，不是整体的取或：要求它始终指示
    /// 选中轨的状态，两条腿状态不一致时（另一轨放完了、或只载了一条）才不会显示反。
    private var playButtonPlaying: Bool { vm.sideIsPlaying(vm.activeTrack) }

    /// The clock drives the window width: it either has room for all eight
    /// digits or the window stops shrinking, never half-cut. When the bar runs
    /// out of room the rightmost optional button goes first, then the next.
    /// Measured rather than ViewThatFits: letting SwiftUI re-size-measure nine
    /// copies of the bar on every playhead tick cost 93% CPU against 10%.
    private var transportBar: some View {
        GeometryReader { proxy in
            transportBar(hiding: TransportSlot.hiddenItems(forWidth: proxy.size.width))
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: TransportSlot.floorWidth)
        .frame(height: 60)
    }

    @ViewBuilder
    private func transportBar(hiding hidden: TransportSlot) -> some View {
        HStack(spacing: 12) {
            Text(vm.activeTrack.rawValue)                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.barChipText)
                .frame(width: 48, height: 48)
                .background(vm.activeTrack == .a ? Color.barChipA : Color.barChipB)
                .cornerRadius(8)
                .onTapGesture { vm.switchTrack() }
                .help("点击切换 A/B 轨道")

            Button { vm.stopPlayback() } label: {
                Image(systemName: "stop.fill").font(.title2)
                    .foregroundColor(.barIcon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(width: TransportSlot.buttonWidth, height: TransportSlot.buttonWidth)
            .background(Color.barButtonBase)
            .cornerRadius(6)
            .buttonStyle(.plain)

            Button { vm.togglePlayPause() } label: {
                Image(systemName: playButtonPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .foregroundColor(.barIcon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(width: TransportSlot.buttonWidth, height: TransportSlot.buttonWidth)
            // 底色三态：停 = 常态灰；模式内播放 = 深紫；模式外播放 = 绿（新增，
            // 模式外只上底色、不描边）。stop 不参与配色。
            .background(playButtonPlaying
                        ? (vm.editMode ? Color.barPlayBgEdit : Color.barPlayBgNormal)
                        : Color.barButtonBase)
            .cornerRadius(6)
            .overlay {
                if vm.editMode {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.abModePurple, lineWidth: 2)
                }
            }
            .buttonStyle(.plain)

            if TransportSlot.anyVisible(hidden, TransportSlot.rangeGroup) {
                barDividerLine

                if !hidden.contains(.range) {
                    Button { vm.toggleRangeSelection() } label: {
                        Text("选择").font(.system(size: 16))
                            .foregroundColor(.barIcon)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 64, height: 48)
                    .background(vm.isSelectingRange ? Color.barRangeOn : Color.barButtonBase)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                }

                if !hidden.contains(.clearRange) {
                    Button {
                        deselectFlash = true
                        vm.clearAllRanges()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { deselectFlash = false }
                    } label: {
                        Text("取消选择").font(.system(size: 16))
                            .foregroundColor(.barIcon)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 84, height: 48)
                    .background(deselectFlash ? Color.barDeselectFlash : Color.barButtonBase)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                    .help("清除所有已选范围 (⌘R)")
                }

                if !hidden.contains(.rangePlay) {
                    Button { vm.toggleRangeCompare() } label: {
                        Text("范围播放").font(.system(size: 16))
                            .foregroundColor(.barIcon)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 90, height: 48)
                    .background(vm.rangeCompareEnabled ? Color.barRangePlayOn : Color.barButtonBase)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                }
            }

            if TransportSlot.anyVisible(hidden, TransportSlot.panelGroup) {
                barDividerLine

                if !hidden.contains(.info) {
                    Button { InfoPanelController.shared.toggle(vm: vm) } label: {
                        Image(systemName: "info.circle").font(.title2)
                            .foregroundColor(.barIcon)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .frame(width: TransportSlot.buttonWidth, height: TransportSlot.buttonWidth)
                    .background(Color.barButtonBase)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                    .help("信息窗口 (I)")
                }

                if !hidden.contains(.sidebar) {
                    Button { vm.showPlaylistSidebar.toggle() } label: {
                        Image(systemName: "sidebar.right").font(.title2)
                            .foregroundColor(.barIcon)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .frame(width: TransportSlot.buttonWidth, height: TransportSlot.buttonWidth)
                    .background(Color.barButtonBase)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                }
            }

            LiveBigClock(vm: vm, clock: vm.clock, side: vm.activeTrack)
                .frame(width: TransportSlot.clockWidth, height: TransportSlot.buttonWidth,
                       alignment: .leading)
                // 非编辑模式下底色就是走带栏自己的颜色，等于看不见；进模式整块借用
                // 播放键那一档的深紫底色＋描边（给定的 #823AEF 垫白字太冲，
                // 改成和播放键同一套，所以不再单立柱时钟色）。
                // 圆角跟同排按钮一致（6），不然进模式时是一方块戳在圆角按钮中间。
                .background(vm.editMode ? Color.barPlayBgEdit : Color.barClockBg)
                .cornerRadius(6)
                .overlay {
                    if vm.editMode {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.abModePurple, lineWidth: 2)
                    }
                }

            if !hidden.contains(.follow) {
                Button { settings.waveformFollowPlayhead.toggle() } label: {
                    // 「>|<」：中间的竖线是播放头，两边的小箭头表示画面跟着它走。
                    // 启用时只换图案颜色（橙，不再用描边那支淡紫），底色保持不动。
                    HStack(alignment: .top, spacing: 1.5) {
                        Text(">").font(.system(size: 9, weight: .bold))
                        Capsule().frame(width: 2, height: 15)
                        Text("<").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(settings.waveformFollowPlayhead ? Color.barFollowOn : Color.barFollowOff)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .frame(width: 40, height: 40)
                .background(Color.barButtonBase)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .help("水平缩放时画面跟随播放头 (⌃⇧F)")
            }

            if !hidden.contains(.split) {
                Button { settings.waveformSplitStereo.toggle() } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 1.5).frame(width: 13, height: 13)
                            .offset(x: settings.waveformSplitStereo ? -3.5 : 0)
                        if settings.waveformSplitStereo {
                            Circle().stroke(lineWidth: 1.5).frame(width: 13, height: 13).offset(x: 3.5)
                        }
                    }
                    .foregroundStyle(Color.barSplitIcon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Only the stroked outline is opaque, so the transparent interior
                    // of the circle was not a hit target — clicks near the centre were
                    // swallowed and the button looked dead.
                    .contentShape(Rectangle())
                }
                .frame(width: 40, height: 40)
                .background(Color.barButtonBase)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .help("分声道显示 L / R (⇧S)")
            }

            Spacer(minLength: TransportSlot.spacing)

            GainFader(db: $settings.outputGainDB, onGestureBegin: { vm.beginEdit() })
                .frame(width: TransportSlot.faderWidth, height: 24)
                .help("全局增益 −∞ … +12 dB · ⌥点按推子任意位置归零 · 双击数字可输入")
            GainReadout(db: $settings.outputGainDB, fontSize: settings.playlistFontSize,
                        onBeforeCommit: { vm.beginEdit() })
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if settings.transportGlass { GlassBackground() } else { Color.barBackdrop }
        }
        .onChange(of: settings.outputGainDB) { vm.setOutputGain($0) }
    }

    /// 分隔竖线：barDivider 是白@0.098，系统那根 Divider 有自己的颜色、跟着外观走，
    /// 所以立一根自己的（宽 1 高 36，和 TransportSlot.dividerWidth 同一笔账）。
    private var barDividerLine: some View {
        Rectangle().fill(Color.barDivider).frame(width: TransportSlot.dividerWidth, height: 36)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { vm.openFiles(urls: [url]) }
            }
        }
        return true
    }
}

// MARK: - Playlist Sidebar

/// Row frames per index, used for rubber-band multi-selection
struct MainRowFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct BackupRowFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 一张表此刻有多高。上下两张表分掉的那份高 = 上表高 + 下表高（其余只有两行表头、
/// 两条 Divider 和分隔条，VStack spacing 0），同一帧之内这个和不变，所以量到下表的高
/// 就能算出上表的绝对上限。
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 两张表之间的分隔条。做成 NSView 而不是 SwiftUI 的 Rectangle + DragGesture，是为了
/// 用 AppKit 的光标矩形（`resetCursorRects` + `addCursorRect`，和进度条两端手柄那对
/// 左右箭头同一套做法）：SwiftUI 侧 `onHover` + `NSCursor.set()` 会被 AppKit 自己的
/// 矩形表按回箭头（橡皮擦那轮实测）。指针形状选上下双箭头，要的是「宽度调整
/// 那一套形式」里的竖向款。
private struct PlaylistDivider: NSViewRepresentable {
    /// 此刻还拖得动吗（上表顶到上限、又没到下限 = 只能往上；两边都顶死 = 不动，指针也不换）。
    var dragAvailable: Bool
    /// 竖向位移，向下为正 —— 和原先 DragGesture 的 `translation.height` 一个口径。
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> PlaylistDividerNSView {
        let v = PlaylistDividerNSView()
        v.onDrag = onDrag
        v.dragAvailable = dragAvailable
        return v
    }

    func updateNSView(_ v: PlaylistDividerNSView, context: Context) {
        let changed = v.dragAvailable != dragAvailable
        v.onDrag = onDrag
        v.dragAvailable = dragAvailable
        if changed { v.window?.invalidateCursorRects(for: v) }
    }
}

private final class PlaylistDividerNSView: NSView {
    var dragAvailable = false
    var onDrag: (CGFloat) -> Void = { _ in }
    private var dragStart: CGPoint?

    /// y 向下翻：位移口径和 SwiftUI 的 DragGesture 对齐，往下拖是正数。
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.3, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.5, alpha: 1).setFill()
        let pill = NSRect(x: (bounds.width - 30) / 2, y: (bounds.height - 3) / 2, width: 30, height: 3)
        NSBezierPath(roundedRect: pill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onDrag(convert(event.locationInWindow, from: nil).y - start.y)
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if dragAvailable { addCursorRect(bounds, cursor: .resizeUpDown) }
    }
}

/// 把记住的栏宽摆回分隔条上。为什么不能交给 SwiftUI：`.frame(idealWidth:)`
/// 在这枚 HSplitView 上根本不作数 —— 实测把记住的值写成 180、再写成 400，重启后那一栏
/// 两次都还是 264（窗口拉宽到 1400 时它按比例长到 412），两栏分的一直是比例，不是理想宽。
/// 所以恢复这一步自己来：顺着 superview 找到那枚 NSSplitView，按记住的宽挪一次分隔条。
/// 动手的时机是「记下的宽」或「整条分栏的宽」有一个变了，加上「这一栏刚被 P 重新拉起来」
/// （那时账归零）。用户拖分隔条那一路两个都没变（去抖后的新宽走「记下的宽」那一路回来），
/// 所以不会被自己追。
///
/// 这一枚视图还兼两件事，因为它 `layout()` 里的 `bounds.width` 就是这一栏此刻的宽：
/// `measured` 把它报给 SettingsStore 记账（原先那份走 GeometryReader + PreferenceKey，
/// 一个数要来回穿 SwiftUI／AppKit 边界，太脆）；`arm`/`settle` 管闸门那一头 —— 栏刚
/// 立起来时报上来的是 HSplitView 按比例给的宽，不是用户给的，没摆稳之前不能收进去，
/// 否则每次启动都拿比例把用户记下的数冲掉（见 SettingsStore.measurePlaylistWidth）。
private struct SidebarWidthRestorer: NSViewRepresentable {
    let width: CGFloat
    let arm: () -> Void
    let settle: (CGFloat?) -> Void
    let measured: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarWidthNSView {
        arm()
        let view = SidebarWidthNSView()
        view.settle = settle
        view.measured = measured
        view.target = width
        return view
    }

    func updateNSView(_ view: SidebarWidthNSView, context: Context) {
        view.settle = settle
        view.measured = measured
        view.target = width
    }
}

final class SidebarWidthNSView: NSView {
    var settle: ((CGFloat?) -> Void)?
    var measured: ((CGFloat) -> Void)?
    var target: CGFloat = 0 {
        didSet { if oldValue != target { schedule() } }
    }
    /// 上一回真正摆过的「目标宽 + 分栏总宽」。归 nil 的意思是「这一栏刚立起来，还没摆过」。
    /// 两个一起记，是因为启动那一下窗口还会按记住的尺寸重摆一回：总宽一变，分栏按比例
    /// 把这一栏也带宽（实测 180 摆好后跟着变成 280），只记目标宽的话这一下没人管。
    /// 反过来，摆完总宽就定了，账也对上了，不会在 layout 里追着自己 setPosition。
    private var applied: (target: CGFloat, total: CGFloat)?
    private var settled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applied = nil
        schedule()
        // 兜底：万一这棵树上根本找不到 NSSplitView（界面怎么改都有可能），闸门不能
        // 一辈子关着 —— 那就谁拖都不记账了。1.5 秒还没摆上的话就当场放开、以此刻的宽
        // 当底子挡一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !self.settled else { return }
            self.settleNow(self.bounds.width > 1 ? self.bounds.width : nil)
        }
    }

    override func layout() {
        super.layout()
        if bounds.width > 1 { measured?(bounds.width) }
        schedule()
    }

    /// 摆分隔条这一步不能摆在 layout 里：`setPosition` 会去叫 layoutSubtreeIfNeeded，
    /// 而那一会儿这棵树正在摆 —— AppKit 会打「_NSDetectedLayoutRecursion」，官方话是
    /// 「This may break in the future」。所以一律跳到下一拍主队列再摆，同一拍里多次
    /// 触发只留最后一次。
    private var queued = false

    private func schedule() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async {
            self.queued = false
            self.applyNow()
        }
    }

    private func settleNow(_ baseline: CGFloat?) {
        guard !settled else { return }
        settled = true
        settle?(baseline)
    }

    private func applyNow() {
        guard let split = enclosingSplitView,
              let pane = split.arrangedSubviews.firstIndex(where: { isDescendant(of: $0) }),
              pane > 0 else { return }
        guard target > 1 else {
            // 没记住过宽：没东西要摆。闸门开了，但把此刻的宽挡一次 —— 那是比例给的。
            if bounds.width > 1 { settleNow(bounds.width) }
            return
        }
        // 横着分的栏：这一栏的宽 = 整条分栏的宽 − 分隔条左边 − 分隔条自己那一截。
        // 要它等于 target，分隔条就摆在 total − target − thickness。
        let total = split.bounds.width
        guard applied?.target != target || applied?.total != total else { return }
        applied = (target, total)
        let moved = total - target - split.dividerThickness
        if moved > 0, abs(currentWidth(pane: pane, in: split) - target) > 1 {
            split.setPosition(moved, ofDividerAt: pane - 1)
        }
        // 这一栏的宽是我们说了算的了，往后的回报都是用户给的，收。
        settleNow(nil)
    }

    private func currentWidth(pane: Int, in split: NSSplitView) -> CGFloat {
        split.arrangedSubviews[pane].frame.width
    }

    private var enclosingSplitView: NSSplitView? {
        var walk: NSView? = superview
        while let view = walk {
            if let split = view as? NSSplitView { return split }
            walk = view.superview
        }
        return nil
    }
}

/// 哪一张表上的第几行。抓手指针要认「指针现在停在哪一行」，主列表和备用列表的
/// 行号会撞，所以带上表。
private struct ListRowID: Equatable {
    let isMain: Bool
    let index: Int
}

/// 按住 ⌘ 拖一行的在途记账。源和落点都是数组下标；translation 是手指此刻
/// 的竖向位移，target 由它按整行四舍五入换算 —— 让位的动画只在跨过一格边界时触发一次，
/// 不是每像素一次。
private struct PlaylistRowDrag {
    let isMain: Bool
    let source: Int
    var translation: CGFloat
    var target: Int
}

/// 让位 / 合上的时长，和插件槽调序同一档（iOS 提醒事项那种短促的「让开再合上」）。
private let playlistDragSettle = Animation.easeOut(duration: 0.18)

struct PlaylistSidebar: View {
    /// 这一栏的宽度上下限，和 mainLayout 里的 `.frame` 同一笔账（也是
    /// SettingsStore 记宽度时用的夹取范围）。
    static let widthFloor: CGFloat = 150
    static let widthCeil: CGFloat = 500

    /// 上表高度的老账：下限 60、硬上限 400（只补下面那条地板，这两格不动）。
    private static let upperFloor: CGFloat = 60
    private static let upperCeil: CGFloat = 400
    /// 下表至少露出这么多 —— 窗口太小、再往下拉就把走带挤出窗外时，分隔条就该停住。
    private static let lowerFloor: CGFloat = 60
    /// 验收用的起手高度：那一拖要拖出 200 才看得见撑开，这台机器注不进鼠标事件，
    /// 所以留一条环境变量把起手值摆过去（Release 里编不到，走默认 200）。
    private static let initialUpperHeight: CGFloat = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["AB_LIST_UPPER"], let value = Double(raw) {
            return CGFloat(value)
        }
        #endif
        return 200
    }()

    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var command = CommandState.shared
    @State private var upperHeight: CGFloat = PlaylistSidebar.initialUpperHeight
    /// 下表实测高度，上表绝对上限由它算出（见 `ListHeightKey`）。
    @State private var lowerListHeight: CGFloat = 0
    @State private var mainFrames: [Int: CGRect] = [:]
    @State private var backupFrames: [Int: CGRect] = [:]
    @State private var bandMain: CGRect? = nil
    @State private var bandBackup: CGRect? = nil
    /// 按住 ⌘ 拖一行时的在途状态（nil = 没在拖）。
    @State private var drag: PlaylistRowDrag? = nil
    @State private var hovered: ListRowID? = nil

    private var rowFont: CGFloat { CGFloat(settings.playlistFontSize) }

    var body: some View {
        // 这一栏的高必须由窗口给，不能由两张表给。上表那一格是写死的 height、下表吃满
        // 剩余，两个一相加就是这一栏的「理想高」：少了这层 GeometryReader，分隔条往下拖
        // 会把整栏撑高，HSplitView 又把这个高度回报给窗口，走带栏就这么被顶出窗外
        // （那次「意外撑开」）。GeometryReader 自己只报 10×10，栏高从此
        // 只跟着窗口走，`lowerListHeight` 也才会真的被挤小 —— 上面那道闸就此咬得住。
        GeometryReader { proxy in
            listStack
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private var listStack: some View {
        VStack(spacing: 0) {
            // 播放列表 header
            HStack {
                Text("播放列表").font(.subheadline.bold()).foregroundColor(.white)
                Spacer()
                Button { vm.clearAllTracks() } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                        .font(.system(size: rowFont))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 8).padding(.vertical, 4)

            Divider()

            // Main tracks
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(vm.tracks.enumerated()), id: \.element.id) { idx, track in
                        trackRow(track: track, index: idx, isMain: true)
                    }
                }
            }
            .coordinateSpace(name: "mainList")
            .onPreferenceChange(MainRowFramesKey.self) { mainFrames = $0 }
            .overlay(alignment: .topLeading) { bandView(bandMain) }
            // ⌘ 按着的时候这一趟拖动归「排序」，框选要让路（按住 ⌘ 激活
            // 拖文件名调序，激活逻辑和进度条上按住 ⌘ 临时换工具同一套）。没按 ⌘ 时
            // 框选一点不变。
            .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .named("mainList"))
                .onChanged { v in
                    bandMain = reorderArmed ? nil : normRect(v.startLocation, v.location)
                }
                .onEnded { v in
                    if !reorderArmed {
                        applyBand(normRect(v.startLocation, v.location), frames: mainFrames, isMain: true)
                    }
                    bandMain = nil
                })
            .frame(height: upperHeight)

            // Draggable divider
            PlaylistDivider(dragAvailable: dividerDragAvailable) { dy in
                upperHeight = max(Self.upperFloor, min(upperCeiling, upperHeight + dy * 0.5))
            }
            .frame(height: 6)

            // 备用列表 header
            HStack {
                Text("备用列表").font(.subheadline.bold()).foregroundColor(.white)
                Spacer()
                Button { vm.clearBackupTracks() } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                        .font(.system(size: rowFont))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 8).padding(.vertical, 4)

            Divider()

            // Backup tracks
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(vm.backupTracks.enumerated()), id: \.element.id) { idx, track in
                        trackRow(track: track, index: idx, isMain: false)
                    }
                }
            }
            .coordinateSpace(name: "backupList")
            .onPreferenceChange(BackupRowFramesKey.self) { backupFrames = $0 }
            .background { GeometryReader { Color.clear.preference(key: ListHeightKey.self, value: $0.size.height) } }
            .onPreferenceChange(ListHeightKey.self) { h in
                lowerListHeight = h
                // 窗口被缩小：把上表拉回上限，两张表一起顶出窗外就是说的那个意外
                // 撑开。拉回之后下表高度会重新报上来，一轮就收敛。
                if h > 0 { upperHeight = min(upperHeight, upperCeiling) }
            }
            .overlay(alignment: .topLeading) { bandView(bandBackup) }
            .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .named("backupList"))
                .onChanged { v in
                    bandBackup = reorderArmed ? nil : normRect(v.startLocation, v.location)
                }
                .onEnded { v in
                    if !reorderArmed {
                        applyBand(normRect(v.startLocation, v.location), frames: backupFrames, isMain: false)
                    }
                    bandBackup = nil
                })
        }
        .background {
            if settings.listGlass { GlassBackground() } else { Color(white: 0.13) }
        }
        // 栏被 P 收掉：拖拽状态要清账，指针要是我们摆的就得还原成箭头。
        .onDisappear { drag = nil; PlaylistCursor.show(nil) }
        // ⌘ 松开、指针却一动不动 —— 修饰键只有监听那一条路，不补这一下抓手指针会粘住。
        .onChange(of: command.held) { _ in refreshCursor() }
    }

    // MARK: 两张表之间的高度账

    /// 上表能长到多高：把下表留在地板上，再套原有的 400 硬上限。两张表分的那份高在这
    /// 一帧里是定数（`upperHeight + lowerListHeight`），所以这就是条绝对上限，拖动夹到
    /// 这里就停 —— 窗口再小也不会把走带挤出窗外。下表还没量到第一帧时不设这道闸。
    private var upperCeiling: CGFloat {
        guard lowerListHeight > 0 else { return Self.upperCeil }
        return max(Self.upperFloor,
                   min(Self.upperCeil, upperHeight + lowerListHeight - Self.lowerFloor))
    }

    /// 分隔条此刻拖不拖得动（往上、往下有一条走得通就算能动，指针才换成调整形状）。
    private var dividerDragAvailable: Bool {
        upperCeiling > upperHeight || upperHeight > Self.upperFloor
    }

    // MARK: - 按住 ⌘ 拖行调序

    /// ⌘ 上膛（或已经在拖）时，框选要让路。
    private var reorderArmed: Bool { command.held || drag != nil }

    private func rowCount(isMain: Bool) -> Int { isMain ? vm.tracks.count : vm.backupTracks.count }

    /// 行高：量到就用量到的（两张表都是 spacing 0，行高就是行距）。首帧还没量到时
    /// 按字号兜一个，拖第一下时早已量好了。
    private func rowHeight(index: Int, isMain: Bool) -> CGFloat {
        let measured = (isMain ? mainFrames[index] : backupFrames[index])?.height ?? 0
        return measured > 1 ? measured : rowFont * 1.35 + 12
    }

    /// iOS 提醒事项那一套：被拿起来的那一行跟着手指走，中间那一截各让开一个行高。
    private func rowShift(index: Int, isMain: Bool) -> (offset: CGFloat, lifted: Bool) {
        guard let d = drag, d.isMain == isMain else { return (0, false) }
        if index == d.source { return (d.translation, true) }
        let h = rowHeight(index: index, isMain: isMain)
        if d.source < d.target, index > d.source, index <= d.target { return (-h, false) }
        if d.source > d.target, index < d.source, index >= d.target { return (h, false) }
        return (0, false)
    }

    /// 抓手指针的现算：在拖 = 握拳；⌘ 按着且指针停在某一行 = 张开的手；否则收回箭头。
    private func refreshCursor() {
        if drag != nil { PlaylistCursor.show(.closedHand) }
        else { PlaylistCursor.show(hovered != nil && command.held ? .openHand : nil) }
    }

    private func rowDragChanged(_ v: DragGesture.Value, index: Int, isMain: Bool) {
        if drag == nil {
            // 只有 ⌘ 按着的那一下起手才算排序；没按就把这趟拖动整趟让给框选。
            guard command.held, rowCount(isMain: isMain) > 1 else { return }
            drag = PlaylistRowDrag(isMain: isMain, source: index, translation: 0, target: index)
        }
        guard let d = drag, d.isMain == isMain else { return }
        let h = rowHeight(index: d.source, isMain: isMain)
        let n = rowCount(isMain: isMain)
        // 位移夹在表的头尾之间：拖不出这一栏，也不会拖到隔壁那张表的行上去。
        let travel = min(CGFloat(n - 1 - d.source) * h, max(-CGFloat(d.source) * h, v.translation.height))
        drag = PlaylistRowDrag(isMain: isMain, source: d.source, translation: travel,
                               target: min(n - 1, max(0, d.source + Int((travel / h).rounded()))))
        refreshCursor()
    }

    private func rowDragEnded() {
        guard let d = drag else { return }
        // 先清账再挪数组：偏移清零和数组换位是同一拍，两边正好对上，所以这里不该有
        // 动画（有的话会看见整列往回弹一下）。
        drag = nil
        refreshCursor()
        guard d.source != d.target else { return }
        vm.reorderTrack(from: d.source, to: d.target, isMain: d.isMain)
    }

    private func bandView(_ rect: CGRect?) -> some View {
        Group {
            if let r = rect {
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .background(Color.accentColor.opacity(0.15))
                    .frame(width: max(1, r.width), height: max(1, r.height))
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func normRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func applyBand(_ rect: CGRect, frames: [Int: CGRect], isMain: Bool) {
        let hits = frames.filter { rect.intersects($0.value) }.map(\.key)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if isMain {
            if shift {
                vm.mainMulti.formUnion(hits)
            } else {
                vm.mainMulti = Set(hits)
                vm.selectedTrackIndex = hits.first
            }
        } else {
            if shift {
                vm.backupMulti.formUnion(hits)
            } else {
                vm.backupMulti = Set(hits)
                vm.backupSelectedIndex = hits.first
            }
        }
    }

    private func trackRow(track: Track, index: Int, isMain: Bool) -> some View {
        let isSelected = isMain
            ? (vm.selectedTrackIndex == index || vm.mainMulti.contains(index))
            : (vm.backupSelectedIndex == index || vm.backupMulti.contains(index))
        let s = rowShift(index: index, isMain: isMain)
        return HStack(spacing: 4) {
            if vm.trackA?.id == track.id {
                Text("A").foregroundColor(.green).font(.system(size: max(8, rowFont - 4), weight: .bold))
            }
            if vm.trackB?.id == track.id {
                Text("B").foregroundColor(.blue).font(.system(size: max(8, rowFont - 4), weight: .bold))
            }
            Text(track.displayName).lineLimit(1).truncationMode(.middle)
                .foregroundColor(track.missing ? Color(white: 0.4) : .white)
                .font(.system(size: rowFont))
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(s.lifted ? Color(white: 0.3)
                             : (isSelected ? Color.accentColor.opacity(0.4) : Color.clear))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Group {
                if isMain {
                    Color.clear.preference(key: MainRowFramesKey.self,
                                           value: [index: g.frame(in: .named("mainList"))])
                } else {
                    Color.clear.preference(key: BackupRowFramesKey.self,
                                           value: [index: g.frame(in: .named("backupList"))])
                }
            }
        })
        // 按住 ⌘ 拖行调序：偏移排在量尺寸之后，所以行高读到的仍是没挪动的那一份。
        .offset(y: s.offset)
        .zIndex(s.lifted ? 1 : 0)
        .shadow(color: s.lifted ? Color.black.opacity(0.5) : .clear,
                radius: s.lifted ? 5 : 0, y: s.lifted ? 2 : 0)
        // 拿起来那一条要即时跟手，不吃动画；让位的那些在跨过一格边界时才动一下。
        // 落定那一拍 drag 归 nil、数组同时换位，两边正好对上，这时候不能再有动画，
        // 不然整列看着往回弹一下。
        .animation(s.lifted || drag == nil ? nil : playlistDragSettle, value: drag?.target)
        // 抓手：⌘ 按着 + 指针停在这一行（拖起来换握拳，见 refreshCursor）。
        .onContinuousHover { phase in
            if case .active = phase {
                hovered = ListRowID(isMain: isMain, index: index)
            } else if hovered == ListRowID(isMain: isMain, index: index) {
                hovered = nil
            }
            refreshCursor()
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { v in rowDragChanged(v, index: index, isMain: isMain) }
            .onEnded { _ in rowDragEnded() })
        .gesture(SpatialTapGesture().onEnded { _ in
            let shift = NSEvent.modifierFlags.contains(.shift)
            if isMain { vm.selectTrackRow(index: index, shift: shift) }
            else { vm.selectBackupRow(index: index, shift: shift) }
        })
        .contextMenu {
            Button("设为A轨道") {
                if isMain { vm.setTrackA(index: index) } else { vm.setTrackAFromBackup(index: index) }
            }
            Button("设为B轨道") {
                if isMain { vm.setTrackB(index: index) } else { vm.setTrackBFromBackup(index: index) }
            }
            Divider()
            if isMain {
                Button("移至备用列表") {
                    ensureSelection(index: index, isMain: true)
                    vm.moveSelectedToBackup()
                }
            } else {
                Button("移至播放列表") {
                    ensureSelection(index: index, isMain: false)
                    vm.moveSelectedBackupToMain()
                }
            }
            Button("移除") {
                ensureSelection(index: index, isMain: isMain)
                vm.removeSelected(isMain: isMain)
            }
        }
    }

    /// Right-clicking a row that is not part of the multi-selection narrows
    /// the selection to just that row (Finder behavior) before bulk actions.
    private func ensureSelection(index: Int, isMain: Bool) {
        if isMain {
            if !(vm.selectedTrackIndex == index || vm.mainMulti.contains(index)) {
                vm.mainMulti = []
                vm.selectedTrackIndex = index
            }
        } else {
            if !(vm.backupSelectedIndex == index || vm.backupMulti.contains(index)) {
                vm.backupMulti = []
                vm.backupSelectedIndex = index
            }
        }
    }
}

// MARK: - Info Panel

/// 信息面板是一张表 —— 行首一列名字，右边一列数值，两列都左对齐、
/// 定宽，所以五行整整齐齐竖下来。当前这一轨带画面时再立第二列，并在最上面带出
/// 「音频 | 视频」那一行表头（规格：视频不存在就不显示首行 —— 表头和第二列一起没）。
/// 第 4、5 行的行首按规格是空 cell：那两行音频/视频各说各的口径，名字盖不住。
struct InfoPanel: View {
    @ObservedObject var vm: PlayerViewModel

    private static let labelWidth: CGFloat = 52
    private static let columnWidth: CGFloat = 80

    /// 这一轨有没有画面：读回来之前是 nil，读回来才定。
    private var video: VideoFacts? {
        guard let path = vm.currentTrack?.url.path else { return nil }
        let facts = vm.videoFacts[path]
        return (facts?.hasVideo ?? false) ? facts : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let track = vm.currentTrack {
                Text(track.displayName).font(.headline)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let video {
                        headerRow(video)
                    }
                    row("容器", track.containerInfo, video: video?.container)
                    row("编码", vm.codecNames[track.url.path] ?? "…", video: video?.codec)
                    // 码率这一格：有画面的容器里，文件字节数 ÷ 时长那本账把视频也算进去了，
                    // 所以读到了音轨自己的码率就用它，读不到才退回按容器算的那一份。
                    row("码率", video?.audioBitrate ?? track.bitrateInfo, video: video?.bitrate)
                    // 音频报声道、视频报色域；行首那一格按规格空着。
                    row("", track.channelInfo, video: video?.colour)
                    row("", track.sampleRateInfo, video: video?.frameRate)
                }
            } else { Text("未选择轨道").foregroundColor(.secondary) }
            Spacer()
            HStack { Spacer(); Button("关闭") { InfoPanelController.shared.close(vm: vm) } }
        }
        .padding(20)
        .frame(width: 300, height: video == nil ? 200 : 226)
        .task(id: vm.currentTrack?.url.path) {
            await vm.ensureCodec(for: vm.currentTrack?.url)
            await vm.ensureVideoFacts(for: vm.currentTrack?.url)
        }
    }

    /// 表头那一行：第一格占位，后两格和数值列同一把尺。
    private func headerRow(_ video: VideoFacts) -> some View {
        HStack(spacing: 10) {
            Text("").frame(width: Self.labelWidth, alignment: .leading)
            Text("音频").foregroundColor(.secondary)
                .frame(width: Self.columnWidth, alignment: .leading)
            Text("视频").foregroundColor(.secondary)
                .frame(width: Self.columnWidth, alignment: .leading)
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String, video: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundColor(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            Text(value).monospacedDigit()
                .frame(width: Self.columnWidth, alignment: .leading)
            if let video {
                Text(video).monospacedDigit()
                    .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
    }
}
