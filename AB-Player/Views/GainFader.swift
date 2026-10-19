import SwiftUI
import AppKit

/// Logic-style horizontal gain fader: -∞ at the far left, 0 dB a little past
/// three quarters of the travel, +12 dB at the top of the travel. The negative
/// side follows a 40 dB/decade amplitude law, so the closer you get to 0 the
/// smaller each pixel of travel is in dB — fine control where it matters.
enum GainFaderScale {
    static let minDB = -96.0     // stands in for -∞
    static let maxDB = 12.0
    static let unity: CGFloat = 0.72

    static func db(for p: CGFloat) -> Double {
        let q = max(0, min(1, p))
        if q <= unity {
            return max(minDB, 40 * log10(max(1e-9, Double(q / unity))))
        }
        return 12 * Double((q - unity) / (1 - unity))
    }

    static func position(for db: Double) -> CGFloat {
        if db <= 0 {
            return unity * CGFloat(pow(10, max(minDB, db) / 40))
        }
        return unity + CGFloat(db / maxDB) * (1 - unity)
    }
}

struct GainFader: NSViewRepresentable {
    @Binding var db: Double
    /// Fires once at mouseDown, so a whole drag costs 撤销 a single step.
    var onGestureBegin: (() -> Void)?

    func makeNSView(context: Context) -> GainFaderNSView {
        let v = GainFaderNSView()
        v.onDrag = { self.db = $0 }
        v.onGestureBegin = onGestureBegin
        return v
    }

    func updateNSView(_ v: GainFaderNSView, context: Context) {
        v.db = db
        v.onDrag = { self.db = $0 }
        v.onGestureBegin = onGestureBegin
        v.needsDisplay = true
    }
}

class GainFaderNSView: NSView {
    var db: Double = 0 { didSet { needsDisplay = true } }
    var onDrag: ((Double) -> Void)?
    var onGestureBegin: (() -> Void)?
    private var dragging = false

    private var groove: NSRect {
        NSRect(x: 2, y: bounds.midY - 2, width: bounds.width - 4, height: 4)
    }

    override func draw(_ r: NSRect) {
        let track = groove
        NSColor.barFaderGroove.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let x = track.minX + GainFaderScale.position(for: db) * track.width
        NSColor.barFaderFill.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.midY - 2,
                                         width: max(0, x - track.minX), height: 4),
                     xRadius: 2, yRadius: 2).fill()

        // Handle: a short knurled cap. 帽从 11×20 换成 18×13（横着更宽、
        // 竖着更矮），滚花线跟着帽高走（hh − 8 = 5 长）。
        let hw: CGFloat = 18, hh: CGFloat = 13
        let handle = NSRect(x: x - hw / 2, y: bounds.midY - hh / 2, width: hw, height: hh)
        NSColor.barFaderHandle.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2.5, yRadius: 2.5).fill()
        NSColor.barFaderKnurl.setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for offset in [handle.midX - 2, handle.midX + 2] {
            lines.move(to: NSPoint(x: offset, y: handle.minY + 4))
            lines.line(to: NSPoint(x: offset, y: handle.maxY - 4))
        }
        lines.stroke()
    }

    override func mouseDown(with e: NSEvent) {
        onGestureBegin?()
        if e.modifierFlags.contains(.option) {
            onDrag?(0)          // ⌥-click anywhere: back to ±00.00
            return
        }
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
        guard track.width > 0 else { return }
        onDrag?(GainFaderScale.db(for: (loc.x - track.minX) / track.width))
    }
}

/// The ±00.00 readout: double-click to type an exact value.
struct GainReadout: View {
    @Binding var db: Double
    let fontSize: Double
    var onBeforeCommit: (() -> Void)?

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var display: String {
        if db <= GainFaderScale.minDB + 0.5 { return "-∞" }
        // 归零那一档不再写 ±，就一个 00.00 —— 正负号只在真有正负的时候才有意义。
        if abs(db) < 0.005 { return "00.00" }
        return String(format: "%+.2f", db)
    }

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(.barReadoutText)
                    // 键入框锁死在读数那一档的宽度上：TextField 的宽度是弹性的，
                    // 只给 minWidth 的话它会一路撑开，把左边的推子整根挤走。字号照旧
                    // 不动，只锁宽 —— 和混音器里 pre-gain 那个小框同一个规矩。
                    .frame(width: 74, height: fontSize + 6)
                    .background(Color(white: 0.25))
                    .cornerRadius(3)
                    .onSubmit(commit)
                    .focused($focused)
                    .onExitCommand { editing = false }
                    .onAppear { text = String(format: "%.2f", db); focused = true }
            } else {
                Text(display)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(.barReadoutText)
                    // The readout must never break onto a second line: it sizes
                    // itself and only grows the reserved minimum.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 74, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = true }
            }
        }
        .help("全局增益（仅监听，不影响导出）· 双击输入数值 · ⌃+滚轮微调")
    }

    private func commit() {
        onBeforeCommit?()
        editing = false
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
        db = max(GainFaderScale.minDB, min(GainFaderScale.maxDB, value))
    }
}
