import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit

// MARK: 插件编辑浮窗
//
// 一格一个浮窗。原生界面走 AUAudioUnit.requestViewController：实测这台机器上连 v2
// 插件也拿得到（Apple AUDelay 484×255、Xfer OTT 290×400、Focusrite Red 2 EQ 920×315、
// Accusonus ERA-D 737×580），所以不必去碰 kAudioUnitProperty_CocoaUI 那套手工活。
// 底下再挂一张通用参数表：插件自带界面时它是补充，没界面时它就是全部。
//
// 窗口里只放插件自己的界面（头部、旁通那些一律不做，标题栏写了「A · 1 · 名字」）；
// 只有不公开界面的插件才用通用参数表兜底。
//
// 真相只在引擎的 unit 里。兜底那张表每 20 Hz 跟读一次参数，插件自己的界面拧了旋钮
// 这里跟着动，反过来也一样，两边不会打架。

/// 滑杆位置 ↔ 参数值。对数那档把 0…1 指数映射到量程，线性那档直接插值。
enum PluginEditorScale {
    static func position(value: Double, min: Double, max: Double, logarithmic: Bool) -> Double {
        guard max != min else { return 0 }
        if logarithmic, value > 0, min > 0 {
            return (log(value) - log(min)) / (log(max) - log(min))
        }
        return (value - min) / (max - min)
    }

    static func value(position: Double, min: Double, max: Double, logarithmic: Bool) -> Double {
        let clamped = Swift.min(Swift.max(position, 0), 1)
        if logarithmic, min > 0 {
            return exp(log(min) + (log(max) - log(min)) * clamped)
        }
        return min + (max - min) * clamped
    }
}

/// 一格插件的编辑器状态。
final class PluginEditorModel: ObservableObject {
    /// 参数面板上的一行。
    struct Param: Identifiable, Equatable {
        let address: AUParameterAddress
        let name: String
        let detail: String
        let value: AUValue
        let minValue: AUValue
        let maxValue: AUValue
        let logarithmic: Bool
        let writable: Bool
        var id: AUParameterAddress { address }

        init(read p: AUParameter) {
            address = p.address
            name = p.displayName
            detail = PluginEditorModel.detailString(for: p)
            value = p.value
            minValue = p.minValue
            maxValue = p.maxValue
            logarithmic = PluginEditorModel.isLogarithmic(p)
            writable = PluginEditorModel.isWritable(p)
        }
    }

    let side: TrackSide
    let index: Int
    /// 开窗那一刻的插件身份。那一格换了别的插件，这个模型就作废，窗口跟着关。
    let pluginID: String

    @Published private(set) var params: [Param] = []
    @Published private(set) var nativeViewController: NSViewController?
    /// 原生界面还在路上：requestViewController 是异步的，某些厂商会跑一阵。
    @Published private(set) var awaitingNative = true

    /// 写回参数之前叫一次，让撤销栈记下改动前的状态（只在一次手势的开头叫）。
    var onWillEdit: (() -> Void)?
    /// 内容换了个头（参数表行数变了、原生界面到齐）时叫一次，让管家按内容重设窗口大小。
    var onLayoutChange: (() -> Void)?

    private weak var unit: AVAudioUnitEffect?
    private var timer: Timer?
    private var requested = false

    init(side: TrackSide, index: Int, unit: AVAudioUnitEffect, plugin: AUPlugin) {
        self.side = side
        self.index = index
        self.pluginID = plugin.id
        self.unit = unit
    }

    /// 这个模型绑的是不是手里这颗 unit。窗口通常按身份（id）认格子，但拖拽落格会给同一格
    /// 换上另一颗**同名**实例（⌥ 复制盖在原地就是），那时候只有比对象才认得出来。
    func binds(unit: AVAudioUnitEffect?) -> Bool { unit != nil && unit === self.unit }

    // MARK: 生命周期

    /// 窗口露脸时开始跟读并要原生界面；关掉就停，别让 12 个隐形窗口空转。
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
        requestNativeViewOnce()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // 插件自带界面之后就别再跟读参数：表已经不显示了，每 20 Hz 复制一整棵参数树
        // 只是让这个窗口白算一遍，插件自己的界面跟着遭殃。
        guard nativeViewController == nil else { return }
        guard let tree = unit?.auAudioUnit.parameterTree else {
            if !params.isEmpty { params = [] }
            return
        }
        let next = tree.allParameters.map { Param(read: $0) }
        // 值没变就别惊动 SwiftUI：一轨六格全开窗口时，20 Hz 的全量刷新全是白烧。
        let rows = params.count
        if next != params {
            params = next
            // 只有行数变了才重排窗口：拧旋钮时每帧都在报值，别跟着抖个头。
            if next.count != rows { onLayoutChange?() }
        }
    }

    // MARK: 写回

    /// 一次拖动的开头：记一笔撤销，同一个手势里的后续赋值不再进栈
    /// （和推子、pre-gain 一个规矩）。
    func beginGesture() { onWillEdit?() }

    func setValue(_ value: AUValue, address: AUParameterAddress) {
        guard let param = parameter(address) else { return }
        param.value = min(max(value, param.minValue), param.maxValue)
        tick()
    }

    /// 数值框回车：插件自己认字符串的参数（OTT 的 In Gain 量程 0…1，报出来是 "-6.0"）
    /// 先交给它解释，解释不了再按数字折回量程。
    func commitText(_ text: String, address: AUParameterAddress) {
        guard let param = parameter(address) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: AUValue?
        if Self.hasStrings(param) {
            let byPlugin = param.value(from: trimmed)
            if byPlugin >= param.minValue, byPlugin <= param.maxValue { parsed = byPlugin }
        }
        if parsed == nil, let number = Double(trimmed) {
            parsed = min(max(AUValue(number), param.minValue), param.maxValue)
        }
        guard let value = parsed else { tick(); return }
        onWillEdit?()
        param.value = value
        tick()
    }

    private func parameter(_ address: AUParameterAddress) -> AUParameter? {
        unit?.auAudioUnit.parameterTree?.allParameters.first { $0.address == address }
    }

    // MARK: 原生界面

    /// 要原生界面。只在第一次开窗那一回问得到：同一个 unit 问第二次，插件一律回 nil
    /// （实测 Apple AUDelay：484×255 → nil → nil，FabFilter Pro-Q 3 也一样）。
    /// 所以关窗不是关掉这个模型，而是把窗口收起来留着 —— 模型活着，那位界面也活着，
    /// 再开就是同一位，既不用再问一次，也不用把它搬进新窗口。
    /// 搬窗口这条路实测走过：Apple AUDelay 的自定义视图第二次被搬进新窗口时
    /// `-[AUDelayCustomView getParameterValue:]` 直接断言，整个宿主跟着崩。
    private func requestNativeViewOnce() {
        guard !requested, let unit else { return }
        let auu = unit.auAudioUnit
        requested = true
        guard auu.providesUserInterface else {
            awaitingNative = false
            return
        }
        auu.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                guard let self else { return }
                self.nativeViewController = controller
                self.awaitingNative = false
                self.onLayoutChange?()
            }
        }
    }

    // MARK: 读数

    static func hasStrings(_ p: AUParameter) -> Bool {
        Int(p.flags.rawValue) & (1 << 21) != 0     // kAudioUnitParameterFlag_ValuesHaveStrings
    }

    static func isWritable(_ p: AUParameter) -> Bool {
        Int(p.flags.rawValue) & (1 << 31) != 0     // kAudioUnitParameterFlag_IsWritable
    }

    /// 频率类参数（AUDelay 的低通 10…22050 Hz）线性拖根本没法用：九成行程都落在
    /// 2 kHz 以后。实测这批插件一个都不给显示档（flags 的 bit16…22 全是 0），
    /// 所以自己判：单位是 Hz（实测 rawValue = 8），或者量程比值超过 100 且不过 0。
    static func isLogarithmic(_ p: AUParameter) -> Bool {
        guard p.minValue > 0, p.maxValue > 0 else { return false }
        if p.unit.rawValue == 8 { return true }
        return max(p.maxValue, p.minValue) / min(p.maxValue, p.minValue) > 100
    }

    /// 插件自己给的字符串优先（OTT 的 In Gain 报 "-6.0"，而它的原生量程是 0…1）。
    static func detailString(for p: AUParameter) -> String {
        if hasStrings(p) {
            var value = p.value
            let string = withUnsafePointer(to: &value) { p.string(fromValue: $0) }
            if !string.isEmpty { return string }
        }
        if let options = p.valueStrings, !options.isEmpty {
            let i = Int(p.value.rounded())
            return options.indices.contains(i) ? options[i] : "\(p.value)"
        }
        return number(p.value, span: abs(p.maxValue - p.minValue))
            + (p.unitName.map { $0.isEmpty ? "" : " \($0)" } ?? "")
    }

    static func number(_ value: AUValue, span: AUValue) -> String {
        let digits = span >= 1000 ? 0 : span >= 10 ? 1 : span >= 1 ? 2 : 3
        return String(format: "%.\(digits)f", value)
    }
}

// MARK: - 窗口管理

/// 一格一窗的浮窗管家。窗口关掉只是收起界面，插件实例照旧留在链上
/// （规格里定的是：退出编辑模式也不销毁，只切换接管）。
final class PluginEditorController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PluginEditorController()

    /// 一个窗口连同它的模型。存数组，省得把 (轨, 槽) 编成字符串再拆回来。
    private struct Entry {
        let side: TrackSide
        /// 这一项现在挂在哪一格。同轨拖拽调序改的就是它：unit 没换，窗口和模型都留着，
        /// 只有格号跟着插件走。
        var index: Int
        let window: NSWindow
        let model: PluginEditorModel
        /// 开窗那一刻的插件名，只为标题栏那一截留着（换序要重算标题）。
        let pluginName: String
        /// 用户自己收掉的那一格（✕ 或再点一次按钮）。V 的「全部放回」不替使用者打开——
        /// 窗口现在只是收起来、不再销毁，这一条得自己记。
        var withdrawn = false
    }

    private var entries: [Entry] = []

    /// V 那下「隐藏全部」：窗口收起来但留着，插件界面的内部状态跟着留。
    private var hiddenByUser = false
    /// 窗口开合的记账。通道条上那颗小按钮要亮起来，可它只认「哪一格有窗」这一件事，
    /// 与其把窗口表再抄一份进 @Published，不如就报一个改动号让界面重算。
    @Published private(set) var editorRevision = 0

    var openCount: Int { entries.filter { $0.window.isVisible }.count }
    var anyVisible: Bool { entries.contains { $0.window.isVisible } }

    func owns(_ window: NSWindow?) -> Bool {
        window != nil && entries.contains { $0.window === window }
    }

    func window(for side: TrackSide, _ index: Int) -> NSWindow? {
        entry(side, index)?.window
    }

    /// 这一格有没有露着脸。通道条那颗小按钮用它决定亮不亮。
    func isShowing(_ side: TrackSide, index: Int) -> Bool {
        entry(side, index)?.window.isVisible ?? false
    }

    /// 打开（或前置）某一格的编辑器。收起来的窗口直接再摆出来，不重建；空槽没有 unit，
    /// 返回 false 表示没得开。
    @discardableResult
    func open(vm: PlayerViewModel, side: TrackSide, index: Int) -> Bool {
        guard vm.editMode else { return false }
        if let i = entries.firstIndex(where: { $0.side == side && $0.index == index }) {
            hiddenByUser = false
            entries[i].withdrawn = false
            entries[i].window.makeKeyAndOrderFront(nil)
            entries[i].model.start()
            return true
        }
        guard let unit = AudioEngine.shared.unit(side, at: index),
              let plugin = AudioEngine.shared.slotPlugin(side, at: index) else { return false }

        let model = PluginEditorModel(side: side, index: index, unit: unit, plugin: plugin)
        model.onWillEdit = { vm.beginEdit() }
        let hosting = NSHostingView(rootView: PluginEditorView(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Self.title(side, index, plugin.name)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.hidesOnDeactivate = false
        window.level = .floating
        window.contentView = hosting
        model.onLayoutChange = { [weak window] in self.sizeWindowToContent(window) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        entries.append(Entry(side: side, index: index, window: window, model: model,
                             pluginName: plugin.name))
        hiddenByUser = false
        touch()
        model.start()
        return true
    }

    /// 关窗 = 收起来，窗口和模型都留着。理由在 PluginEditorModel.requestNativeViewOnce：
    /// 同一个 unit 的原生界面只给一次，搬进新窗口又会把某些插件当场弄崩。
    func close(side: TrackSide, index: Int) {
        guard let i = entries.firstIndex(where: { $0.side == side && $0.index == index }) else { return }
        entries[i].model.stop()
        entries[i].window.orderOut(nil)
        entries[i].withdrawn = true
        touch()
    }

    /// 这一格换了别的插件、或者卸干净了：窗口和模型一起作废。留着的话，下次给这一格
    /// 开窗口会看见上一个插件的界面。
    private func purge(side: TrackSide, index: Int) {
        guard let i = entries.firstIndex(where: { $0.side == side && $0.index == index }) else { return }
        // 先从表里摘走：window.close() 会回调 windowWillClose，那边还要按窗口找一次，
        // 找到的就是隔壁那一项。
        let item = entries.remove(at: i)
        item.model.stop()
        item.window.close()
        touch()
    }

    func toggle(vm: PlayerViewModel, side: TrackSide, index: Int) {
        if isShowing(side, index: index) { close(side: side, index: index) }
        else { open(vm: vm, side: side, index: index) }
    }

    func closeAll() {
        for item in entries { item.model.stop(); item.window.orderOut(nil) }
        hiddenByUser = false
        touch()
    }

    /// V：全收起来 / 全放回去。一个窗口都没开时什么都不做。用户自己 ✕ 掉的那些不放回。
    func toggleAllPages() {
        guard !entries.isEmpty else { return }
        if hiddenByUser || !anyVisible {
            hiddenByUser = false
            for item in entries where !item.withdrawn {
                item.window.makeKeyAndOrderFront(nil); item.model.start()
            }
        } else {
            hiddenByUser = true
            for item in entries { item.window.orderOut(nil); item.model.stop() }
        }
    }

    /// 同轨拖拽调序之后把两格的窗号对调过去。为什么在这里改而不让 syncWithEngine 关掉：
    /// 换序动的只是数组顺序，两颗 unit 都还在原位活着，窗口里那块原生界面绑的就是它 ——
    /// 关了再开等于把同一个 unit 的原生界面第二次搬进新窗口，那是实测会当场弄崩某些厂商
    /// 的做法。跨轨搬的那一趟不一样：源的 unit 会被放手，那种窗口只能作废，走 purge。
    func remap(side: TrackSide, _ a: Int, _ b: Int) {
        guard a != b else { return }
        let ia = entries.firstIndex { $0.side == side && $0.index == a }
        let ib = entries.firstIndex { $0.side == side && $0.index == b }
        switch (ia, ib) {
        case let (ia?, ib?):
            entries[ia].index = b
            entries[ib].index = a
            retitle(ia)
            retitle(ib)
        case let (ia?, nil):
            entries[ia].index = b
            retitle(ia)
        case let (nil, ib?):
            entries[ib].index = a
            retitle(ib)
        case (nil, nil):
            return          // 这两格都没窗口，什么都不用做，也别惊动通道条那颗按钮
        }
        touch()
    }

    /// 标题栏写的是「A · 3 · 名字」，格号变了就得重算那一个号。
    private func retitle(_ i: Int) {
        entries[i].window.title = Self.title(entries[i].side, entries[i].index, entries[i].pluginName)
    }

    /// 每一格还对不对得上开窗时那个插件：换了、卸了就作废这一格的窗口。撤销、[A→B]、
    /// ⌘F 插空槽最后都汇到 PlayerViewModel.refreshSlots，所以挂在那儿叫一次就够。
    func syncWithEngine() {
        // 先比 id（换了别的插件），再比实例：拖拽落格、撤销调换都可能给同一格换上另一颗
        // **同名**实例，只比 id 认不出来，窗口就留着读那颗已下链的 unit —— 旋钮照旧能动，
        // 动的却不是链子上这颗，读数骗人。同轨调序走 remap，实例没换，所以不会被这条误杀。
        // 先挑出来再动：purge 会改 entries，边遍历边删会跳项，严重时直接 trap。
        let stale = entries.filter {
            AudioEngine.shared.slotPlugin($0.side, at: $0.index)?.id != $0.model.pluginID
                || !$0.model.binds(unit: AudioEngine.shared.unit($0.side, at: $0.index))
        }
        for item in stale { purge(side: item.side, index: item.index) }
    }

    /// 退出编辑模式：链路不再经过这些插件，窗口留着只会读数骗人。收起来，不销毁。
    func editModeEnded() { closeAll() }

    /// ✕：收起来，不是真关（理由同 close），所以这里回 false 拦住 AppKit。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let item = entries.first(where: { $0.window === sender }) else { return true }
        close(side: item.side, index: item.index)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let i = entries.firstIndex(where: { $0.window === window }) else { return }
        entries[i].model.stop()
        entries.remove(at: i)
        touch()
    }

    /// 窗口表变了就叫一声，让通道条那颗小按钮重算亮不亮。
    private func touch() { editorRevision += 1 }

#if DEBUG
    // 探针看的是模型内部（原生视图到没到、参数表几行），模型是私有的，就只开这一扇 DEBUG 的门。
    func debugNativeView(_ side: TrackSide, index: Int) -> NSView? {
        entry(side, index)?.model.nativeViewController?.view
    }

    func debugParams(_ side: TrackSide, index: Int) -> [PluginEditorModel.Param] {
        entry(side, index)?.model.params ?? []
    }

    func debugAwaitingNative(_ side: TrackSide, index: Int) -> Bool {
        entry(side, index)?.model.awaitingNative ?? false
    }
#endif

    /// 原生界面到齐之后按内容重算窗口个头。以前是「原生尺寸 + 一个估来的 padding」，
    /// 估不准：AUDelay 的 484×255 配 150 的余量，窗口比内容高出一截，参数表被顶到底部，
    /// 中间空成一条带（实测截图就是这样）。NSHostingView 的 fittingSize 才是准数。
    func sizeWindowToContent(_ window: NSWindow?) {
        guard let window, let host = window.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let need = host.fittingSize
        guard need.width > 1, need.height > 1 else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 标题栏那一截：窗口高 − 内容高，撑大之后还得给它留着。
        let chrome = window.frame.height - host.frame.height
        var frame = window.frame
        let topEdge = frame.maxY
        frame.size.width = min(need.width, visible.width)
        frame.size.height = min(need.height + chrome, visible.height)
        frame.origin.y = topEdge - frame.height
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        window.setFrame(frame, display: true, animate: false)
    }

    private func entry(_ side: TrackSide, _ index: Int) -> Entry? {
        entries.first { $0.side == side && $0.index == index }
    }

    private static func title(_ side: TrackSide, _ index: Int, _ name: String) -> String {
        "\(side == .a ? "A" : "B") · \(index + 1) · \(name)"
    }
}

// MARK: - 界面

struct PluginEditorView: View {
    @ObservedObject var model: PluginEditorModel

    var body: some View {
        // 插件自带界面时，窗口里就只有它的界面：标题栏已经写了「A · 1 · 名字」，
        // 我再垫一条头部和一张参数表，只是把插件自己的界面挤小。
        // 参数表只给不公开界面的插件兜底。
        Group {
            if let controller = model.nativeViewController {
                NativeAUView(native: controller.view)
                    .frame(width: max(120, controller.view.frame.width),
                           height: max(60, controller.view.frame.height))
            } else if model.awaitingNative {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在载入插件界面…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                parameterArea
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(white: 0.15))
    }

    @ViewBuilder private var parameterArea: some View {
        if model.params.isEmpty {
            Text("该插件不公开参数")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(10)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.params) { param in
                        ParameterRow(model: model, param: param)
                    }
                }
                .padding(6)
            }
            // 行数少就贴着内容长，四行参数不该占掉一整屏；多了到 220 起滚动。
            .frame(maxHeight: 220)
        }
    }
}

/// 参数一行：名字 + 滑杆 + 数值框。跨度大的量程按对数铺滑杆（见 isLogarithmic）。
private struct ParameterRow: View {
    @ObservedObject var model: PluginEditorModel
    let param: PluginEditorModel.Param
    @State private var editing: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(param.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 108, alignment: .leading)
            Slider(value: Binding(get: { position }, set: { moveTo($0) }), in: 0...1) { editing in
                if editing { model.beginGesture() }
            }
            .controlSize(.mini)
            .disabled(!param.writable)
            .frame(minWidth: 90)
            TextField("", text: $editing)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .focused($focused)
                .onSubmit {
                    model.commitText(editing, address: param.address)
                    focused = false
                }
        }
        .frame(height: 18)
        .onAppear { editing = param.detail }
        .onChange(of: param.detail) { editing = $0 }
    }

    private var position: Double {
        PluginEditorScale.position(value: Double(param.value), min: Double(param.minValue),
                                   max: Double(param.maxValue), logarithmic: param.logarithmic)
    }

    private func moveTo(_ position: Double) {
        let value = PluginEditorScale.value(position: position, min: Double(param.minValue),
                                            max: Double(param.maxValue), logarithmic: param.logarithmic)
        model.setValue(AUValue(value), address: param.address)
    }
}

/// 插件自己的界面：原尺寸交给 SwiftUI，不压缩不拉伸（这些视图不少会自己 resizeToFit）。
private struct NativeAUView: NSViewRepresentable {
    let native: NSView

    func makeNSView(context: Context) -> Host {
        Host(provider: self)
    }

    func updateNSView(_ host: Host, context: Context) {
        host.refresh()
    }

    func attach(to host: NSView) {
        if native.frame.width < 1 || native.frame.height < 1 {
            native.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        }
        native.frame.origin = .zero
        native.autoresizingMask = []
        native.translatesAutoresizingMaskIntoConstraints = true
        if host.subviews.first !== native { host.addSubview(native) }
        // 撑窗口要等它真的挂上窗口之后，所以晚一拍再报。
        DispatchQueue.main.async { [weak host] in
            guard let host, let window = host.window else { return }
            PluginEditorController.shared.sizeWindowToContent(window)
        }
    }

    /// 顶左原点，插件视图按它自己的尺寸占位，SwiftUI 靠 intrinsicContentSize 排版。
    final class Host: NSView {
        private let provider: NativeAUView
        init(provider: NativeAUView) {
            self.provider = provider
            super.init(frame: .zero)
            provider.attach(to: self)
        }
        required init?(coder: NSCoder) { fatalError() }
        func refresh() { provider.attach(to: self) }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            subviews.first?.frame.size ?? NSSize(width: 400, height: 220)
        }
    }
}
