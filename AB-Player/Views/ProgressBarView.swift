import SwiftUI
import AppKit

// MARK: - ProgressBarNSView

class ProgressBarNSView: NSView {
    /// 视图高 32，上下各留 8 给标记三角形，条本身 16；播放头高 20 因此上下各出 2。
    private static let barHeight: CGFloat = 16
    private static let playheadWidth: CGFloat = 2.0
    private static let playheadHeight: CGFloat = 20.0
    private static let handleSize = NSSize(width: 3.15, height: 8.65)
    /// 手柄只有 3.15 宽，判定区按 Lab 那样向两侧再放 3pt。
    private static let handleGrab: CGFloat = handleSize.width / 2 + 3

    var duration: TimeInterval = 0
    var position: TimeInterval = 0
    /// 已播放那一段的颜色：A 轨绿、B 轨蓝（最终轮），别的角色一律两轨共用。
    var fillColor: NSColor = .barFill { didSet { needsDisplay = true } }
    var markers: [Marker] = []
    var range: ABRange? = nil
    var isSelectingRange = false
    var pendingRangeStart: TimeInterval? = nil
    var pendingRangeEnd: TimeInterval? = nil

    /// Both range callbacks have to be present for ⌘ to arm the selection tool:
    /// the ABX bar has no range at all, so a temporary selection there would only
    /// draw a box that can never be committed.
    var supportsRangeGesture: Bool { onRangeStart != nil && onRangeEnd != nil }

    var onSeek: ((TimeInterval, Bool) -> Void)?
    var onRangeStart: ((TimeInterval, Bool) -> Void)?
    var onRangeUpdate: ((TimeInterval, Bool) -> Void)?
    var onRangeEnd: ((TimeInterval, Bool) -> Void)?
    /// 范围手柄：拖动中实时写那一端，松手收尾这一笔。
    var onEdgeDrag: ((Bool, TimeInterval) -> Void)?
    var onEdgeDragEnd: (() -> Void)?

    /// Latched at mouseDown: one press stays in the mode it started in, so an
    /// in-flight drag still finishes as a selection when ⌘ is released mid-drag.
    private var dragSelects = false
    /// Latched with it — ⇧ means "this pointer move drives both lanes".
    private var dragBothLanes = false
    private var isDragging = false
    /// 按住手柄时的那一端；nil = 没在拖手柄。
    private var draggingEdge: Bool? = nil
    private var commandHeld = false
    private var trackingArea: NSTrackingArea?
    private var flagsMonitor: Any?

    override var mouseDownCanMoveWindow: Bool { false }

    /// What the bar does right now: a live drag keeps the mode it latched at
    /// mouseDown, otherwise the range mode or the temporary ⌘ one is in effect.
    private var selecting: Bool {
        isDragging ? dragSelects : (isSelectingRange || tempSelecting)
    }
    private var tempSelecting: Bool { commandHeld && supportsRangeGesture }

    override func draw(_ dirtyRect: NSRect) {
        // Fixed vertical padding reserved above/below the bar for marker triangles.
        let barRect = bounds.insetBy(dx: 0, dy: 8)
        guard barRect.height > 0 else { return }

        NSColor.barTrack.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()

        guard duration > 0 else { return }

        let progress = CGFloat(position / duration)
        let progressX = progress * barRect.width
        let playheadX = barRect.minX + progressX

        // Progress fill first
        fillColor.setFill()
        NSBezierPath(rect: NSRect(x: barRect.minX, y: barRect.minY,
                                  width: progressX, height: barRect.height)).fill()

        // Range highlight ON TOP (semi-transparent)
        if let range = range {
            let startX = barRect.minX + CGFloat(range.start / duration) * barRect.width
            let endX = barRect.minX + CGFloat(range.end / duration) * barRect.width
            NSColor.barRangefill.setFill()
            NSBezierPath(rect: NSRect(x: startX, y: barRect.minY,
                                      width: endX - startX, height: barRect.height)).fill()
            // Range border
            NSColor.barRangestroke.setStroke()
            let borderPath = NSBezierPath()
            borderPath.move(to: NSPoint(x: startX, y: barRect.minY))
            borderPath.line(to: NSPoint(x: startX, y: barRect.maxY))
            borderPath.move(to: NSPoint(x: endX, y: barRect.minY))
            borderPath.line(to: NSPoint(x: endX, y: barRect.maxY))
            borderPath.lineWidth = 1.5
            borderPath.stroke()
        }

        // Selection highlight ON TOP (semi-transparent)
        if selecting, let start = pendingRangeStart, let end = pendingRangeEnd {
            let startX = barRect.minX + CGFloat(min(start, end) / duration) * barRect.width
            let endX = barRect.minX + CGFloat(max(start, end) / duration) * barRect.width
            NSColor.barSelection.setFill()
            NSBezierPath(rect: NSRect(x: startX, y: barRect.minY,
                                      width: endX - startX, height: barRect.height)).fill()
        }

        if tempSelecting && !isDragging { drawArmedHint(barRect) }

        // Markers on top: global (backtick) = orange ▼ above the bar, tip tangent;
        // side (M) = bright cyan ▲ below the bar, tip tangent.
        for marker in markers {
            let mx = barRect.minX + CGFloat(marker.position / duration) * barRect.width
            let tri = NSBezierPath()
            switch marker.kind {
            case .global:
                tri.move(to: NSPoint(x: mx, y: barRect.maxY))            // tip touches bar top
                tri.line(to: NSPoint(x: mx - 4, y: bounds.maxY))
                tri.line(to: NSPoint(x: mx + 4, y: bounds.maxY))
                NSColor.barMarkerglobal.setFill()
            case .sideA, .sideB:
                tri.move(to: NSPoint(x: mx, y: barRect.minY))            // tip touches bar bottom
                tri.line(to: NSPoint(x: mx - 4, y: bounds.minY))
                tri.line(to: NSPoint(x: mx + 4, y: bounds.minY))
                NSColor.barMarkerside.setFill()
            }
            tri.close()
            tri.fill()
        }

        // 播放头：2 宽 20 高，比条本身上下各出 2，压在填充与范围的交界上。
        let pw = Self.playheadWidth
        NSColor.barPlayhead.setFill()
        NSBezierPath(rect: NSRect(x: playheadX - pw / 2,
                                  y: barRect.midY - Self.playheadHeight / 2,
                                  width: pw, height: Self.playheadHeight)).fill()

        // 范围手柄：条两端各一块，按住可拖。
        if let range = range {
            let s = Self.handleSize
            NSColor.barHandle.setFill()
            for edge in [CGFloat(range.start / duration), CGFloat(range.end / duration)] {
                let cx = barRect.minX + edge * barRect.width
                NSBezierPath(roundedRect: NSRect(x: cx - s.width / 2, y: barRect.midY - s.height / 2,
                                                 width: s.width, height: s.height),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// Dashed frame on the range column: the bar is armed for a range drag for as
    /// long as ⌘ is held, without latching the 选择 mode.
    private func drawArmedHint(_ barRect: NSRect) {
        let path = NSBezierPath(roundedRect: barRect.insetBy(dx: -1.5, dy: -1.5),
                                xRadius: 4, yRadius: 4)
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.barArmed.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let time = timeForX(loc.x)
        // 手柄优先：判定只看横向距离，按到哪一端就拖哪一端。
        if let edge = edgeAtHit(x: loc.x) {
            isDragging = true
            draggingEdge = edge
            dragSelects = false
            needsDisplay = true
            return
        }
        isDragging = true
        // The hover tracking already armed the bar; the event's own flags cover a
        // press made before a tracking update could land.
        let armed = commandHeld || event.modifierFlags.contains(.command)
        dragSelects = isSelectingRange || (armed && supportsRangeGesture)
        dragBothLanes = event.modifierFlags.contains(.shift)

        if dragSelects {
            pendingRangeStart = time
            pendingRangeEnd = time
            onRangeStart?(time, dragBothLanes)
        } else {
            onSeek?(time, dragBothLanes)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let time = timeForX(loc.x)

        if let edge = draggingEdge {
            onEdgeDrag?(edge, time)
        } else if dragSelects {
            pendingRangeEnd = time
            onRangeUpdate?(time, dragBothLanes)
        } else {
            onSeek?(time, dragBothLanes)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false

        if let edge = draggingEdge {
            draggingEdge = nil
            onEdgeDrag?(edge, timeForX(convert(event.locationInWindow, from: nil).x))
            onEdgeDragEnd?()
        } else if dragSelects, let end = pendingRangeEnd {
            onRangeEnd?(end, dragBothLanes)
        }
        // A ⌘-armed drag ends with the tool released, so the ghost selection
        // goes with it; the latched 选择 mode keeps its pending start as before.
        if !isSelectingRange {
            pendingRangeStart = nil
            pendingRangeEnd = nil
        }
        dragSelects = false
        needsDisplay = true
    }

    /// 这一枪落在哪个手柄上（true = 起点端，false = 终点端）。
    private func edgeAtHit(x: CGFloat) -> Bool? {
        guard duration > 0, let range = range, onEdgeDrag != nil else { return nil }
        let bar = bounds.insetBy(dx: 0, dy: 8)
        guard bar.width > 0 else { return nil }
        for (edge, value) in [(true, range.start), (false, range.end)] {
            let cx = bar.minX + CGFloat(value / duration) * bar.width
            if abs(x - cx) <= Self.handleGrab { return edge }
        }
        return nil
    }

    // MARK: - ⌘ tracking

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        guard window != nil else { return }
        // flagsChanged only reaches the first responder, so watch it app-wide and
        // keep only the presses made with the pointer over this bar.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.refreshCommandHeld(event.modifierFlags)
            return event
        }
    }

    deinit {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func refreshCommandHeld(_ flags: NSEvent.ModifierFlags) {
        guard window?.isKeyWindow == true else { return }
        let inside = mouseLocationInside()
        let next = flags.contains(.command) && (inside || isDragging)
        guard next != commandHeld else { return }
        commandHeld = next
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func mouseLocationInside() -> Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        refreshCommandHeld(event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        refreshCommandHeld(event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        commandHeld = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if selecting {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            // Use I-beam cursor (vertical line shape)
            addCursorRect(bounds, cursor: .iBeam)
        }
        // 手柄压在 iBeam 之后：指针一到两端就换成左右箭头，先加的被后面的盖住。
        guard duration > 0, let range = range, onEdgeDrag != nil else { return }
        let bar = bounds.insetBy(dx: 0, dy: 8)
        for value in [range.start, range.end] {
            let cx = bar.minX + CGFloat(value / duration) * bar.width
            addCursorRect(NSRect(x: cx - Self.handleGrab, y: bar.minY,
                                 width: Self.handleGrab * 2, height: bar.height),
                          cursor: .resizeLeftRight)
        }
    }

    private func timeForX(_ x: CGFloat) -> TimeInterval {
        let bar = bounds.insetBy(dx: 0, dy: 8)
        guard duration > 0, bar.width > 0 else { return 0 }
        let ratio = max(0, min(1, (x - bar.minX) / bar.width))
        return TimeInterval(ratio) * duration
    }
}

// MARK: - ProgressBarView (SwiftUI wrapper)

struct ProgressBarView: NSViewRepresentable {
    let duration: TimeInterval
    let position: TimeInterval
    let markers: [Marker]
    let range: ABRange?
    let isSelectingRange: Bool
    var fillColor: NSColor = .barFill
    var onSeek: ((TimeInterval, Bool) -> Void)?
    var onRangeStart: ((TimeInterval, Bool) -> Void)?
    var onRangeUpdate: ((TimeInterval, Bool) -> Void)?
    var onRangeEnd: ((TimeInterval, Bool) -> Void)?
    var onEdgeDrag: ((Bool, TimeInterval) -> Void)?
    var onEdgeDragEnd: (() -> Void)?

    func makeNSView(context: Context) -> ProgressBarNSView {
        let view = ProgressBarNSView()
        view.fillColor = fillColor
        view.onSeek = onSeek
        view.onRangeStart = onRangeStart
        view.onRangeUpdate = onRangeUpdate
        view.onRangeEnd = onRangeEnd
        view.onEdgeDrag = onEdgeDrag
        view.onEdgeDragEnd = onEdgeDragEnd
        return view
    }

    func updateNSView(_ nsView: ProgressBarNSView, context: Context) {
        let rangeChanged = nsView.range != range
        nsView.duration = duration
        nsView.position = position
        nsView.markers = markers
        nsView.range = range
        nsView.isSelectingRange = isSelectingRange
        nsView.fillColor = fillColor
        nsView.onSeek = onSeek
        nsView.onRangeStart = onRangeStart
        nsView.onRangeUpdate = onRangeUpdate
        nsView.onRangeEnd = onRangeEnd
        nsView.onEdgeDrag = onEdgeDrag
        nsView.onEdgeDragEnd = onEdgeDragEnd
        if rangeChanged { nsView.window?.invalidateCursorRects(for: nsView) }
        nsView.needsDisplay = true
    }
}
