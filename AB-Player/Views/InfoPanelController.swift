import SwiftUI
import AppKit

/// Finder-inspector-style floating panel for 信息: non-modal, so the main
/// window keeps working while it is open, and it refreshes automatically
/// because the hosted view observes the same PlayerViewModel.
final class InfoPanelController {
    static let shared = InfoPanelController()
    private(set) var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func toggle(vm: PlayerViewModel) {
        if isVisible { close(vm: vm) } else { open(vm: vm) }
    }

    func open(vm: PlayerViewModel) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 230),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = "信息"
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: InfoPanel(vm: vm))
            p.center()
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        vm.showInfoPanel = true
    }

    func close(vm: PlayerViewModel) {
        panel?.orderOut(nil)
        vm.showInfoPanel = false
    }
}
