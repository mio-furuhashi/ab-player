import SwiftUI
import AppKit

// MARK: time trim 旋钮
//
// 双轨视图里每一轨一枚，贴在右侧那颗小停止按钮下面。一颗视图管三件事：
// 按住上下拖（一格 1 s，⇧ 0.1 s，⌃ 10 ms，⇧⌃ 一个样本）、⌥ 点按归零、
// 双击下面那行数字开分段输入框。做成一枚 NSView 而不是 SwiftUI 手势，
// 因为这三条要分得开「按在按钮上」和「按在数字上」，还得在拖的途中读修饰键。

enum TimeTrimGeometry {
    /// 按钮那一格和走带上现有的播放／停止同一套尺寸；底下留一行 8 pt 数字。
    static let columnWidth: CGFloat = 34
    static let buttonHeight: CGFloat = 34
    static let readoutHeight: CGFloat = 10
    static let gap: CGFloat = 2
    static let columnHeight: CGFloat = buttonHeight + gap + readoutHeight
    /// 进度条右边要给这一列让出的宽度（列本身 + HStack 的间距）。
    static let trailingInset: CGFloat = columnWidth + 4
}

struct TimeTrimControl: View {
    @ObservedObject var vm: PlayerViewModel
    let side: TrackSide

    var body: some View {
        TimeTrimRepresentable(
            trim: vm.timeTrim(side),
            sampleRate: vm.trimSampleRate(for: side),
            dragStart: { vm.beginTimeTrimDrag() },
            value: { value, dragging in vm.setTimeTrim(value, for: side, recordHistory: !dragging) },
            dragEnd: { vm.endTimeTrimDrag() })
            .frame(width: TimeTrimGeometry.columnWidth, height: TimeTrimGeometry.columnHeight)
            .help("时间偏移：向上拖 = 延后，向下拖 = 提前；一格 1 s，⇧ 0.1 s，⌃ 10 ms，⇧⌃ 一个样本。⌥ 点按归零，双击数字输入。")
    }
}

struct TimeTrimRepresentable: NSViewRepresentable {
    var trim: TimeInterval
    var sampleRate: Double
    var dragStart: () -> Void
    var value: (TimeInterval, Bool) -> Void
    var dragEnd: () -> Void

    func makeNSView(context: Context) -> TimeTrimNSView {
        let v = TimeTrimNSView()
        v.sampleRate = sampleRate
        v.trim = trim
        v.onDragStart = dragStart
        v.onValue = value
        v.onDragEnd = dragEnd
        return v
    }

    func updateNSView(_ v: TimeTrimNSView, context: Context) {
        v.sampleRate = sampleRate
        v.trim = trim
        v.onDragStart = dragStart
        v.onValue = value
        v.onDragEnd = dragEnd
    }
}

final class TimeTrimNSView: NSView {
    /// 一格拖 4 像素：整枚按钮 34 高，一趟拖满就是 ±8 s。
    private static let pointsPerStep: CGFloat = 4

    var trim: TimeInterval = 0 { didSet { needsDisplay = true } }
    var sampleRate: Double = 0
    var onDragStart: (() -> Void)?
    var onValue: ((TimeInterval, Bool) -> Void)?
    var onDragEnd: (() -> Void)?

    /// 起笔时的值、指针高度和档位；nil = 没在拖。
    private var anchorValue: TimeInterval?
    private var anchorY: CGFloat = 0
    private var anchorMods: NSEvent.ModifierFlags = []
    private var lastApplied: TimeInterval = 0
    /// 一笔只记一次历史，而且要真正走出第一步才记：双击数字会先来一次 mouseDown，
    /// 那一下就把账记下，撤销栈里便多出一格什么都没改的。
    private var recordedThisStroke = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var buttonRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: TimeTrimGeometry.buttonHeight)
    }
    private var readoutRect: NSRect {
        NSRect(x: 0, y: TimeTrimGeometry.buttonHeight + TimeTrimGeometry.gap,
               width: bounds.width, height: TimeTrimGeometry.readoutHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let trimmed = trim != 0
        NSColor(white: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 6, yRadius: 6).fill()
        drawGlyph(in: buttonRect)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (Self.readoutText(trim) as NSString).draw(in: readoutRect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: trimmed ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            .paragraphStyle: style])
    }

    /// 上下双箭头，和走带上那几枚同一套 SF Symbol 形式。这里在画布里手绘，
    /// 所以拿不到 SwiftUI 的自动着色：先画模板图，再用 sourceAtop 把前景色铺上去。
    /// 着色口径跟「跟随」那一枚一样：启用只把符号染橙，底色那格不动。
    private func drawGlyph(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let symbol = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: "时间偏移")?
            .withSymbolConfiguration(config)
        guard let image = symbol else { return }
        let box = NSRect(origin: .zero, size: image.size)
        let canvas = NSImage(size: box.size)
        canvas.lockFocus()
        image.draw(in: box)
        (trim != 0 ? NSColor.systemOrange : NSColor.labelColor).set()
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSBezierPath(rect: box).fill()
        canvas.unlockFocus()
        let target = NSRect(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2,
                            width: box.width, height: box.height)
        canvas.draw(in: target)
    }

    /// 固定宽度、至多四位数字：10 ms 以内给三位小数（一个样本就是 0.023 ms，两位会把
    /// 样本档的相邻两格并进同一个数），10 s 以内给整数毫秒，再往上换成秒、满 999 s
    /// 连小数也不要 —— 每一档都留得住四位。
    static func readoutText(_ value: TimeInterval) -> String {
        let ms = value * 1000
        if ms == 0 { return "0" }
        if abs(ms) < 10 { return String(format: "%.3f", ms) }
        if abs(ms) < 10000 { return String(format: "%.0f", ms) }
        if abs(value) < 999 { return String(format: "%.1fs", value) }
        return String(format: "%.0fs", value)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if readoutRect.contains(loc) {
            // 双击那一行数字才开框，单击什么都不做。
            if event.clickCount >= 2 { editByNumber() }
            return
        }
        guard buttonRect.contains(loc) else { return }
        if event.modifierFlags.contains(.option) {
            onValue?(0, false)
            return
        }
        anchorValue = trim
        anchorY = loc.y
        lastApplied = trim
        recordedThisStroke = false
        anchorMods = Self.stepMods(event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchorValue != nil else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let mods = Self.stepMods(event.modifierFlags)
        // 中途换档：以「已经给出去的那个值」重新起手，不然新旧两档的格数会叠在一起。
        if mods != anchorMods {
            anchorValue = lastApplied
            anchorY = loc.y
            anchorMods = mods
        }
        let step = Self.stepValue(anchorMods, sampleRate: sampleRate)
        // 视图是翻转的，指针往上走 y 在减小 —— 往上 = 延后 = 正，所以拿 anchorY 减。
        let notches = ((anchorY - loc.y) / Self.pointsPerStep).rounded()
        let next = (anchorValue ?? 0) + Double(notches) * step
        guard next != lastApplied else { return }
        if !recordedThisStroke {
            recordedThisStroke = true
            onDragStart?()
        }
        lastApplied = next
        onValue?(next, true)
    }

    override func mouseUp(with event: NSEvent) {
        if recordedThisStroke { onDragEnd?() }
        anchorValue = nil
        recordedThisStroke = false
    }

    /// 只认 ⇧ 和 ⌃ 两位：⌥ 归「点按归零」那一条，按住 ⌥ 拖动不该自成一档。
    private static func stepMods(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.shift, .control])
    }

    private static func stepValue(_ mods: NSEvent.ModifierFlags, sampleRate: Double) -> Double {
        let shift = mods.contains(.shift), control = mods.contains(.control)
        if shift && control { return sampleRate > 0 ? 1 / sampleRate : 0.001 }
        if control { return 0.01 }
        if shift { return 0.1 }
        return 1
    }

    private func editByNumber() {
        guard let v = TimeTrimInput.ask(sampleRate: sampleRate) else { return }
        onValue?(v, false)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(buttonRect, cursor: .resizeUpDown)
        addCursorRect(readoutRect, cursor: .pointingHand)
    }
}

// MARK: 分段输入框（[秒]. [毫秒]. [样本]，图示那一版）

enum TimeTrimInput {
    static func ask(sampleRate: Double) -> TimeInterval? {
        TrimInputDialog(rate: sampleRate > 0 ? sampleRate : 44100).run()
    }
}

/// 图示那一版自己开一扇模态窗。NSAlert 顶不开：它的宽只按上面那段文字给（实测 260 pt），
/// 三格排开要 340 多，右边两格和整条青字都裁在窗外，给 accessory 钉死宽度也不涨。
private final class TrimInputDialog: NSObject, NSTextFieldDelegate {
    /// 图示的比例：标题居上，三格一排（框 · 单位），底下「将偏移」+ 换算那行。
    private enum Metric {
        static let width: CGFloat = 392
        static let sidePad: CGFloat = 24
        static let fieldWidth: CGFloat = 64
        static let fieldHeight: CGFloat = 22
        static let dotGap: CGFloat = 3
        static let groupGap: CGFloat = 18
        static let titleY: CGFloat = 22
        static let rowY: CGFloat = 62
        static let footY: CGFloat = 100
        static let buttonY: CGFloat = 140
        /// 圆角推按钮在 large 档量出来是 32 高，窗口高度跟着它算。
        static let buttonHeight: CGFloat = 32
        static let bottomPad: CGFloat = 20
    }

    private let rate: Double
    private let window = TrimInputDialog.makeWindow()
    private let seconds = NSTextField()
    private let millis = NSTextField()
    private let samples = NSTextField()
    private let summary = NSTextField(labelWithString: "")
    private var rowX: CGFloat = Metric.sidePad

    init(rate: Double) {
        self.rate = rate
        super.init()
        buildContent()
    }

    func run() -> TimeInterval? {
        refresh()
        #if DEBUG
        seed()
        #endif
        window.center()
        #if DEBUG
        // 验收截图的落点：主屏是干活的地方，模态框不该盖上去，所以给一扇后门把它
        // 摆到副屏（"@x,y"，全局坐标，原点在左上，跟 AB_WINDOW 的 @ 那一段同一套）。
        if let raw = ProcessInfo.processInfo.environment["AB_DIALOG_AT"],
           let at = Self.parsePoint(raw) {
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - at.y
            window.setFrameTopLeftPoint(NSPoint(x: at.x, y: top))
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.initialFirstResponder = seconds
        let code = NSApp.runModal(for: window)
        window.orderOut(nil)
        return code == .alertFirstButtonReturn ? total() : nil
    }

    private static func makeWindow() -> NSWindow {
        let w = ModalWindow(contentRect: NSRect(x: 0, y: 0, width: Metric.width, height: 200),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isReleasedWhenClosed = false
        return w
    }

    private func buildContent() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: Metric.width, height: 200))
        window.contentView = root

        let title = label("时间偏移", NSFont.boldSystemFont(ofSize: 13))
        title.setFrameOrigin(NSPoint(x: (Metric.width - title.frame.width) / 2, y: Metric.titleY))
        root.addSubview(title)

        let units: [(NSTextField, String)] = [(seconds, "秒"), (millis, "毫秒"), (samples, "样本")]
        let dotFont = NSFont.systemFont(ofSize: 15, weight: .bold)
        let unitFont = NSFont.systemFont(ofSize: 13)
        let dotWidth = textWidth(".", font: dotFont)
        let groupWidths = units.map { Metric.fieldWidth + Metric.dotGap * 2 + dotWidth
            + textWidth($0.1, font: unitFont) }
        let rowWidth = groupWidths.reduce(0, +) + Metric.groupGap * CGFloat(units.count - 1)
        rowX = max(Metric.sidePad, (Metric.width - rowWidth) / 2)

        var x = rowX
        for (field, unit) in units {
            configure(field)
            field.frame = NSRect(x: x, y: Metric.rowY, width: Metric.fieldWidth, height: Metric.fieldHeight)
            root.addSubview(field)
            let dot = label(".", dotFont)
            dot.textColor = NSColor.trimDot
            dot.setFrameOrigin(NSPoint(x: x + Metric.fieldWidth + Metric.dotGap, y: Metric.rowY + 3))
            root.addSubview(dot)
            let name = label(unit, unitFont)
            name.setFrameOrigin(NSPoint(x: x + Metric.fieldWidth + Metric.dotGap * 2 + dotWidth,
                                        y: Metric.rowY + 2))
            root.addSubview(name)
            x += Metric.fieldWidth + Metric.dotGap * 2 + dotWidth + textWidth(unit, font: unitFont)
                + Metric.groupGap
        }

        let caption = label("将偏移", unitFont)
        caption.setFrameOrigin(NSPoint(x: rowX, y: Metric.footY))
        root.addSubview(caption)
        summary.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        summary.textColor = NSColor.abCyan
        summary.sizeToFit()
        // 宽度给到右边距：样本数进了括号以后这一行比原来长，数值一大（几千个样本）
        // 260 就把它截成「…」，那段次读数就白算了。
        summary.frame = NSRect(x: rowX + caption.frame.width + 10, y: Metric.footY,
                               width: Metric.width - (rowX + caption.frame.width + 10) - Metric.sidePad,
                               height: 18)
        root.addSubview(summary)

        // 默认键在右，取消在它左边一格（跟系统弹框同一个方向）。
        let okLeft = addButton("好", action: #selector(commit),
                               rightEdge: Metric.width - Metric.sidePad, defaultButton: true)
        _ = addButton("取消", action: #selector(cancelled), rightEdge: okLeft - 10)

        window.setContentSize(NSSize(width: Metric.width, height: Metric.buttonY + Metric.buttonHeight
            + Metric.bottomPad))
    }

    private func addButton(_ text: String, action: Selector, rightEdge: CGFloat,
                           defaultButton: Bool = false) -> CGFloat {
        guard let root = window.contentView else { return rightEdge }
        let button = NSButton(title: text, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = defaultButton ? "\r" : "\u{1b}"
        button.sizeToFit()
        let width = max(button.frame.width, 84)
        // .rounded 的 bezel 自己带一圈留白，往上挪 4 才和量出来的框对得上。
        button.frame = NSRect(x: rightEdge - width, y: Metric.buttonY - 4,
                              width: width, height: Metric.buttonHeight)
        root.addSubview(button)
        return button.frame.minX
    }

    private func configure(_ field: NSTextField) {
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .right
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
    }

    @objc private func changed() { refresh() }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    @objc private func commit() {
        refresh()
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }

    @objc private func cancelled() { NSApp.stopModal(withCode: .cancel) }

    /// 三格各填各的，留空算 0，合起来才是结果：填 3 秒 2000 毫秒就是 5 秒，不打架。
    private func total() -> TimeInterval {
        parsed(seconds) + parsed(millis) / 1000 + parsed(samples) / rate
    }

    /// 底下这一行边输边换算，正负都带符号。两段分色：秒数是主读数（青），
    /// 样本数是换算出来的次读数，括在括号里、退成亮灰。
    private func refresh() {
        let value = total()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let text = NSMutableAttributedString(
            string: String(format: "%+.3f 秒", value),
            attributes: [.font: font, .foregroundColor: NSColor.abCyan])
        text.append(NSAttributedString(
            string: String(format: " (+%.0f 个样本)", value * rate),
            attributes: [.font: font, .foregroundColor: NSColor.trimSample]))
        summary.attributedStringValue = text
    }

    /// 空着、或者小数点打成了逗号的，都想办法读出一个数：读不出就当 0。
    private func parsed(_ field: NSTextField) -> Double {
        let raw = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(raw) ?? 0
    }

    private func label(_ text: String, _ font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.sizeToFit()
        return field
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    #if DEBUG
    private static func parsePoint(_ raw: String) -> NSPoint? {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    /// 验收用的起手值：这台机器注不进键盘事件，框开出来三格全是空的，底下那行换算就
    /// 只能停在 0，图上要看的「输入后换算的结果」根本没影。给一个 `秒,毫秒,样本`
    /// 的环境变量，把三格填上再手动刷一次（程序改 stringValue 不发变更通知）。
    private func seed() {
        guard let raw = ProcessInfo.processInfo.environment["AB_TRIM_INPUT"] else { return }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for (field, part) in zip([seconds, millis, samples], parts) { field.stringValue = part }
        refresh()
    }
    #endif
}

/// 无标题栏的模态窗：隐藏了标题栏按钮之后还得能拿到键盘，所以自己说是 key 和 main。
private final class ModalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 手动摆位用的容器：翻转过来，y 从上往下数，跟图示一行一行对。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
