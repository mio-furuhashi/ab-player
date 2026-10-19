import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
#if DEBUG
// 只给探针用：把画成 PDF 的界面取回成文字（帮助页、增益读数）。Release 里连这个 import 都没有。
import PDFKit
#endif

@main
struct ABPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = PlayerViewModel()
    @ObservedObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                // The transport bar is what the window cannot be narrower than.
                // 高的地板单轨、双轨共用一块：双轨那档要 443 点排得下，单轨跟着抬到同一块，
                // 切模式就不跳窗口尺寸，走带栏也再掉不出窗外（见 `ContentView.rootMinHeight`）。
                .frame(minWidth: ContentView.TransportSlot.floorWidth,
                       minHeight: ContentView.rootMinHeight)
                .background(Color(white: 0.1))
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.vm = vm }
                .onOpenURL { url in
                    // 双击 .abpl 走工程，其余（音频）还是进播放列表。
                    if url.pathExtension == ProjectStore.projectExtension {
                        vm.loadProject(from: url)
                    } else {
                        vm.openFiles(urls: [url])
                    }
                }
                .sheet(isPresented: $vm.showSettings) { SettingsView(vm: vm) }
                .sheet(isPresented: $vm.showHelp) { HelpView() }
                .sheet(item: $vm.exportRequest) { request in
                    ExportDialogView(vm: vm, scope: request.scope, mode: request.mode) {
                        vm.exportRequest = nil
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…") { openFilePanel() }
                    .keyboardShortcut("o", modifiers: .command)
                // 工程文件：整个会话存成单文件，⌘S 存、⇧⌘S 另存、⇧⌘O 打开。
                // 三项都不挂 .disabled（同一个理由：菜单项一灰，AppKit 就不派发它的按键），
                // 没内容时也照样能存一份空工程。
                Button("打开工程…") { vm.openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                // 第一次 ⌘S 问地方（等于「存储为…」），之后 ⌘S 直接写回那一份，标题上的
                // 「…」也跟着消失 —— 和「撤销 ⌘Z」一样，标题打印的是此刻的行为。
                Button(vm.projectURL == nil ? "存储工程…" : "存储工程") { vm.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("存储为…") { vm.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                // Measuring takes a while and re-entrant runs would just fight for
                // the same two files, so the item names the wait and greys out.
                Button(vm.isDetectingLoudness ? "检测中…" : "检测响度") { vm.detectLoudness() }
                    .disabled(vm.isDetectingLoudness)
            }
            CommandMenu("导出") {
                // 对话框摆在菜单顶上，⌘E；和原来两项、新增两项之间各画一条分隔线。
                //
                // 这三项都不挂 .disabled：SwiftUI 只在菜单真正打开那一刻才把 disabled 的
                // 新值灌回 NSMenuItem（实测：装了轨之后读到的仍是开栏那一刻的 false），
                // 而 ⌘E 是 AppKit 拿 isEnabled 决定放不派发的，于是没点开过「导出」菜单
                // 之前快捷键永远不响。能不能导交给动作自己判（exportLanes 为空就什么都不做），
                // 和旁边两条 1.x 就在的无插件导出一样。
                Button("导出…") { vm.openExportDialog(scope: .current, mode: .trim) }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                // 这两条不重编码、不动品质，名字跟着「裁切」这一档走；
                // 省略号留着 —— 一条弹保存面板、一条弹选目录面板，都还要用户给地方。
                Button("裁切当前轨道范围…") { vm.exportCurrentTrack() }
                Button("裁切全部轨道范围…") { vm.exportAllTracks() }
                Divider()
                // 这两条也开对话框（和 ⌘E 同一张，只是预选渲染模式），所以补省略号。
                Button("渲染后导出当前轨道范围…") { vm.openExportDialog(scope: .current, mode: .render) }
                Button("渲染后导出全部轨道范围…") { vm.openExportDialog(scope: .all, mode: .render) }
            }
            CommandMenu("模式") {
                // 这三条同时是「把主窗口叫回来」的入口。窗口被关掉（现在是
                // 藏起来）之后没有别的窗口可以按按键，菜单这一级是唯一的入口。
                // 版本对比 → 单轨视图、参考曲 → 双轨视图，并用分隔线把这两档
                // 视图和下面的开关分开。
                Button("单轨视图") { MainWindow.show(); vm.setCompareMode(.versionCompare) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("双轨视图") { MainWindow.show(); vm.setCompareMode(.reference) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("ABX") { MainWindow.show(); vm.setCompareMode(.abx) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                // 编辑模式和混音器的键照样在快捷键表里：能写成「⌘ + 一个字符」的就照
                // ⌘1/2/3 的样式把按键印在右边，绑成裸字母或方向键的退回写在标题里。
                // 两项都不挂 .disabled —— SwiftUI 只在菜单真正打开那一刻才把新值灌回
                // NSMenuItem，而 AppKit 是拿 isEnabled 决定派不派发按键的，挂上去会把
                // 快捷键永久吞掉（实测）。该不该放行由动作自己判。
                shortcutButton("编辑模式", .toggleEditMode) { vm.toggleEditMode() }
                shortcutButton("混音器", .toggleMixer) { vm.toggleMixer() }
                // 混音器和视频窗口之间拉一条线。
                Divider()
                // 视频窗口在菜单底部（裁定：不做按钮，收入模式菜单，默认 ⌘6）。
                shortcutButton("视频窗口", .toggleVideo) { vm.toggleVideo() }
            }
            CommandGroup(after: .sidebar) {
                Button("保存当前窗口大小为默认") { WindowDefaults.saveCurrentSize() }
                Button("应用默认窗口大小") { WindowDefaults.applySavedSize() }
                    .disabled(settings.savedWindowSize == nil)
            }
            // 撤销/重做 live in the shortcut table, so the menu items carry no
            // hardcoded ⌘Z: their titles print whatever key is bound right now.
            CommandGroup(replacing: .undoRedo) {
                Button("撤销 \(ShortcutStore.shared.displayKey(for: .undoEdit))") { vm.undoEdit() }
                    .disabled(!vm.canUndo)
                Button("重做 \(ShortcutStore.shared.displayKey(for: .redoEdit))") { vm.redoEdit() }
                    .disabled(!vm.canRedo)
            }
            // 默认的「关于」只印 Info.plist，挂不上文案，
            // 所以在原位换成自己这一份（菜单位置、条目名都不变）。
            CommandGroup(replacing: .appInfo) {
                Button("关于 AB-Player") { AboutPanel.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { vm.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("AB-Player 使用帮助") { vm.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandMenu("播放列表") {
                Button("放大文字") { SettingsStore.shared.bumpPlaylistFont(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("放大文字 (=)") { SettingsStore.shared.bumpPlaylistFont(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小文字") { SettingsStore.shared.bumpPlaylistFont(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("恢复默认字号") { SettingsStore.shared.resetPlaylistFont() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    /// 快捷键表里的绑定能写成「⌘ + 一个字符」的，就照 ⌘1/2/3 的样式把按键印在右边；
    /// 绑成裸字母或方向键的没法这样写（裸字母进菜单会变成全局按键，打字都被抢），
    /// 退回把键名印在标题里。按下都由本地监视器派发，这里只管长什么样。
    @ViewBuilder
    private func shortcutButton(_ title: String, _ action: ShortcutAction,
                                _ body: @escaping () -> Void) -> some View {
        if let shortcut = ShortcutStore.shared.menuCommandShortcut(for: action) {
            Button(title, action: body).keyboardShortcut(shortcut.0, modifiers: shortcut.1)
        } else {
            Button("\(title) \(ShortcutStore.shared.displayKey(for: action))", action: body)
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        // 这批新增的容器要能在面板里点得选。实测本机
        // .ogg/.opus/.wma/.ape/.wv 都已归到 public.audio 之下，只有 .dsf 连 UTI 都没有
        // （audio=false），面板会把它灰掉，所以按扩展名现取一个动态类型补进名单。
        var types: [UTType] = [.audio, .mp3, .wav, .aiff]
        // 带画面的 QuickTime 家族（mp4 / mov）也进得了面板。
        // 声音仍旧由 `AVAudioFile` 从同一个文件里解，只做单画面，不碰 mkv / webm。
        types.append(.movie)
        for ext in AudioFormatCache.ffmpegExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !type.conforms(to: .audio) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { vm.openFiles(urls: panel.urls) }
    }
}

// MARK: - Window size defaults

/// 「保存当前窗口大小为默认」/「应用默认窗口大小」. Only the size is remembered:
/// applying keeps the window where it is and grows it from the top-left corner,
/// which is how dragging the bottom-right corner already behaves.
enum WindowDefaults {
    /// The window the size commands work on: the main window, falling back to the
    /// only content window while nothing has been made main (launch, panel focus).
    static var target: NSWindow? {
        NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !($0 is NSPanel) }
    }

    static func saveCurrentSize() {
        guard let frame = target?.frame else { return }
        SettingsStore.shared.savedWindowSize = CGSize(width: frame.width.rounded(),
                                                      height: frame.height.rounded())
    }

    static func applySavedSize() {
        guard let size = SettingsStore.shared.savedWindowSize else { return }
        apply(size: size)
    }

    /// 改尺寸不动左上角，和拖右下角的行为一致。「应用默认窗口大小」和工程文件恢复
    /// 共用这一条：后者存的也是同一套「宽 × 高」。
    static func apply(size: CGSize) {
        guard let window = target else { return }
        var frame = window.frame
        let topEdge = frame.maxY
        frame.size = size
        frame.origin.y = topEdge - size.height
        window.setFrame(frame, display: true, animate: false)
    }
}

/// 主窗口一关就再也呼不回来。SwiftUI 的 WindowGroup 关掉即销毁，⌘1/2/3 到
/// 那时候只剩「换个模式」这件事可做，没有窗口可以印出来。这一条把关闭改写成藏起来。
/// 动的是关闭按钮本身：红按钮的 target 从窗口换成我们，动作变成 orderOut —— delegate
/// 一个字都不改（SwiftUI 那一份还要靠 windowDidBecomeKey 之类维护焦点与外观，换掉会
/// 让窗口看起来永远是失焦的）。⌘W 走的是菜单的 performClose，那条路由监听器截下来
/// （见 monitor 里的 swallowsUnboundSpace 旁边一段）。藏起来的窗口叫回来还是原来那一
/// 个：解码、通道条、播放头、窗口尺寸全在原处，不用重跑一遍启动。
enum MainWindow {
    private static weak var window: NSWindow?
    /// 关闭按钮的 target 是 weak，接单的那个小对象得由我们留着。
    private static var handler: CloseHandler?

    /// 由 ContentView 里的接线视图调上来（只有它拿得到承载自己的那扇窗口）。
    static func adopt(_ candidate: NSWindow?) {
        guard let candidate, let button = candidate.standardWindowButton(.closeButton) else { return }
        if button.target is CloseHandler { window = candidate; return }
        let handler = CloseHandler()
        handler.window = candidate
        button.target = handler
        button.action = #selector(CloseHandler.hideWindow(_:))
        Self.handler = handler
        window = candidate
    }

    /// ⌘1/2/3 和 Dock 图标都走这一条。窗口没被藏起来时它只是把它带到最前。
    static func show() {
        guard let window else { return }
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘W：和点红按钮同一个结果 —— 藏起来，不销毁。
    static func hide() {
        window?.orderOut(nil)
    }

    /// 接线有没有完成 —— ContentView 里那个视图跑过一次 adopt 就是 true。
    static var isWired: Bool { window != nil }

    #if DEBUG
    static var isHiddenForCheck: Bool { window != nil && window?.isVisible == false }
    /// 探针要自己按一次关闭，所以把窗口本体交出去 —— 只有 Debug 里有这一条。
    static var windowForCheck: NSWindow? { window }
    #endif

    final class CloseHandler: NSObject {
        weak var window: NSWindow?
        @objc func hideWindow(_ sender: Any?) { window?.orderOut(nil) }
    }
}

// MARK: - 关于面板

/// 面板的名字和版本号由 Info.plist 自己印，这里只挂下面几行。
/// 系统的「关于」面板支持一段 credits（放在窗口底部那块小字区），几行装得下，
/// 所以不必自建窗口。credits 是普通 NSAttributedString，不跟着外观变色，
/// 因此显式给 labelColor —— 否则在深色面板上是一坨黑字。
/// 排版本来居中，裁定改左对齐（三行长短差得多，居中看着是散的）；左对齐之后
/// 第二行放不下会自己折出孤字，所以「发布，」后面手动断成两行。
enum AboutPanel {
    private static let repoURL = "https://github.com/mio-furuhashi/ab-player"
    private static let lines = [
        "AB对比播放器，支持音频、视频。",
        "本程序为自由软件，在 GNU GPL v3 下发布，",
        "无任何保证。",
        "源码与构建方式：\(repoURL)",
    ]

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 2
        let text = lines.joined(separator: "\n")
        let credits = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        if let url = URL(string: repoURL) {
            credits.addAttribute(.link, value: url, range: (text as NSString).range(of: repoURL))
        }
        // 「版本 2.2.0 (1)」后面那对括号是 build 号（CFBundleVersion），裁定去掉：`.version`
        // 这一路喂的就是它，给空串。版本号仍从 Info.plist 现读，不在这儿写死。
        let release = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits,
                                                     .applicationVersion: release,
                                                     .version: ""])
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - AppDelegate for keyboard monitoring

class AppDelegate: NSObject, NSApplicationDelegate {
    var vm: PlayerViewModel?
    var monitor: Any?
    #if DEBUG
    /// AB_RESTORE_CHECK=1 那一档把「自动恢复上次会话」当作已开：偏好是用户自己的，
    /// 探针不该去拨它。Release 二进制里连这个字段都没有。
    private var restoreProbeForced = false
    /// AB_BATCH_CHECK 的账本：这一批要等去抖、等 sheet 站住，分好几拍才写完，
    /// 所以边跑边记，最后一拍一起落盘。
    private var batchReport: [String] = []
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ShortcutStore.shared        // migrate bindings saved by earlier builds
        // Debug-only scaffolding: the release binary never reads these.
#if DEBUG
        setupDebugAutoplay()
        // 走带栏的挤压顺序要在不同宽度下拍照，而这台机器注入不了鼠标拖窗口，
        // 所以开一扇「按指定尺寸摆主窗口」的后门（"1700x520"，可带 "@x,y" 定位）。
        if let spec = ProcessInfo.processInfo.environment["AB_WINDOW"],
           let size = Self.parseWindowSize(spec) {
            let place = Self.parseWindowPlace(spec)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let window = WindowDefaults.target else { return }
                var frame = window.frame
                let topEdge = frame.maxY
                frame.size = size
                frame.origin.y = topEdge - size.height
                window.setFrame(frame, display: true)
                if let place = place {
                    // AppKit 的 y 朝上，原点在主屏左下；CG 全局坐标正好反过来。
                    let top = (NSScreen.screens.first?.frame.maxY ?? 0) - place.y
                    window.setFrameTopLeftPoint(NSPoint(x: place.x, y: top))
                }
            }
        }
        if ProcessInfo.processInfo.environment["AB_MENUDUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.dumpMenusForCheck()
                self.exerciseWindowDefaultsForCheck()
                self.exerciseHistoryForCheck()
            }
        }
        // Its own switch: the loudness dialog is modal and would stall everything
        // scheduled behind it.
        if ProcessInfo.processInfo.environment["AB_LOUDNESS_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.exerciseLoudnessForCheck() }
        }
        // Its own switch as well: this one moves the playhead and the play state,
        // and it needs the tracks loaded before it has anything to seek.
        if ProcessInfo.processInfo.environment["AB_TRANSPORT_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseTransportForCheck() }
        }
        // 走带按钮的逐轨状态 + 空格/K 的基准，同样要等音轨解完才有东西可放。
        if ProcessInfo.processInfo.environment["AB_PLAYSTATE_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exercisePlayStateForCheck() }
        }
        // 预设那一格菜单的四条动作，单独一个开关（它要自己装插件、自己清盘）。
        if ProcessInfo.processInfo.environment["AB_PRESET_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exercisePresetsForCheck() }
        }
        // 双拓扑与 pre-gain 的电平验收，同样要等音轨解完才开始。
        if ProcessInfo.processInfo.environment["AB_CHAIN_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseChainForCheck() }
        }
        // 量声像到底在插件之前还是之后。
        if ProcessInfo.processInfo.environment["AB_ORDER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseOrderForCheck() }
        }
        // 声道抽头能不能就地改样本、电平表读数是否跟得上，单独一个开关，
        // 免得每次试声道都重跑一遍那六轮采样。
        if ProcessInfo.processInfo.environment["AB_LANE_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseLaneTapForCheck() }
        }
        // 插件有没有真的在算。同样要等音轨解完，因为它是靠输出采样说话。
        if ProcessInfo.processInfo.environment["AB_AU_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseAUForCheck() }
        }
        // 电平表闪烁：抽头 100 ms 才交付一包，表 20 Hz 去问，空手那一拍该保持还是该塌，
        // 只能这样抄表量出来。
        if ProcessInfo.processInfo.environment["AB_METER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseMeterForCheck() }
        }
        // 电平表慢 2 秒（正好是抽头队列从前封顶 400 窗 × 5 ms）的来路：这一支跑得久，
        // 要看着队列一点点攒满、换轨那一下又是怎么把旧的 2 秒画完的。
        // 要两首以上 --autoplay，才有轨可换。
        if ProcessInfo.processInfo.environment["AB_METERLAG_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseMeterLagForCheck() }
        }
        // 渲染导出算不算插件（靠读回文件的自相关说话）、裁切那条路还是不是
        // 原样搬样本、对话框的状态机跟不跟着选项走。
        if ProcessInfo.processInfo.environment["AB_EXPORT_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseExportForCheck() }
        }
        // 参数写得进去吗（靠输出采样）、fullState 带不带得走（撤销/[A→B]）、
        // 原生界面取不取得到、浮窗跟不跟得上槽位变化。
        if ProcessInfo.processInfo.environment["AB_EDITOR_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseEditorForCheck() }
        }
        // 橡皮擦指针「不显示，但 ⌘+点仍能擦」：这条链上能量化的只有矩形和计数器，
        // 外加一张带光标的全屏截图（screencapture -C 会把指针画进去）。
        if ProcessInfo.processInfo.environment["AB_ERASER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseEraserCursorForCheck() }
        }
        // 推子的 ⌃+滚轮微调：不碰音频、不等装载，两枚视图各喊一次 scrollWheel 就完。
        // 之后同一支探针跑鼠标和触控板两种指针。
        if ProcessInfo.processInfo.environment["AB_FADER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.exerciseFaderScrollForCheck() }
        }
        // 波形图的触控板那一套：双指左右 = 平移、竖向不翻页、⌥⌘/⌘ 两种指针同向。
        if ProcessInfo.processInfo.environment["AB_POINTER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.exercisePointerWaveformForCheck() }
        }
        // 头一次进编辑模式自动开混音器：只要模式开关和面板可见性，两秒就够。
        if ProcessInfo.processInfo.environment["AB_MIXEROPEN_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.exerciseMixerAutoOpenForCheck() }
        }
        // 工程文件与轨道预设。NSSavePanel/NSOpenPanel 是模态的，
        // 探针碰不得，所以存取直接把路径交给落盘那一步；⌘S 走菜单那一级的
        // performKeyEquivalent，那一刻工程已经有路径，不会弹出面板。
        if ProcessInfo.processInfo.environment["AB_PROJECT_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseProjectForCheck() }
        }
        // 配套的另一半：这一支不带 --autoplay 启动，专看「下次打开直接恢复」那一条。
        // 之后这一条挪进了设置、默认关着，所以 =1 那一档把开关当作已开（不去动
        // 用户盘上那条偏好），=off 那一档才照默认走 —— 两档各验一半。
        if let mode = ProcessInfo.processInfo.environment["AB_RESTORE_CHECK"] {
            restoreProbeForced = mode != "off"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.exerciseRestoreForCheck(offRound: mode == "off")
            }
        }
        // 插件槽拖拽调序：手势要靠真鼠标，探针只验松手那一步的六条走法。
        if ProcessInfo.processInfo.environment["AB_SLOTORDER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseSlotOrderForCheck() }
        }
        // 主窗口关掉之后还能不能呼回来。它要改窗口可见性，单独一个开关。
        if ProcessInfo.processInfo.environment["AB_WINDOW_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.exerciseWindowForCheck() }
        }
        // 混音器推子刻度：白色高亮到底落在哪一格，把刻度列拍成位图逐行量（AB_TICK_CHECK）。
        // 不开混音器窗口也能量，画的是同一个 draw()。
        if ProcessInfo.processInfo.environment["AB_TICK_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.exerciseTicksForCheck() }
        }
        // ffmpeg 解码缓存。素材由 AB_CACHE_FILE="a|b|c" 递进来
        // （都得是系统读不了的容器），同一批文件还要用 --autoplay 先装载 —— 不装载就只能
        // 量机械账，量不到「这一轨真的响了、波形真的画出来了」。
        if ProcessInfo.processInfo.environment["AB_CACHE_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseCacheForCheck() }
        }
        // time trim 是参数式的偏移，能量数字的四件事（刻度、沉降、
        // 空白里播放头怎么走、撤销）都由这一支探针记账。
        if ProcessInfo.processInfo.environment["AB_TRIM_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseTrimForCheck() }
        }
        // 裁切导出的三种反馈（全成只提示音 / AV 回落那一句 / 逐轨成败那个窗口）。
        // 菜单那两条第一步弹的是选目录面板，这台机器注不进鼠标，所以走「选完目录」那一步。
        if let which = ProcessInfo.processInfo.environment["AB_TRIM_FEEDBACK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseTrimFeedbackForCheck(which) }
        }
        // 章节自动转标记。素材是两份带章节的 m4a（路径从 AB_CHAPTER_FILES 递进来，
        // 中间一根竖线分开），没给就只留一行「跳过」。它一路要装载、要等空闲、要按撤销，
        // 所以自己一个开关、自己一条时间线。
        if ProcessInfo.processInfo.environment["AB_CHAPTER_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseChaptersForCheck() }
        }
        // 播放头跟随动画：τ 改小之后要一个真数字，只能让波形视图自己掐表。
        if WaveformNSView.followCheckPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseFollowForCheck() }
        }
        // 播放头帧率：跟随 + 8× 缩放播 6 秒，每秒一行「几帧 / 每帧几毫秒 / 播放头几次」。
        if WaveformNSView.perfPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exercisePlayheadPerfForCheck() }
        }
        // Raise a panel by itself, since no click or keystroke can reach this app.
        if let panel = ProcessInfo.processInfo.environment["AB_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.openPanelForCheck(panel) }
        }
        // 两轨纯音频按 ⌘6 闪退：崩溃报告死在 AppKit 拖边改框那一路，而这一路只有真指针进得来
        // （这台机器注不进鼠标），所以这一支先把视频窗口的窗口账整个抄下来，再用
        // `beginLiveResize` 那条公开的路走一遍同一条链子，看它回不回得来。
        if ProcessInfo.processInfo.environment["AB_VIDEOSTATE_CHECK"] != nil {
            let delay = Double(ProcessInfo.processInfo.environment["AB_VIDEOSTATE_DELAY"] ?? "") ?? 5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.exerciseVideoStateForCheck() }
        }
        // 调序的账、P/H/⌃H 三把新键、模式2 的空格、增益读数、列表宽度、
        // 帮助文案，一支探针按顺序跑完（要等音轨解完，所以排在 6 秒那一拍）。
        if ProcessInfo.processInfo.environment["AB_BATCH_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.exerciseBatchForCheck() }
        }
#endif
        // 「下次打开直接恢复」：只认上一次 ⌘S 存过的那一份工程。命令行里递了
        // 音频文件时不抢 —— 那是明确要开的东西，探针也靠这一条保住原来的基线。
        // 延后一拍：窗口和主线程那会儿才刚站住，恢复要做的事不少（解码、接线、改尺寸）。
        var restoreOnLaunch = SettingsStore.shared.autoRestoreSession
#if DEBUG
        restoreOnLaunch = restoreOnLaunch || restoreProbeForced
#endif
        if !Self.launchedWithAudioFiles(), restoreOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.vm?.restoreLastProjectAtLaunch()
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, let vm = self.vm else { return event }
            #if DEBUG
            // AB_KEYLOG：真按键的四个字段原样记账。放在所有分支之前，所以被谁吃掉、
            // 没被吃掉都记得到。
            if event.type == .keyDown { self.logKeyForCheck(event) }
            #endif
            // 插槽上的橡皮擦指针要认得出「⌘ 刚刚按下、鼠标没动」这一下。
            if event.type == .flagsChanged {
                CommandKeys.flagsChanged(event)
                return event
            }
            // Block only while a modal sheet/dialog is key; the floating info
            // panel must not stop the player hotkeys (Finder-inspector style).
            // 插件浮窗同理：V 收放全部页面、⌘4 退模式都得从它上面按出来。
            // 视频窗口也在这张名单上：它是 utility panel，键在它上面的时候播放、
            // 换轨（F）和 ⌘6 本身都得照样应答。
            let kw = NSApp.keyWindow
            if kw != NSApp.mainWindow,
               !InfoPanelController.shared.owns(kw),
               !MixerPanelController.shared.owns(kw),
               !VideoPanelController.shared.owns(kw),
               !PluginEditorController.shared.owns(kw) { return event }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let sc = ShortcutStore.shared

            // Tab 在这里没有任何实际用途：它只是在按钮之间循环焦点、留下一圈高亮
            // 外框，所以整下收掉。文本框里的 Tab 留给 AppKit 换焦点，带修饰键的
            // 也一律放行，别把 ⌥⇥ 之类的输入行为一起挡了。
            if event.keyCode == 48,
               event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
               !(kw?.firstResponder is NSText) { return nil }

            // Command combos: only the two we bind, everything else passes through
            if event.modifierFlags.contains(.command) {
                // ⌘W：菜单那一条走的是 performClose，会把窗口真销毁，所以从主窗口还 key
                // 的时候截下来，改成藏起来。红按钮已经在 MainWindow.adopt 里
                // 换了接单对象，两条路同一个结果。浮窗 key 的时候不动它 —— 那一下是关面板。
                if event.keyCode == 13, kw == NSApp.mainWindow,
                   event.modifierFlags.intersection([.option, .control, .shift]).isEmpty {
                    MainWindow.hide(); return nil
                }
                switch key {
                case sc.key(for: .copyToBackupList): vm.copySelectedToBackup(); return nil
                case sc.key(for: .clearRanges): vm.clearAllRanges(); return nil
                // ⌘F：查找插件，插进活动轨从上往下第一个空槽（Logic 同款）。输入框
                // 正拿着键盘时不算，那时候 ⌘F 是用户的文本操作。
                case "f": if vm.editMode, !(kw?.firstResponder is NSText) {
                              vm.openPluginSearch(); return nil
                          }
                          return event
                default: break
                }
                // Recorded ⌘ bindings (⌘/, ⌘J) sit in the same table as the rest, and
                // ⌃⌘ narrows the transport rows the way ⌃ alone does.
                if dispatch(event, vm: vm) { return nil }
                return event
            }

            // A focused text field (timecode entry, gain readout, playlist rename)
            // owns the keyboard until it is committed.
            if kw?.firstResponder is NSText { return event }

            if dispatch(event, vm: vm) { return nil }

            // 空格查表没命中，就是这一按没绑给任何人（多半是 ⇧空格）。这时候不能把它交还
            // 给系统 —— 交还回去，AppKit 把它送给当前聚焦的控件：焦点在走带按钮上就白按
            // 一下，焦点在播放列表上 ⇧空格会扩展选区，选中一条没载曲的条目，波形图当场
            // 空掉。带 ⌃⌥ 的空格是切输入法的（⌃空格、⌥空格），一律放行。
            if Self.swallowsUnboundSpace(event.keyCode, event.modifierFlags) { return nil }

            // Backtick has no ShortcutAction of its own.
            if key == "`" { vm.addGlobalMarkerAtCurrentPosition(); return nil }
            // Z 复位视图 is hardcoded too, and only outside ABX — there, z confirms
            // the round's answer and the table above has already taken the press.
            if key == "z", !event.modifierFlags.contains(.shift), vm.compareMode != .abx {
                vm.resetWaveformView(); return nil
            }
            // 硬编码的插槽键（1…6 / ⇧1…⇧6 / V）。抽成方法是为了让探针能按同一把入口验它，
            // 而不是另抄一遍规则。
            if slotKey(event, vm: vm) { return nil }
            return event
        }
    }

    /// 1…6 开 A 轨那一格，⇧1…⇧6 开 B 轨那一格，V 收放全部页面。
    /// 数字认 keyCode，不认 characters：⇧+1 送进来的 charactersIgnoringModifiers 是 "!"
    /// （中文输入法下更是全角），`wholeNumberValue` 读成 nil，那一按就什么都不是 —— 用户
    /// 报的「⇧1…⇧6 打不开 B 轨窗口」正是旧写法踩的这条。V 继续认字符：它不带 ⇧，键盘上
    /// 印着哪个键就该按哪个键。修饰键的规矩照旧 —— 数字不吃 ⌥（⌥1 不放）也不吃 ⌃（那一档
    /// 要给走带栏的 J/K/L 收窄留路），V 不吃 ⌥ 和 ⇧。返回 true 表示这一下已经吃掉。
    static let slotDigitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6]

    @discardableResult
    func slotKey(_ event: NSEvent, vm: PlayerViewModel) -> Bool {
        guard vm.editMode else { return false }
        let mods = event.modifierFlags
        if let digit = Self.slotDigitKeyCodes[event.keyCode],
           !mods.contains(.option), !mods.contains(.control) {
            vm.toggleSlotEditor(digit - 1, for: mods.contains(.shift) ? .b : .a)
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "v", !mods.contains(.option), !mods.contains(.shift) {
            vm.toggleAllPluginPages()
            return true
        }
        return false
    }

    /// 查表落空后的空格规则：裸空格和 ⇧空格收掉，别的修饰键组合交还给系统。
    /// ⌃空格、⌥空格是切换输入法的，收到应用里就把用户的输入法开关给拆了。抽成方法是为了
    /// 让探针按同一把入口验它，和 slotKey 一个道理。
    static func swallowsUnboundSpace(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 49 && modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// 启动时有没有直接把音频文件递给播放器。Release 里恒为 false（只有 Debug 的
    /// `--autoplay` 后门会这样带路径），留着它是因为工程的自动恢复不能抢用户明确要开的曲子。
    /// 定义在 `#if DEBUG` 那一大段之外：启动恢复是产品行为，Release 也要问这一句。
    static func launchedWithAudioFiles() -> Bool {
#if DEBUG
        CommandLine.arguments.contains("--autoplay")
#else
        false
#endif
    }

    // MARK: Diagnostics
    //
    // Kept in the source because they are the only way to check this app without a
    // keyboard or a mouse, but compiled out of the release build: a shipping binary
    // carries no code that reads AB_* environment variables.

    /// Diagnostic: drive the transport presses from inside the app. This machine
    /// drops every synthetic keystroke for want of Accessibility permission, so a
    /// press can only be proved by handing the monitor's own lookup the key data a
    /// real one carries — a control+letter arrives as the control character itself
    /// (⌃J is 0x0A, ⌃K is 0x0B, ⌃L is 0x0C), which is exactly the input the ⌃
    /// fallback reads.
    ///
    /// It leaves both lanes parked and back at the spot it started from.
#if DEBUG
    private func exerciseTransportForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        // Decoding these two tracks takes half a minute on this machine, and there
        // is nothing to seek until it is done.
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("TRANSPORT: 音轨未在 60s 内就绪，跳过\n", suffix: ".keys")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseTransportForCheck(remaining: remaining - 1)
            }
            return
        }
        func f(_ t: TimeInterval) -> String { String(format: "%5.1f", t) }
        func flag(_ playing: Bool) -> String { playing ? "▶" : "⏸" }
        let kJ = UInt16(38), kK = UInt16(40), kL = UInt16(37), kZ = UInt16(6)
        let none: NSEvent.ModifierFlags = []
        let ctrl: NSEvent.ModifierFlags = [.control]
        let cmd: NSEvent.ModifierFlags = [.command]
        let cmdCtrl: NSEvent.ModifierFlags = [.command, .control]
        let ctrlShift: NSEvent.ModifierFlags = [.control, .shift]

        vm.pause()
        vm.compareMode = .reference
        vm.setActiveTrack(.a)
        vm.seekSide(.a, to: 60)
        vm.seekSide(.b, to: 60)
        var lines: [String] = ["参考曲 起点 A=\(f(vm.position(of: .a))) B=\(f(vm.position(of: .b)))"]

        func step(_ label: String, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) {
            let a0 = vm.position(of: .a), b0 = vm.position(of: .b)
            let hit = drive(keyCode: code, modifiers: mods,
                            charactersIgnoringModifiers: chars, vm: vm)
            lines.append("\(label): consumed=\(hit) A \(f(a0))→\(f(vm.position(of: .a))) "
                         + "B \(f(b0))→\(f(vm.position(of: .b)))")
        }

        step("J    ", kJ, "j", none)
        step("⌃J   ", kJ, "\n", ctrl)
        step("⌘J   ", kJ, "j", cmd)
        step("⌃⌘J  ", kJ, "\n", cmdCtrl)
        step("⌃⇧L  ", kL, "\u{0C}", ctrlShift)
        step("⌘L   ", kL, "l", cmd)
        // The guard rail: a stray ⌃ must not borrow a binding that isn't transport.
        step("⌃⌘Z  ", kZ, "\u{1A}", cmdCtrl)
        // K moves the play state rather than the playhead, so it goes last.
        step("⌃K   ", kK, "\u{0B}", ctrl)
        lines.append("⌃K 之后 A=\(flag(AudioEngine.shared.isPlaying(.a))) "
                     + "B=\(flag(AudioEngine.shared.isPlaying(.b)))")
        step("⌃⌘K  ", kK, "\u{0B}", cmdCtrl)
        lines.append("⌃⌘K 之后 A=\(flag(AudioEngine.shared.isPlaying(.a))) "
                     + "B=\(flag(AudioEngine.shared.isPlaying(.b)))")
        // 混音器从裸 x 搬到 ⌘5（早前一轮 UI 改的）：x 只留给 ABX，编辑模式里
        // 也不该再开窗口；⌘5 才是要验的那一条。查表按 allCases 走，不在盲听时
        // .abxSwitchX 返回 false，drive() 换下一个候选。
        let kX = UInt16(7), k5 = UInt16(23)
        step("x 非编辑", kX, "x", none)
        lines.append("混音器窗口=\(MixerPanelController.shared.isVisible)")
        vm.setEditMode(true)
        step("x 编辑中", kX, "x", none)
        lines.append("按过 x 之后混音器窗口=\(MixerPanelController.shared.isVisible)")
        step("⌘5     ", k5, "5", cmd)
        lines.append("混音器窗口=\(MixerPanelController.shared.isVisible)")
        step("⌘5 再按", k5, "5", cmd)
        lines.append("混音器窗口=\(MixerPanelController.shared.isVisible)")
        vm.setEditMode(false)
        lines.append("退出编辑后混音器窗口=\(MixerPanelController.shared.isVisible)")
        // 裸 / 只跳当前选中轨，⌘/ 两轨一起跳。1.x 本来就有前一条，
        // ⌘/ 迁移把它并进了后一条就丢了，所以两把键要各拍各的。
        let kSlash = UInt16(78)
        func timecode(_ label: String, _ mods: NSEvent.ModifierFlags) -> String {
            vm.pause()
            vm.seekSide(.a, to: 60); vm.seekSide(.b, to: 60)
            let a0 = vm.position(of: .a), b0 = vm.position(of: .b)
            let hit = drive(keyCode: kSlash, modifiers: mods, charactersIgnoringModifiers: "/", vm: vm)
            vm.commitTimecode("1 20")
            return "\(label) 吃掉=\(hit) A \(f(a0))→\(f(vm.position(of: .a))) "
                   + "B \(f(b0))→\(f(vm.position(of: .b)))"
        }
        vm.compareMode = .reference
        vm.setActiveTrack(.a)
        lines.append(timecode("/  选中A ", none))
        vm.setActiveTrack(.b)
        lines.append(timecode("/  选中B ", none))
        vm.setActiveTrack(.a)
        lines.append(timecode("⌘/      ", cmd))
        vm.pause()
        vm.seekSide(.a, to: 60)
        vm.seekSide(.b, to: 60)
        lines.append("收尾 A=\(f(vm.position(of: .a))) B=\(f(vm.position(of: .b))) isPlaying=\(vm.isPlaying)")
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".keys")
    }

    /// Diagnostic: 走带按钮与空格/K 的状态机。这台机器注不进真按键，
    /// 所以空格那一下只能走监听器自己的两个入口：查表 drive()，加上收键谓词
    /// swallowsUnboundSpace。每一行都同时记「两条腿各自的播放状态」和「按钮读到的那个
    /// 值」—— 用户报的就是这两者不一致。整段在一个 runloop turn 里跑完，20 Hz 那拍
    /// 插不进来，读数才是按键当场的效果。收尾把两条腿停回 60 秒。
    private func exercisePlayStateForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("PLAY: 音轨未在 60s 内就绪，跳过\n", suffix: ".play")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exercisePlayStateForCheck(remaining: remaining - 1)
            }
            return
        }
        let kSpace = UInt16(49), kK = UInt16(40)
        let none: NSEvent.ModifierFlags = []
        let ctrl: NSEvent.ModifierFlags = [.control]
        let shift: NSEvent.ModifierFlags = [.shift]
        let option: NSEvent.ModifierFlags = [.option]
        func f(_ t: TimeInterval) -> String { String(format: "%5.1f", t) }
        func mark() -> String {
            "A=\(vm.sideIsPlaying(.a) ? "▶" : "⏸") B=\(vm.sideIsPlaying(.b) ? "▶" : "⏸") "
            + "按钮\(vm.activeTrack.rawValue)=\(vm.sideIsPlaying(vm.activeTrack) ? "▶" : "⏸") "
            + "取或=\(vm.isPlaying ? "▶" : "⏸")"
        }
        /// 走监听器那条路：先查表，没命中再看收键规则，两边都没吃掉才是交还系统。
        func press(_ label: String, _ code: UInt16, _ chars: String,
                   _ mods: NSEvent.ModifierFlags) -> String {
            let before = mark()
            let hit = drive(keyCode: code, modifiers: mods,
                            charactersIgnoringModifiers: chars, vm: vm)
            let swallowed = !hit && Self.swallowsUnboundSpace(code, mods)
            return "\(label) 吃掉=\(hit || swallowed) | \(before) ⇒ \(mark())"
        }

        var lines: [String] = []
        vm.setEditMode(false)
        vm.pause()
        vm.compareMode = .versionCompare
        vm.setActiveTrack(.a)
        vm.seekSide(.a, to: 60)
        vm.seekSide(.b, to: 60)
        lines.append("版本对比 起点 A=\(f(vm.position(of: .a))) B=\(f(vm.position(of: .b))) \(mark())")
        lines.append(press("空格    ", kSpace, " ", none))
        lines.append(press("空格    ", kSpace, " ", none))
        lines.append(press("K 选A   ", kK, "k", none))

        // 两条腿分岔：参考曲里只放 A，再把选中轨换成停着的 B。旧写法在这里读的是取或，
        // 按钮显示 ▶、按空格白按 —— 那正是反馈里说的状态指示不动。
        vm.pause()
        vm.compareMode = .reference
        vm.setActiveTrack(.a)
        vm.toggleSide(.a)
        lines.append("参考曲 只放A \(mark())")
        vm.setActiveTrack(.b)
        lines.append("切到停着的B \(mark())")
        lines.append(press("空格    ", kSpace, " ", none))
        lines.append(press("K 选B在放", kK, "k", none))
        // K 的基准：选中轨停着、另一轨还在放，这一按要把两条腿一起放起来。
        vm.pause()
        vm.setActiveTrack(.a)
        vm.toggleSide(.a)
        vm.setActiveTrack(.b)
        lines.append("A放B停 选B \(mark())")
        lines.append(press("K       ", kK, "k", none))
        lines.append(press("⌃K      ", kK, "\u{0B}", ctrl))
        // ⇧空格收在应用里、不交还给系统；⌃/⌥空格是切输入法的路，放行。
        let p0 = vm.position(of: .a), sel0 = vm.selectedTrackIndex, r0 = vm.rangeA
        lines.append(press("⇧空格   ", kSpace, " ", shift))
        lines.append(press("⌥空格   ", kSpace, " ", option))
        lines.append("⇧/⌥空格之后 位置=\(f(p0))→\(f(vm.position(of: .a))) "
                     + "选中=\(sel0.map(String.init) ?? "nil")→\(vm.selectedTrackIndex.map(String.init) ?? "nil") "
                     + "范围A=\(r0 == nil ? "nil" : "有")/\(vm.rangeA == nil ? "nil" : "有") \(mark())")

        vm.pause()
        vm.compareMode = .versionCompare
        vm.seekSide(.a, to: 60)
        vm.seekSide(.b, to: 60)
        lines.append("收尾 A=\(f(vm.position(of: .a))) B=\(f(vm.position(of: .b))) \(mark())")
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".play")
    }

    // MARK: 探针（AB_BATCH_CHECK）
    //
    // 这一轮六条规格里，没有真鼠标也能验的都收在这一支里：调序的账（映射表、主列表、备用
    // 列表、一步撤销、备用列表落盘）、P / H / ⌃H 三把新键 + 模式2 的空格（连带「⌃空格必须
    // 放行给系统」「⌃退格不能撞成 ⌃H」两条）、增益读数在 0 那一档到底印成什么、列表栏宽度
    // 记不记得住、帮助页有没有那几句。
    // ⌘ 拖拽本身验不了：这台机器注不进鼠标，只能验到「⌘ 有没有传到 SwiftUI 那一边」，
    // 拖起来的手感、跟手的行、让位的动画要人亲手拖一次才量得准。
    private func exerciseBatchForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("BATCH: 音轨未在 60s 内就绪，跳过\n", suffix: ".batch")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseBatchForCheck(remaining: remaining - 1)
            }
            return
        }
        batchReport = []
        batchReorderCheck()
        batchCommandKeyCheck()
        batchShortcutTableCheck()
        batchKeysCheck()
        batchReadoutCheck()
        // 宽度那一格要等 0.4 秒的去抖，帮助那一格要等 sheet 站住，只能排到后面几拍。
        batchWidthCheck(stage: 0)
    }

    /// 一行假曲目，只用来当被调序的对象（不装载、不进引擎）。
    private func batchRow(_ name: String) -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/\(name).wav"))
        track.displayName = name
        return track
    }

    private func batchOrderName(_ tracks: [Track]) -> String {
        tracks.map { $0.displayName }.joined(separator: " ")
    }

    private func batchIndexes(_ set: Set<Int>) -> String {
        set.sorted().map(String.init).joined(separator: ",")
    }

    private func batchIndexText(_ index: Int?) -> String {
        index.map(String.init) ?? "nil"
    }

    private func writeBatchReport() {
        let text = batchReport.joined(separator: "\n") + "\n"
        writeDiag(text, suffix: ".batch")
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }

    private func batchReorderCheck() {
        guard let vm else { return }
        // 探针把真曲目换成假的，跑完原样摆回去；备用列表那一份顺带落盘一次，
        // 所以「摆回去」也就是把磁盘上那份复原。
        let savedTracks = vm.tracks, savedBackup = vm.backupTracks
        let savedMain = vm.selectedTrackIndex, savedMainMulti = vm.mainMulti
        let savedBack = vm.backupSelectedIndex, savedBackMulti = vm.backupMulti
        defer {
            vm.tracks = savedTracks
            vm.selectedTrackIndex = savedMain
            vm.mainMulti = savedMainMulti
            vm.backupTracks = savedBackup
            vm.backupSelectedIndex = savedBack
            vm.backupMulti = savedBackMulti
            vm.clearEditHistory()   // 探针记的那几步不该留在用户按 ⌘Z 的路上
        }
        // 纯映射：「原来第 i 行现在第几行」整行列出来，四个方向各一行。
        func mapRow(_ count: Int, _ source: Int, _ destination: Int) -> String {
            (0..<count).map { String(PlayerViewModel.remappedIndex($0, from: source, to: destination)) }
                .joined(separator: ",")
        }
        let table: [(String, String, String)] = [
            ("0→2", mapRow(4, 0, 2), "2,0,1,3"),
            ("2→0", mapRow(4, 2, 0), "1,2,0,3"),
            ("0→3", mapRow(4, 0, 3), "3,0,1,2"),
            ("3→1", mapRow(4, 3, 1), "0,2,3,1"),
            ("1→1", mapRow(4, 1, 1), "0,1,2,3"),
        ]
        batchReport.append("调序表 " + table.map {
            "\($0.0):[\($0.1)]\($0.1 == $0.2 ? "" : "≠期望\($0.2)")"
        }.joined(separator: " ") + " 判定=\(table.allSatisfy { $0.1 == $0.2 } ? "对" : "错")")

        // 主列表：顺序、单选、多选、一步撤销。
        vm.tracks = ["甲", "乙", "丙", "丁"].map { batchRow($0) }
        vm.selectedTrackIndex = 0
        vm.mainMulti = [0, 3]
        let main0 = batchOrderName(vm.tracks)
        vm.reorderTrack(from: 0, to: 2, isMain: true)
        batchReport.append("主列表 0→2 「\(main0)」⇒「\(batchOrderName(vm.tracks))」(期望 乙 丙 甲 丁)"
            + " 选中=\(batchIndexText(vm.selectedTrackIndex))(期望2)"
            + " 多选=\(batchIndexes(vm.mainMulti))(期望2,3) 可撤销=\(vm.canUndo)")
        vm.undoEdit()
        batchReport.append("主列表 一步撤销 ⇒「\(batchOrderName(vm.tracks))」回到原样=\(batchOrderName(vm.tracks) == main0)")

        // 越界不动，也不许多记一步撤销（撤销历史里冒泡是最难查的那种脏）。
        let guardBefore = batchOrderName(vm.tracks)
        vm.reorderTrack(from: 0, to: 4, isMain: true)
        vm.reorderTrack(from: 3, to: -1, isMain: true)
        vm.reorderTrack(from: 1, to: 1, isMain: true)
        batchReport.append("越界 0→4 / 3→-1 / 1→1 顺序不动=\(batchOrderName(vm.tracks) == guardBefore)"
            + " 没多出撤销步=\(!vm.canUndo)")

        // 备用列表：同一套账，外加「顺序随列表自动存盘」这一条。
        vm.backupTracks = ["A", "B", "C"].map { batchRow($0) }
        vm.backupSelectedIndex = 2
        vm.backupMulti = [0, 2]
        vm.reorderTrack(from: 2, to: 0, isMain: false)
        let backup1 = batchOrderName(vm.backupTracks)
        let disk = batchOrderName(BackupListStore.shared.load())
        batchReport.append("备用列表 2→0 ⇒「\(backup1)」(期望 C A B)"
            + " 选中=\(batchIndexText(vm.backupSelectedIndex))(期望0)"
            + " 多选=\(batchIndexes(vm.backupMulti))(期望0,1)"
            + " 落盘读回「\(disk)」一致=\(disk == backup1)")
        vm.undoEdit()
        batchReport.append("备用列表 一步撤销 ⇒「\(batchOrderName(vm.backupTracks))」回到原样"
            + "=\(batchOrderName(vm.backupTracks) == "A B C")")
    }

    /// ⌘ 有没有传到 SwiftUI 那一边：拖拽的上膛、抓手的摆放都读这一个状态。事件由
    /// CGEvent 现造再翻成 NSEvent —— 这台机器 post 不出去，只能直接喂给同一个入口。
    private func batchCommandKeyCheck() {
        func flagsEvent(_ mods: NSEvent.ModifierFlags) -> NSEvent? {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true) else { return nil }
            event.flags = CGEventFlags(rawValue: UInt64(mods.rawValue))
            event.type = .flagsChanged
            return NSEvent(cgEvent: event)
        }
        var held: [String] = []
        if let pressed = flagsEvent([.command]), let released = flagsEvent([]) {
            CommandKeys.flagsChanged(pressed)
            held.append(CommandState.shared.held ? "按下=1" : "按下=0")
            CommandKeys.flagsChanged(released)
            held.append(CommandState.shared.held ? "松开=1" : "松开=0")
        } else {
            held = ["造不出事件"]
        }
        batchReport.append("⌘状态 \(held.joined(separator: " ")) 判定=\(held == ["按下=1", "松开=0"] ? "对" : "错")")
    }

    /// 新键在册、每条在设置面板里恰好出现一次、整张表没有撞键。
    private func batchShortcutTableCheck() {
        let store = ShortcutStore.shared
        let pairs: [ShortcutAction] = [.playPause, .stopAll, .stopCurrentLane, .syncPlayPause, .togglePlaylist]
        batchReport.append("在册 " + pairs.map { "\($0.rawValue)=\(store.key(for: $0))" }.joined(separator: " | "))
        let all = ShortcutAction.allCases
        let listed = ShortcutAction.settingsSections.flatMap { $0.actions }
        batchReport.append("分区 全部\(all.count)条 表里\(listed.count)条"
            + " 漏=\(all.filter { !listed.contains($0) }.map { $0.rawValue })"
            + " 重=\(Set(listed).count == listed.count ? "无" : "\(listed.count - Set(listed).count)条")")
        var seen: [String: [ShortcutAction]] = [:]
        for action in all { seen[store.key(for: action), default: []].append(action) }
        let clashes = seen.filter { $0.value.count > 1 && $0.key != ShortcutStore.returnKey }
        batchReport.append("撞键 " + (clashes.isEmpty ? "无"
            : clashes.sorted { $0.key < $1.key }
                .map { "\($0.key)→\($0.value.map { $0.rawValue }.joined(separator: "/"))" }
                .joined(separator: " ")))
    }

    private func batchKeysCheck() {
        guard let vm else { return }
        let kP: UInt16 = 35, kH: UInt16 = 4, kSpace: UInt16 = 49, kDelete: UInt16 = 51
        let none: NSEvent.ModifierFlags = []
        let ctrl: NSEvent.ModifierFlags = [.control]
        let mode0 = vm.compareMode
        defer { vm.pause(); vm.compareMode = mode0 }
        func state() -> String {
            "A=\(vm.sideIsPlaying(.a) ? "▶" : "⏸")@\(String(format: "%.2f", vm.position(of: .a))) "
                + "B=\(vm.sideIsPlaying(.b) ? "▶" : "⏸")@\(String(format: "%.2f", vm.position(of: .b)))"
                + " 主动轨\(vm.activeTrack.rawValue)"
        }
        func press(_ label: String, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) -> String {
            let before = state()
            let hit = drive(keyCode: code, modifiers: mods, charactersIgnoringModifiers: chars, vm: vm)
            return "\(label) 吃掉=\(hit) | \(before) ⇒ \(state())"
        }
        // P：列表栏开关，两下回原位。
        let sidebar0 = vm.showPlaylistSidebar
        let first = drive(keyCode: kP, modifiers: none, charactersIgnoringModifiers: "p", vm: vm)
        let flipped = vm.showPlaylistSidebar
        let second = drive(keyCode: kP, modifiers: none, charactersIgnoringModifiers: "p", vm: vm)
        batchReport.append("P 两下都吃掉=\(first && second) 翻开变了=\(flipped != sidebar0) 复原=\(vm.showPlaylistSidebar == sidebar0)")

        vm.setEditMode(false)
        vm.pause()
        vm.compareMode = .reference
        // 模式2 的空格：基准是选中轨，动作落两轨。旧写法只管选中那一轨，所以
        // 「A 在放、选中停着的 B、按空格」这一枪才是分水岭 —— 两轨该一起起来。
        vm.seekSide(.a, to: 1.0)
        vm.seekSide(.b, to: 1.0)
        vm.setActiveTrack(.a)
        vm.toggleSide(.a)
        batchReport.append("模式2 起手 只放A \(state())")
        vm.setActiveTrack(.b)
        batchReport.append(press("空格(选停着的B) ", kSpace, " ", none))
        batchReport.append(press("空格(两轨在放)  ", kSpace, " ", none))
        batchReport.append(press("⌃空格(必须放行) ", kSpace, " ", ctrl))

        // H：两轨都停并回到开头。
        vm.seekSide(.a, to: 1.0)
        vm.seekSide(.b, to: 1.0)
        vm.toggleSide(.a)
        vm.toggleSide(.b)
        batchReport.append("模式2 两轨在放 \(state())")
        batchReport.append(press("H              ", kH, "h", none))

        // ⌃H：只停主动轨并把它拉回开头，另一轨照放。真按键送来的是控制字符，表里查的
        // 就是这一份；字母那份一并查，两条都该落在同一个动作上。
        vm.seekSide(.a, to: 1.0)
        vm.seekSide(.b, to: 1.0)
        vm.setActiveTrack(.a)
        vm.toggleSide(.a)
        vm.toggleSide(.b)
        vm.setActiveTrack(.b)
        batchReport.append("模式2 选B在放 \(state())")
        batchReport.append(press("⌃H(控制字符形)  ", kH, "\u{8}", ctrl))
        let controlForm = ShortcutStore.shared.action(forPressWithKeyCode: kH, modifiers: ctrl,
                                                      charactersIgnoringModifiers: "\u{8}")
        let letterForm = ShortcutStore.shared.action(forPressWithKeyCode: kH, modifiers: ctrl,
                                                     charactersIgnoringModifiers: "h")
        let deleteForm = ShortcutStore.shared.action(forPressWithKeyCode: kDelete, modifiers: ctrl,
                                                     charactersIgnoringModifiers: "\u{8}")
        batchReport.append("查表 ⌃H 控制字符形=\(controlForm?.rawValue ?? "nil")"
            + " 字母形=\(letterForm?.rawValue ?? "nil")"
            + " 同一条=\(controlForm == letterForm && controlForm == .stopCurrentLane)"
            + " ⌃退格=\(deleteForm?.rawValue ?? "nil")(期望nil)")

        // 模式1：两轨始终同步，⌃H 落到 stopAll 的兜底。
        vm.pause()
        vm.compareMode = .versionCompare
        vm.seekSide(.a, to: 1.0)
        vm.seekSide(.b, to: 1.0)
        vm.toggleSide(.a)
        batchReport.append("模式1 起手 \(state())")
        batchReport.append(press("⌃H(模式1)      ", kH, "\u{8}", ctrl))
    }

    /// 读数到底印成什么：把 GainReadout 挂进主窗口（屏幕外一格）画成 PDF，再用 PDFKit
    /// 把字取出来 —— 光看源码看不出「0 那一档有没有真去掉 ±」。
    private func batchReadoutCheck() {
        func readout(_ db: Double) -> String {
            let host = NSHostingView(rootView: GainReadout(db: .constant(db), fontSize: 11))
            host.frame = NSRect(x: -200, y: 0, width: 120, height: 24)
            guard let window = MainWindow.windowForCheck ?? NSApp.mainWindow,
                  let content = window.contentView else { return "无宿主窗口" }
            content.addSubview(host)
            host.layoutSubtreeIfNeeded()
            defer { host.removeFromSuperview() }
            let pdf = host.dataWithPDF(inside: host.bounds)
            return (PDFDocument(data: pdf)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let zero = readout(0), near = readout(0.001), plus = readout(3)
        let minus = readout(-3), floor = readout(GainFaderScale.minDB)
        batchReport.append("读数 0「\(zero)」判定=\(zero == "00.00" ? "对" : "错")"
            + " 0.001「\(near)」(期望00.00) +3「\(plus)」(期望+3.00)"
            + " −3「\(minus)」(期望-3.00) −96「\(floor)」(期望-∞)")
        batchReport.append("读数 键入框定宽=\(batchGainFieldLocked())（混音器那一格 44×16，这里跟读数栏的 74 对齐，字号照旧不动）")
    }

    /// 编辑态要真双击才进得去，这台机器注不进鼠标，所以退一步查源码：那一格用的是
    /// 定宽 frame，还是会被撑开的 minWidth。
    private func batchGainFieldLocked() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Views/GainFader.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "读不到源码" }
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("TextField(\"\", text: $text)") }) else {
            return "找不到键入框"
        }
        let window = lines[start..<min(lines.count, start + 12)].joined(separator: "\n")
        return window.contains(".frame(width: 74") && !window.contains("minWidth: 74") ? "是" : "否"
    }

    /// 列表栏宽度：先量启动那一眼（记住的宽在不在位、有没有被比例回报冲掉），再**模拟一次
    /// 真拖分隔条**（只在 AppKit 侧挪分隔条，一次 measurePlaylistWidth 都不替它调），
    /// 看记账那条路自己走不走得通 —— 上一版探针是我直接调 measure()，等于把要验的那一段
    /// 跳过去了，反馈的「记忆没生效」就是这样漏掉的。中间夹去抖、上下限这些 store 侧的账，
    /// 最后一趟走 P 的原路：关掉再开，量记住的宽有没有自己回来。
    private func batchWidthCheck(stage: Int) {
        let store = SettingsStore.shared
        func shown(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "nil" }
        func disk() -> String {
            let saved = UserDefaults.standard.double(forKey: "playlistSidebarWidth")
            return saved == 0 ? "无" : String(format: "%.1f", saved)
        }
        switch stage {
        case 0:
            batchReport.append("宽度 启动读回=\(shown(store.playlistSidebarWidth)) 盘上=\(disk())")
            // 这一行必须在动手之前拍：后面几拍会把 300/320/180 写进去，那一栏真被挪动了
            // 就分不清是「启动时按记住的宽摆」还是「探针自己把它推过去的」。
            batchReport.append("宽度 启动时" + batchPaneWidthCheck())
            batchReport.append("宽度 模拟拖到300（只挪分隔条）" + batchDragPaneTo(300))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.batchWidthCheck(stage: 1) }
        case 1:
            let w = store.playlistSidebarWidth ?? -1
            batchReport.append("宽度 拖后自己记账=\(shown(store.playlistSidebarWidth)) 盘上=\(disk())"
                + " 走到账了=\(abs(w - 300) <= 2)")
            store.measurePlaylistWidth(320)
            batchReport.append("宽度 measure(320) 当拍=\(shown(store.playlistSidebarWidth))"
                + "(期望还没变，去抖 0.4s)")
            store.measurePlaylistWidth(900)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.batchWidthCheck(stage: 2) }
        case 2:
            batchReport.append("宽度 去抖后=\(shown(store.playlistSidebarWidth))(期望320)"
                + " 盘上=\(disk()) 越界900被丢=\((store.playlistSidebarWidth ?? -1) < 500)")
            batchReport.append("宽度 摆过后" + batchPaneWidthCheck())
            store.measurePlaylistWidth(60)
            store.measurePlaylistWidth(180)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.batchWidthCheck(stage: 3) }
        case 3:
            batchReport.append("宽度 measure(60)丢、measure(180)收 ⇒=\(shown(store.playlistSidebarWidth))(期望180)"
                + " 上下限=\(PlaylistSidebar.widthFloor)…\(PlaylistSidebar.widthCeil)")
            batchReport.append("宽度 收到180后" + batchPaneWidthCheck())
            // 关栏再开那一趟（P 的原路）：整棵子树被丢掉重做，记住的宽必须自己摆回来。
            // 上一版探针没验这一段 —— 而反馈的「记忆没生效」正是重新打开的时候。
            vm?.showPlaylistSidebar = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.vm?.showPlaylistSidebar = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.batchWidthCheck(stage: 4) }
            }
        default:
            batchReport.append("宽度 关栏再开之后" + batchPaneWidthCheck()
                + " 记住的=\(shown(store.playlistSidebarWidth))")
            batchHelpStage()
        }
    }

    /// 只把分隔条挪过去（= 用户拖一下），剩下的交给程序自己记账。
    private func batchDragPaneTo(_ width: CGFloat) -> String {
        guard let split = batchMainSplitView(), split.arrangedSubviews.count > 1 else { return " 分栏没找到" }
        let pane = split.arrangedSubviews.count - 1
        let moved = split.bounds.width - width - split.dividerThickness
        guard moved > 0 else { return " 窗口太窄，摆不到" }
        let before = String(format: "%.0f", split.arrangedSubviews[pane].frame.width)
        split.setPosition(moved, ofDividerAt: pane - 1)
        return " 栏 \(before)→\(String(format: "%.0f", split.arrangedSubviews[pane].frame.width))"
    }

    /// 记住的宽度有没有真把那一栏摆出来：HSplitView 在 AppKit 侧就是一枚 NSSplitView，
    /// 分出去的格子量得到。
    private func batchPaneWidthCheck() -> String {
        guard let split = batchMainSplitView() else { return " 分栏没找到" }
        let widths = split.arrangedSubviews.map { String(format: "%.0f", $0.frame.width) }
        return " 分栏实测 \(widths.joined(separator: " / "))"
    }

    private func batchMainSplitView() -> NSSplitView? {
        guard let window = MainWindow.windowForCheck ?? NSApp.mainWindow,
              let content = window.contentView else { return nil }
        return batchFirstSplitView(in: content)
    }

    private func batchFirstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let split = batchFirstSplitView(in: sub) { return split }
        }
        return nil
    }

    /// 帮助页那几句有没有落地：开面板 → 把整段滚动内容画成 PDF → 取字对句子。
    /// 实测两个坑：全角标点（：，。）被 PDFKit 抽成私有区字形，所以句子一律挑不带标点的
    /// 半截；折行还会在词中间插空格，所以比对前把空白全抹掉。
    private func batchHelpStage() {
        vm?.showHelp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.batchHelpRead() }
    }

    private func batchHelpRead() {
        guard let sheet = visibleSheet(), let content = sheet.contentView,
              let document = firstScrollView(in: content)?.documentView else {
            batchReport.append("帮助 没抓到 sheet，跳过")
            vm?.showHelp = false
            writeBatchReport()
            return
        }
        let pdf = document.dataWithPDF(inside: NSRect(origin: .zero, size: document.frame.size))
        let raw = PDFDocument(data: pdf)?.string ?? ""
        let flat = raw.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let sentences = [
            "按住⌘拖动文件名可调序", "一次拖拽算一步撤销", "备用列表的顺序随列表自动存盘",
            "打开/关闭播放列表栏", "栏宽会被记住", "恢复上次设定的宽度",
            "两轨都停下并回到开头", "只停当前轨道并把它拉回开头", "空格不吃⌃",
            "两轨同时播放/暂停", "正负号只在真有正负时才出现", "启动时回到00.00",
            // 那十二条的落地账（分隔条、橙色滑块、预设、
            // 模式更名、触控板、 ⇧,/⇧.、信息表）。一律挑不带标点的半截。
            "指针停在它上面会变成上下双箭头", "两栏各自的最小高度",
            "橙色滑块", "尚未保存任何预设", "同名会先问要不要覆盖",
            "前往通道条预设文件夹", "双轨视图的单轨控制",
            "触控板自动识别", "双指伸张", "两轨同时跳到上一个", "带点的扩展名",
            // 七种新格式、缓存那一格、DSD 的落点、dff 的缺口、设置→数据三件。
            "还收ogg", "一份文件只转一次", "码率按原文件的字节数算",
            "统一折到176.4kHz", ".dff不支持", "前往音频缓存文件夹", "这批格式读不到章节",
        ]
        batchReport.append("帮助 全文 \(raw.count) 字（抹空白 \(flat.count)）")
        for sentence in sentences {
            batchReport.append("帮助 「\(sentence)」\(flat.contains(sentence) ? "在" : "缺")")
        }
        vm?.showHelp = false
        writeDiag(raw, suffix: ".help.txt")
        writeBatchReport()
    }

    /// 混音器推子刻度：白色高亮到底落在哪一格。两种高度各拍一张合成图，再把混音器真开起来
    /// 量窗口里那一枚真的刻度列（真高、真布局）—— 「眼睛看着白的是 −5 那一格」这种账，
    /// 只有量出来才算对得上。
    private func exerciseTicksForCheck() {
        var lines = ["刻度 白色高亮落在哪一格（合成两种高度 + 混音器真身）"]
        for h in [260.0, 420.0] {
            let v = FaderTicksNSView(frame: NSRect(x: 0, y: 0, width: FaderTicksNSView.columnWidth,
                                                   height: CGFloat(h)))
            lines.append("—— 视图高 \(String(format: "%.0f", h))")
            lines.append(contentsOf: v.debugScaleReport(label: "合成"))
        }
        lines.append(contentsOf: exerciseLiveTicks())
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".ticks")
    }

    /// 真身那一路：开混音器 → 等布局跑完 → 在窗口里找出真的那一枚刻度列，量它。
    private func exerciseLiveTicks() -> [String] {
        guard let vm else { return ["没有 vm，跳过真身"] }
        let wasVisible = MixerPanelController.shared.isVisible
        MixerPanelController.shared.open(vm: vm)
        guard let content = MixerPanelController.shared.panel?.contentView else { return ["混音器没有 contentView"] }
        content.layoutSubtreeIfNeeded()
        var out: [String] = []
        let ticks = exerciseAllTicks(in: content)
        defer { if !wasVisible { MixerPanelController.shared.close() } }
        guard !ticks.isEmpty else { return ["混音器里没找到刻度列"] }
        for (i, v) in ticks.enumerated() {
            out.append("—— 窗口里第 \(i + 1) 枚")
            out.append(contentsOf: v.debugScaleReport(label: "真身"))
        }
        return out
    }

    private func exerciseAllTicks(in view: NSView) -> [FaderTicksNSView] {
        var found: [FaderTicksNSView] = []
        if let tick = view as? FaderTicksNSView { found.append(tick) }
        for sub in view.subviews { found.append(contentsOf: exerciseAllTicks(in: sub)) }
        return found
    }

    /// Diagnostic: 主窗口关掉之后还能不能呼回来。关那一下用红按钮自己的
    /// performClick —— 那是真按钮的路（⌘W 在监听器里换成了同一条 hide），所以这一步验的
    /// 是「接单对象真的换掉了」。叫回来那一步用主菜单的 performKeyEquivalent，那是 ⌘2
    /// 真正的入口（这台机器注不进按键）。跑完把模式和可见性摆回动手前。
    private func exerciseWindowForCheck() {
        guard let vm else { return }
        let mode0 = vm.compareMode
        var lines: [String] = ["接线: MainWindow=\(MainWindow.isWired ? "有" : "没接上（探针跑不了）")"]
        guard let w = MainWindow.windowForCheck else {
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".win")
            return
        }
        let button = w.standardWindowButton(.closeButton)
        lines.append("动手前: 可见=\(w.isVisible) 尺寸=\(Int(w.frame.width))×\(Int(w.frame.height)) "
                     + "模式=\(mode0.rawValue) 红按钮接单=\(button?.target is MainWindow.CloseHandler ? "我们" : "还是窗口")")
        button?.performClick(nil)
        lines.append("点红按钮之后: 可见=\(w.isVisible)（该是 false） "
                     + "窗口还在=\(MainWindow.windowForCheck === w)（该是 true，销毁了就呼不回来）")
        // ⌘2 从菜单这一级按下去：既要把模式换到参考曲，也要把藏起来的窗口叫回来。
        var claimed = false
        if let ev = Self.projKeyDown("2", [.command]) {
            claimed = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
        }
        lines.append("⌘2: 菜单接住=\(claimed) · 可见=\(w.isVisible)（该是 true） "
                     + "模式=\(vm.compareMode.rawValue)（该是 参考曲）")
        MainWindow.hide()
        MainWindow.show()
        lines.append("hide/show 一轮: 可见=\(w.isVisible)（该是 true）")
        vm.setCompareMode(mode0)
        lines.append("收尾: 模式=\(vm.compareMode.rawValue) · 可见=\(w.isVisible)")
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".win")
    }

    // MARK: ffmpeg 解码缓存探针（AB_CACHE_CHECK）

    /// `AB_CACHE_FILE="a|b|c"` 递进来的必须全是系统解码器读不了
    /// 的容器，并且同一批文件要用 `--autoplay` 先装载过：第一截量「这一轨真的响了」，
    /// 第二截是会阻塞的机械账（转码、命中、坏素材、清除），所以整段丢在全局队列上，
    /// 末尾把现场恢复原样 —— 缓存是可再生的，探针不该留下垃圾，也不该把真素材的缓存抹掉。
    private func exerciseCacheForCheck() {
        guard let vm = vm else { return }
        let spec = ProcessInfo.processInfo.environment["AB_CACHE_FILE"] ?? ""
        let paths = spec.components(separatedBy: "|")
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else {
            writeDiag("CACHE: AB_CACHE_FILE 没给对（\(spec)），跳过\n", suffix: ".cache")
            return
        }
        let first = URL(fileURLWithPath: paths[0])
        let head = "◇端到端：轨道=\(vm.trackA?.url.lastPathComponent ?? "nil")"
            + " · 装载中=\(vm.loadPending)"
            + " · 引擎时长=\(String(format: "%.3f", AudioEngine.shared.durationA)) s"
            + " · 行上时长=\(String(format: "%.3f", vm.trackA?.duration ?? 0)) s"
            + " · 峰值格=\(vm.waveformPeaksA.binCount)"
            + " · 容器=\(vm.trackA?.containerInfo ?? "—") 编码=\(vm.codecNames[first.path] ?? "…")"
            + " 码率=\(vm.trackA?.bitrateInfo ?? "—") 声道=\(vm.trackA?.channelInfo ?? "—")"
            + " 采样率=\(vm.trackA?.sampleRateInfo ?? "—")"
            + " · 有声=\(AudioEngine.shared.durationA > 0 && vm.waveformPeaksA.binCount > 0 ? "对" : "错")"
        DispatchQueue.global(qos: .userInitiated).async {
            var lines = [head]

            // ①名单：六个该进来，八个该挡在外面。.dff 有意不收 —— ffmpeg 里没有 DFF 解容器。
            let should = ["ogg", "oga", "opus", "wma", "ape", "wv", "dsf"]
            let wont = ["wav", "mp3", "flac", "m4a", "aiff", "caf", "aac", "dff"]
            let inHits = should.filter { AudioFormatCache.needsConversion(URL(fileURLWithPath: "/x/a.\($0)")) }.count
            let outHits = wont.filter { !AudioFormatCache.needsConversion(URL(fileURLWithPath: "/x/a.\($0)")) }.count
            lines.append("①名单：该转 \(inHits)/\(should.count) · 该放 \(outHits)/\(wont.count)"
                + " · 全对=\(inHits == should.count && outHits == wont.count ? "对" : "错")")

            // ②逐份：先抹掉自己那份缓存 → 真转一遍 → 再问一次（该命中）→ AVAudioFile 开得到吗
            //   → 元数据按原文件对账（码率必须是原容器那个数字，不是 wav 的 1411）。
            lines.append("②逐份（抹掉自己的旧缓存再转）")
            for path in paths {
                let source = URL(fileURLWithPath: path)
                try? FileManager.default.removeItem(at: AudioFormatCache.cacheURL(for: source))
                let t0 = CACurrentMediaTime()
                var note = "  .\(source.pathExtension) \(source.deletingPathExtension().lastPathComponent.prefix(10))"
                var audio = source
                do { audio = try AudioFormatCache.resolve(source) }
                catch {
                    lines.append("\(note) 首转抛错：\(error.localizedDescription)")
                    continue
                }
                let bytes = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let t1 = CACurrentMediaTime()
                let again = (try? AudioFormatCache.resolve(source)) ?? source
                let hitMs = (CACurrentMediaTime() - t1) * 1000
                let file = try? AVAudioFile(forReading: audio)
                let sr = file?.processingFormat.sampleRate ?? 0
                let ch = file?.processingFormat.channelCount ?? 0
                let frames = file?.length ?? 0
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard let meta = AudioEngine.shared.readMetadata(url: source) else {
                    lines.append("\(note) 首转 \(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000)) ms"
                        + " → \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB · 但 readMetadata 交回 nil=错")
                    continue
                }
                let expect = meta.duration > 0 ? Int(Double(size) * 8 / meta.duration / 1000) : 0
                note += " 首转 \(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000)) ms"
                    + " → \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB"
                    + " · 二次 \(String(format: "%.1f", hitMs)) ms 同一份=\(again.path == audio.path ? "对" : "错")"
                    + " · AVAudioFile=\(file == nil ? "开不了=错" : "对") \(String(format: "%.0f", sr)) Hz"
                    + " \(ch) ch \(frames) 帧"
                    + " · 元数据 \(String(format: "%.3f", meta.duration)) s/\(meta.channels) ch"
                    + "/\(String(format: "%.0f", meta.sampleRate)) Hz"
                    + " · 码率 \(meta.bitrate) kbps（原文件 \(size) B 手算 \(expect)"
                    + "=\(meta.bitrate == expect ? "对" : "错")）"
                    + " · 章节 \(PlayerViewModel.readChapters(from: source).count) 组（转码格式该是 0）"
                lines.append(note)
            }

            // ③原地改过一个字节 ⇒ 键该变：不然编辑过的文件会拿到旧缓存。
            //   尺寸问内核（attributesOfItem）：同一个 URL 实例问两次 resourceValues
            //   会交回同一个缓存数字，那样量的就不是文件而是 Foundation 的记性。
            if AudioFormatCache.needsConversion(first) {
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("abcache-\(getpid()).\(first.pathExtension)")
                try? FileManager.default.removeItem(at: copy)
                var note = "③内容变了要换一份缓存"
                func onDiskSize(_ url: URL) -> Int {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    return (attrs?[.size] as? Int) ?? -1
                }
                if (try? FileManager.default.copyItem(at: first, to: copy)) != nil {
                    let keyA = AudioFormatCache.cacheURL(for: copy)
                    let okA = (try? AudioFormatCache.resolve(copy)) != nil
                    let sizeA = onDiskSize(copy)
                    var why = ""
                    do {
                        var data = try Data(contentsOf: copy)
                        data.append(0)
                        try data.write(to: copy)
                    } catch { why = " · 改不动：\(error)" }
                    let sizeB = onDiskSize(copy)
                    let keyB = AudioFormatCache.cacheURL(for: copy)
                    let okB = (try? AudioFormatCache.resolve(copy)) != nil
                    note += "：键变了=\(keyA.path != keyB.path ? "对" : "错")"
                        + " · 两份都转成=\(okA && okB ? "对" : "错")"
                        + "（\(keyA.lastPathComponent) / \(keyB.lastPathComponent)）"
                        + " · 改动 \(sizeA)→\(sizeB) 字节" + why
                } else {
                    note += "：拷贝失败，跳过"
                }
                try? FileManager.default.removeItem(at: copy)
                lines.append(note)
            }

            // ④坏素材（同名、里面不是音频）：要抛错、要说得出话、不许留 .part。
            let junk = FileManager.default.temporaryDirectory
                .appendingPathComponent("abjunk-\(getpid()).opus")
            try? "不是音频".data(using: .utf8)?.write(to: junk)
            var junkNote = "④坏素材："
            do {
                _ = try AudioFormatCache.resolve(junk)
                junkNote += "没抛错=错"
            } catch {
                junkNote += "抛错=对 ·「\(error.localizedDescription)」"
            }
            let residues = ((try? FileManager.default.contentsOfDirectory(
                at: AudioFormatCache.directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []).filter { $0.path.contains(".part") }
            junkNote += " · .part 残留 \(residues.count) 个=\(residues.isEmpty ? "对" : "错")"
            try? FileManager.default.removeItem(at: junk)
            lines.append(junkNote)

            // ⑤清除缓存：大小归零、同步问一句的那格退回原文件。
            let before = AudioFormatCache.sizeText()
            AudioFormatCache.clear()
            lines.append("⑤清除：\(before) → \(AudioFormatCache.sizeText())"
                + " · audioURL 退回原文件="
                + (AudioFormatCache.audioURL(for: first).path == first.path ? "对" : "错"))

            // ⑥恢复现场：把真素材重转一遍，顺带证明「清除之后还能用」——波形也得重算得出。
            var restored = 0
            for path in paths {
                if (try? AudioFormatCache.resolve(URL(fileURLWithPath: path))) != nil { restored += 1 }
            }
            let peaks = WaveformGenerator.generate(url: AudioFormatCache.cacheURL(for: first))
            lines.append("⑥恢复：重转 \(restored)/\(paths.count) 份 · 缓存 \(AudioFormatCache.sizeText())"
                + " · 清除后重算波形 \(peaks?.binCount ?? 0) 格="
                + ((peaks?.binCount ?? 0) > 0 ? "对" : "错"))

            // ⑦渲染导出：这一条链路吃的是解码后的那一份（renderNow 自己会再 resolve 一次），
            //   源文件是 opus 时它是全程序里最容易被格式拖住的一处，所以真渲 2 秒出来量。
            //   尺子不是「正好 2.000 s」：renderNow 写完那一段还要再多要 1 秒的插件尾巴窗
            //   （没挂插件也照走，实测无插件时留下 0.133 s），所以量的是「落盘 + 时长落在
            //   2~3 s 之间 + 里面真的有声音」。
            var exportNote = "⑦渲染导出 2 s（源=\(first.pathExtension)）"
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("abcache-export-\(getpid()).wav")
            try? FileManager.default.removeItem(at: out)
            let request = RenderExportService.Request(sourceURL: first, start: 1, end: 3,
                                                      preGainDB: 0, faderDB: 0, panTicks: 0,
                                                      slots: [], laneBypass: false,
                                                      bitDepth: .s24, outputURL: out)
            let done = DispatchSemaphore(value: 0)
            RenderExportService.run(request, progress: { _ in }, completion: { _ in done.signal() })
            // 渲染本身在后台队列上，这里等的是它自己的完成回跳，主线程不受影响。
            _ = done.wait(timeout: .now() + 120)
            if let file = try? AVAudioFile(forReading: out) {
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                var peak: Float = 0
                let step = AVAudioFrameCount(4096)
                if let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step) {
                    var at: AVAudioFramePosition = 0
                    while at < file.length, (try? file.read(into: buf, frameCount: step)) != nil,
                          buf.frameLength > 0 {
                        if let ch = buf.floatChannelData {
                            for channel in 0..<Int(buf.format.channelCount) {
                                for frame in 0..<Int(buf.frameLength) {
                                    peak = max(peak, abs(ch[channel][frame]))
                                }
                            }
                        }
                        at += AVAudioFramePosition(buf.frameLength)
                    }
                }
                exportNote += "：\(String(format: "%.3f", seconds)) s × \(file.processingFormat.channelCount) ch"
                    + "（2 s 段 + 尾巴窗，该在 2~3 s）=\(seconds >= 2 && seconds <= 3 ? "对" : "错")"
                    + " · 峰值 \(String(format: "%.3f", peak))"
                    + " 有声=\(peak > 0.01 ? "对" : "错")"
            } else {
                exportNote += "：没落盘=错"
            }
            try? FileManager.default.removeItem(at: out)
            lines.append(exportNote)

            DispatchQueue.main.async {
                self.writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".cache")
            }
        }
    }

    // MARK: time trim 探针（AB_TRIM_CHECK）

    /// 这几条只能说成数字：
    /// ① 参数式 —— 一个样本都不搬，刻度 = 文件时长 + 偏移；
    /// ② 300 ms 沉降 —— 途中引擎那份值不动，过了才重排；
    /// ③ 正偏移的空白 —— 播放头在空白里跟着墙钟走（不是先跳到 offset），
    ///    音频在 offset 那一格才出声，差的多少就是排期到样本时钟起步的滞后；
    /// ④ 负偏移 —— 刻度缩短，从文件 |offset| 秒处起播；
    /// ⑤ 撤销 —— undo 一步回到偏移 0，且不等那 300 ms。
    private func exerciseTrimForCheck() {
        guard let vm = vm else { return }
        let engine = AudioEngine.shared
        awaitForCheck("A 轨就绪", { engine.durationA > 0 }) { ready in
            guard ready else { self.appendTrimCheck("没等到 A 轨，跳过"); return }
            let file = engine.durationA
            vm.pause()
            vm.seekSide(.a, to: 0)
            self.appendTrimCheck(String(format: "起点：文件=%.3f 刻度=%.3f 引擎偏移=%.3f 界面偏移=%.3f",
                                        file, vm.laneDuration(.a), engine.trim(.a), vm.timeTrim(.a)))
            vm.setTimeTrim(2, for: .a)
            self.appendTrimCheck(String(format: "给 +2 s 立刻：界面=%.3f 引擎=%.3f（该还是 0）刻度=%.3f",
                                        vm.timeTrim(.a), engine.trim(.a), vm.laneDuration(.a)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.appendTrimCheck(String(format: "给 +2 s 过 400 ms：引擎=%.3f 刻度=%.3f 参数式=%@",
                                            engine.trim(.a), engine.laneDuration(.a),
                                            abs(engine.laneDuration(.a) - (file + 2)) < 0.001 ? "对" : "错"))
                self.trimPlayProbe(offset: 2, file: file) {
                    self.trimUndoProbe(file: file)
                }
            }
        }
    }

    /// 起步之后每 10 ms 采一对（墙钟、播放头），采 3 s：`pos-(wall-0.05)` 就是
    /// 「样本时钟比排期晚起步」多久（0.05 是排期留给引擎的那点提前量）。空白里 pos
    /// 若直接跳到 2，说明负 sampleTime 那条路读到的是哨兵值，得改回墙钟。
    private func trimPlayProbe(offset: TimeInterval, file: TimeInterval, then: @escaping () -> Void) {
        guard let vm = vm else { return }
        let engine = AudioEngine.shared
        vm.seekSide(.a, to: 0)
        let t0 = ProcessInfo.processInfo.systemUptime
        engine.playSide(.a, from: 0)
        var left = 300
        var lastPos = 0.0
        var lastWall = t0
        var worstGap = 0.0
        var worstAt = 0.0
        func step() {
            let wall = ProcessInfo.processInfo.systemUptime - t0
            let pos = engine.position(of: .a)
            // 第一拍没有「上一拍」可比，从第二拍起记账。
            if left < 300, abs((pos - lastPos) - (wall - lastWall)) > abs(worstGap) {
                worstGap = (pos - lastPos) - (wall - lastWall)
                worstAt = wall
            }
            lastPos = pos
            lastWall = wall
            // 空白那一段是嫌疑区，头 60 拍（0.6 s）一拍一行全抄下来。
            if left >= 240 || left % 40 == 0 {
                self.appendTrimCheck(String(format: "  offset=%.1f wall=%.3f pos=%.3f 比墙钟晚=%.3f",
                                            offset, wall, pos, pos - (wall - 0.05)))
            }
            left -= 1
            guard left > 0 else {
                self.appendTrimCheck(String(format: "offset=%.1f 收尾：pos=%.3f 最大跳变=%+.3f @wall=%.3f 刻度=%.3f 文件=%.3f",
                                            offset, pos, worstGap, worstAt, engine.laneDuration(.a), file))
                vm.pause()
                then()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { step() }
        }
        step()
    }

    private func trimUndoProbe(file: TimeInterval) {
        guard let vm = vm else { return }
        let engine = AudioEngine.shared
        vm.seekSide(.a, to: 0)
        vm.setTimeTrim(0, for: .a)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.appendTrimCheck(String(format: "归零过 400 ms：引擎=%.3f 刻度=%.3f 对=%@", engine.trim(.a),
                                        engine.laneDuration(.a),
                                        abs(engine.laneDuration(.a) - file) < 0.001 ? "对" : "错"))
            // 撤销栈上此刻是「偏移 0」「偏移 2」两格，退一步该回到 +2，而且当场生效（不等 300 ms）。
            vm.undoEdit()
            self.appendTrimCheck(String(format: "撤销一步（当场，该回 +2）：界面=%.3f 引擎=%.3f 刻度=%.3f",
                                        vm.timeTrim(.a), engine.trim(.a), engine.laneDuration(.a)))
            self.trimNegativeProbe(file: file)
        }
    }

    private func trimNegativeProbe(file: TimeInterval) {
        guard let vm = vm else { return }
        let engine = AudioEngine.shared
        vm.setTimeTrim(-1, for: .a)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.appendTrimCheck(String(format: "给 -1 s：引擎=%.3f 刻度=%.3f 轨内 0 = 文件 %.3f 秒",
                                        engine.trim(.a), engine.laneDuration(.a),
                                        engine.fileTime(0, side: .a)))
            self.trimPlayProbe(offset: -1, file: file) {
                let rate = engine.sampleRate(for: .a)
                vm.setTimeTrim(0, for: .a)
                self.appendTrimCheck(String(format: "样本档：采样率=%.0f 一格=%.6f s=%.3f ms",
                                            rate, 1 / rate, 1000 / rate))
                vm.setTimeTrim(1 / rate, for: .a)
                self.appendTrimCheck(String(format: "输一个样本：界面=%.6f 折到整帧=%@",
                                            vm.timeTrim(.a),
                                            abs(vm.timeTrim(.a) * rate - 1) < 0.0001 ? "对" : "错"))
                vm.setTimeTrim(0, for: .a)
                self.trimProjectProbe()
            }
        }
    }

    /// ⑥ 工程往返：偏移存进 .abpl、读回来当场生效（不等那 300 ms）。
    private func trimProjectProbe() {
        guard let vm = vm else { return }
        let engine = AudioEngine.shared
        let url = URL(fileURLWithPath: "/tmp/ab220win/trim-project.abpl")
        let lastBefore = ProjectStore.lastProjectURL
        vm.setTimeTrim(1.5, for: .a)
        vm.setTimeTrim(-0.25, for: .b)
        vm.writeProject(to: url)
        let saved = try? ProjectStore.readProject(from: url)
        appendTrimCheck(String(format: "落盘：文件里 A=%.3f B=%.3f（该是 1.500 / -0.250）",
                               saved?.trimA ?? -999, saved?.trimB ?? -999))
        vm.setTimeTrim(0, for: .a)
        vm.setTimeTrim(0, for: .b)
        vm.loadProject(from: url)
        appendTrimCheck(String(format: "读回当场：界面 A=%.3f B=%.3f 引擎 A=%.3f B=%.3f 刻度 A=%.3f",
                               vm.timeTrim(.a), vm.timeTrim(.b), engine.trim(.a), engine.trim(.b),
                               engine.laneDuration(.a)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.appendTrimCheck(String(format: "读回过 400 ms：刻度 A=%.3f B=%.3f",
                                         engine.laneDuration(.a), engine.laneDuration(.b)))
            try? FileManager.default.removeItem(at: url)
            ProjectStore.lastProjectURL = lastBefore
            self.appendTrimCheck("探针跑完")
        }
    }

    /// 账追加进 `<AB_TRIM_CHECK>.trim`：一路要等沉降、等播放，收尾一次写会把中间
    /// 那几拍丢掉。
    private func appendTrimCheck(_ line: String) {
        let text = line + "\n"
        FileHandle.standardError.write(text.data(using: .utf8)!)
        guard let base = ProcessInfo.processInfo.environment["AB_TRIM_CHECK"],
              base != "1", !base.isEmpty else { return }
        let path = base + ".trim"
        let data = text.data(using: .utf8)!
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: 章节转标记探针（AB_CHAPTER_CHECK）
    /// 新功能：音频自带章节 → 开文件自动转成 M 标记，落选中的那一轨，
    /// 一次 ≥50 枚先问一句（默认按钮「否」）。素材是两份带章节的 m4a，路径由
    /// `AB_CHAPTER_FILES="少章节|多章节"` 递进来，章节数从文件本身读出来对账、不写死。
    private func exerciseChaptersForCheck() {
        guard let vm = vm else { return }
        let spec = ProcessInfo.processInfo.environment["AB_CHAPTER_FILES"] ?? ""
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2, parts.count <= 3,
              FileManager.default.fileExists(atPath: parts[0]),
              FileManager.default.fileExists(atPath: parts[1]) else {
            chNote("AB_CHAPTER_FILES=\"少章节|多章节[|长文件]\" 没给对或文件不存在（\(spec)），跳过")
            return
        }
        chFew = URL(fileURLWithPath: parts[0])
        chMany = URL(fileURLWithPath: parts[1])
        chFewCount = PlayerViewModel.readChapters(from: chFew).count
        chManyCount = PlayerViewModel.readChapters(from: chMany).count
        // 第三份可选：一首长曲子，专门用来量「标记先到、波形后到」这两下差多少秒。
        if parts.count == 3, FileManager.default.fileExists(atPath: parts[2]) {
            chLong = URL(fileURLWithPath: parts[2])
            chLongCount = PlayerViewModel.readChapters(from: chLong).count
        }
        chNote("素材: \(chFew.lastPathComponent)=\(chFewCount) 章 · "
               + "\(chMany.lastPathComponent)=\(chManyCount) 章 · 阈值=\(PlayerViewModel.chapterPromptThreshold)"
               + (chLongCount > 0 ? " · 长文件\(chLongCount)章" : " · 没给长文件（时序那一档跳过）"))
        MarkerStore.shared.setMarkers([], for: chFew)
        MarkerStore.shared.setMarkers([], for: chMany)
        vm.setEditMode(false)
        vm.pause()
        vm.clearAllTracks()
        chRun()
    }

    private var chLines: [String] = []
    private var chStage = 0
    private var chFew = URL(fileURLWithPath: "/")
    private var chMany = URL(fileURLWithPath: "/")
    private var chFewCount = 0
    private var chManyCount = 0
    /// 时序那一档用的长文件（可选），以及掐表的三个读数。
    private var chLong = URL(fileURLWithPath: "/")
    private var chLongCount = 0
    private var chClock = Date()
    private var chMarkAt: TimeInterval?
    private var chIdleAt: TimeInterval?

    private func chNote(_ line: String) {
        chLines.append(line)
        writeDiag(chLines.joined(separator: "\n") + "\n", suffix: ".chapter")
    }

    /// 装载是异步的：每一阶段先把动作发出去，再等 loadPending 归零读账，然后自己往下走。
    private func chRun() {
        guard let vm = vm else { return }
        // 读数闭包是逃出的，属性得 self. 前缀；先拷两份局部的，写起来干净些。
        let fewCount = chFewCount, manyCount = chManyCount
        func promptCount() -> Int { vm.chapterImportPrompt?.positions.count ?? 0 }
        func kinds(_ markers: [Marker]) -> String {
            Set(markers.map { $0.kind.rawValue }).sorted().joined(separator: ",")
        }
        func edgeTimes(_ markers: [Marker]) -> String {
            guard let first = markers.min(by: { $0.position < $1.position }),
                  let last = markers.max(by: { $0.position < $1.position }) else { return "—" }
            return String(format: "%.3f / %.3f", first.position, last.position)
        }
        switch chStage {
        case 0:
            vm.setCompareMode(.versionCompare)
            vm.setActiveTrack(.a)
            vm.loadTrackAFromTrack(Track(url: chFew))
            chWait({ "S1 版本对比·选中A·开「少章节」: 标记A=\(vm.markersA.count)（该是 \(fewCount)） "
                    + "弹窗=\(promptCount())（该是 0，没到阈值就直接转） kind=\(kinds(vm.markersA))" })
        case 1:
            vm.loadTrackAFromTrack(Track(url: chFew))
            chWait({ "S2 同一个文件再开一次: 标记A=\(vm.markersA.count)（该仍是 \(fewCount)，去重生效） "
                    + "弹窗=\(promptCount())" })
        case 2:
            // 落点认的是「这一份文件在哪一轨」，不是选中轨：这里选中 A 也把章节写进 B，
            // 因为曲子就装在 B 的条上。先清掉这个文件自己那份标记（S1 刚给它转过），
            // 不然读数分不清是新写的还是老账。
            vm.setCompareMode(.reference)
            MarkerStore.shared.setMarkers([], for: chFew)
            vm.loadTrackBFromTrack(Track(url: chFew))
            chWait({ "S3 参考曲·选中A·把「少章节」装到B: 标记B=\(vm.markersB.count)（该是 \(fewCount)，落在文件自己那一轨） "
                    + "弹窗=\(promptCount())（该是 0）" })
        case 3:
            // B 有东西了才选得中，所以「选中B」紧贴在换文件那一步之前。
            vm.setActiveTrack(.b)
            vm.loadTrackBFromTrack(Track(url: chMany))
            chWait({ "S4 参考曲·选中B·换「多章节」: 选中=\(vm.activeTrack.rawValue)（该是 B） "
                    + "弹窗=\(promptCount())（该是 \(manyCount)） 标记B=\(vm.markersB.count)（该是 0，还没点头）" })
        case 4:
            vm.cancelChapterImport()
            chStep({ "S5 按「否」: 标记B=\(vm.markersB.count)（该是 0） 弹窗=\(promptCount())（该是 0）" })
        case 5:
            vm.loadTrackBFromTrack(Track(url: chMany))
            chWait({ "S6 同一个文件再开一次: 弹窗=\(promptCount())（该是 \(manyCount)，又问一遍）" })
        case 6:
            vm.confirmChapterImport()
            chStep({ "S7 按「是」: 标记B=\(vm.markersB.count)（该是 \(manyCount)） kind=\(kinds(vm.markersB))（该是 sideB） "
                    + "位置首末=\(edgeTimes(vm.markersB))" })
        case 7:
            vm.undoEdit()
            chStep({ "S8 撤销这一笔: 标记B=\(vm.markersB.count)（该是 0）" })
        case 8:
            // 版本对比只画 A 轨那一条进度条，所以落点固定是 A：选中 B 也不算数，B 这一路整个跳过。
            vm.setCompareMode(.versionCompare)
            vm.setActiveTrack(.b)
            MarkerStore.shared.setMarkers([], for: chMany)
            vm.loadTrackBFromTrack(Track(url: chMany))
            chWait({ "S9 版本对比·选中B·把「多章节」装到B: 选中=\(vm.activeTrack.rawValue) 标记B=\(vm.markersB.count)（该是 0） "
                    + "弹窗=\(promptCount())（该是 0）" })
        case 9:
            // 时序：标记不该等波形解码完才冒出来。没给长文件就跳过这一档。
            guard chLongCount > 0 else {
                chStep({ "S10 时序: 跳过（没给第三个长文件）" })
                return
            }
            MarkerStore.shared.setMarkers([], for: chLong)
            vm.setCompareMode(.versionCompare)
            vm.setActiveTrack(.a)
            chMarkAt = nil
            chIdleAt = nil
            chClock = Date()
            vm.loadTrackAFromTrack(Track(url: chLong))
            chPollTiming(vm)
        default:
            MarkerStore.shared.setMarkers([], for: chFew)
            MarkerStore.shared.setMarkers([], for: chMany)
            if chLongCount > 0 { MarkerStore.shared.setMarkers([], for: chLong) }
            vm.pause()
            vm.setActiveTrack(.a)
            chNote("收尾: 两份测试文件的标记都清了（少=\(MarkerStore.shared.markers(for: chFew).count) "
                   + "多=\(MarkerStore.shared.markers(for: chMany).count)，都该是 0）")
            return
        }
    }

    /// 10 ms 一轮，把「标记到齐」和「波形就绪」各掐一次表。
    private func chPollTiming(_ vm: PlayerViewModel, remaining: Int = 6_000) {
        let now = Date().timeIntervalSince(chClock)
        if chMarkAt == nil, vm.markersA.count >= chLongCount { chMarkAt = now }
        if chIdleAt == nil, chMarkAt != nil, vm.loadPending == 0 { chIdleAt = now }
        if chMarkAt != nil, chIdleAt != nil || remaining == 0 {
            let longCount = chLongCount
            chStep({ "S10 时序（长文件 \(longCount) 章）: 标记到齐=\(Self.chTime(self.chMarkAt)) s · "
                    + "波形就绪=\(Self.chTime(self.chIdleAt)) s —— 标记该在前" })
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.chPollTiming(vm, remaining: remaining - 1)
        }
    }

    private static func chTime(_ t: TimeInterval?) -> String {
        t.map { String(format: "%.2f", $0) } ?? "—"
    }

    private func chWait(_ line: @escaping () -> String) {
        guard let vm = vm else { return }
        awaitForCheck("音轨空闲", remaining: 1_200, { vm.loadPending == 0 }) { settled in
            if !settled { self.chNote("（等音轨空闲超时，这一行读数不可信）") }
            self.chNote(line())
            self.chStage += 1
            self.chRun()
        }
    }

    private func chStep(_ line: @escaping () -> String) {
        chNote(line())
        chStage += 1
        chRun()
    }

    // MARK: 视频窗口探针（AB_PANEL=video · #if DEBUG）
    //
    // 这支 mp4 的画面在不在、和声音差多少，隔着屏幕看不出所以只能记账：每一步把
    // 「引擎要的位置」和「播放器实际的位置」都抄一遍，容差按半帧算。跑完写进
    // `<AB_MENUDUMP>.video`。

    private var vcLines: [String] = []

    private func vcNote(_ line: String) {
        vcLines.append(line)
        writeDiag(vcLines.joined(separator: "\n") + "\n", suffix: ".video")
    }

    /// 一列同步账：期望/实际/差/半帧容差。
    private func vcSync(_ vm: PlayerViewModel, _ tag: String) {
        let side = vm.activeTrack
        guard let r = VideoPanelController.shared.syncReadings(side) else {
            vcNote("\(tag): \(side == .a ? "A" : "B") 轨读不到（没画面或还没挂上 item）")
            return
        }
        let delta = r.actual - r.expected
        vcNote("\(tag): \(side == .a ? "A" : "B") 轨 期望=\(String(format: "%.3f", r.expected))s "
               + "实际=\(String(format: "%.3f", r.actual))s 差=\(String(format: "%+.3f", delta))s "
               + "半帧=\(String(format: "%.4f", r.halfFrame))s "
               + "判定=\(abs(delta) <= max(r.halfFrame * 2, 0.05) ? "对得上" : "对不上")")
    }

    /// 视频那一列的六个读数，探针一行写完。
    private static func vcFactsLine(_ f: VideoFacts?) -> String {
        guard let f else { return "未读" }
        return "\(f.hasVideo ? "有" : "无")画面 \(f.container) \(f.codec) \(f.bitrate) "
            + "\(f.colour) \(f.frameRate) \(Int(f.width))×\(Int(f.height))"
    }

    private func vcFacts(_ vm: PlayerViewModel) {
        for side in [TrackSide.a, .b] {
            guard let track = side == .a ? vm.trackA : vm.trackB else { continue }
            let facts = vm.videoFacts[track.url.path]
            let shown = Self.vcFactsLine(facts)
            // 码率两本账一起抄：`bitrateInfo` 是文件字节数 ÷ 时长（整个容器），
            // `audioBitrate` 是这条音轨自己的。面板音频那一列用后者，所以这一行要看得出
            // 带画面的容器上两者差多少。编码那一格读的是 `codecNames`（后台读、主线程写）。
            vcNote("\(side == .a ? "A" : "B") \(track.url.lastPathComponent): 视频[\(shown)] "
                   + "音频[时长\(String(format: "%.2f", track.duration))s "
                   + "\(track.channelInfo) \(track.sampleRateInfo) 按容器=\(track.bitrateInfo) "
                   + "音轨=\(facts?.audioBitrate ?? "无") 编码=\(vm.codecNames[track.url.path] ?? "未写")]")
        }
    }

    /// 视频窗口那三条落成数字：内容尺寸该等于画面尺寸（摆不下才缩），
    /// 宽高比该锁在画面上，随便递一个尺寸进去落回来的比例该不变；整块可拖读
    /// `isMovableByWindowBackground`。
    private func reportVideoSizeForCheck(_ settled: Bool) {
        guard let vm else { return }
        guard settled else {
            writeDiag("VIDEOSIZE: 没等到画面摆上，跳过\n", suffix: ".videosize")
            return
        }
        let panel = VideoPanelController.shared
        let path = (vm.activeTrack == .a ? vm.trackA : vm.trackB)?.url.path
        let facts = path.flatMap { vm.videoFacts[$0] } ?? VideoFacts()
        let f = panel.windowFactsForCheck
        let ratio = { (s: NSSize) -> String in
            s.height > 0 ? String(format: "%.4f", s.width / s.height) : "—"
        }
        var lines: [String] = []
        let picture = NSSize(width: facts.width, height: facts.height)
        lines.append("画面: \(Int(facts.width))×\(Int(facts.height))（比例 \(ratio(picture))）")
        lines.append("开窗: 内容=\(Int(f.content.width))×\(Int(f.content.height))（比例 \(ratio(f.content))）"
                     + " 锁定的宽高比=\(Int(f.aspect.width))×\(Int(f.aspect.height)) 整块可拖=\(f.draggable ? "是" : "否")")
        // 站错屏 = 缩放的尺子读错：这一行把「窗口框 + 它认为自己在哪块屏 + 那块屏的可见框」
        // 三件一起报出来，和外面用 CGWindowList 量的 1842×1055 对得上才算数。
        func place(_ tag: String) {
            let p = panel.windowPlaceForCheck
            lines.append("\(tag): 框=\(Int(p.frame.width))×\(Int(p.frame.height))@(\(Int(p.frame.minX)),\(Int(p.frame.minY)))"
                         + " 屏=\(p.screen) 可见=\(Int(p.visible.width))×\(Int(p.visible.height))")
            if tag == "开窗时" { lines.append("这一份程序的窗: \(p.others)") }
        }
        place("开窗时")
        for try_ in [NSSize(width: 800, height: 600), NSSize(width: 2000, height: 1000)] {
            let got = panel.resizeForCheck(try_)
            lines.append("递 \(Int(try_.width))×\(Int(try_.height)) → 落 \(Int(got.width))×\(Int(got.height))（比例 \(ratio(got))）")
        }
        let back = panel.resizeForCheck(f.content)
        lines.append("回到 \(Int(back.width))×\(Int(back.height))")
        place("收尾时")
        writeDiag("VIDEOSIZE:\n" + lines.joined(separator: "\n") + "\n", suffix: ".videosize")
    }

    /// AB_VIDEOSTATE_CHECK：两轨纯音频按 ⌘6 闪退那一条的现场。先把视频窗口的窗口账整份抄下来
    /// （找非有限值 / 0 值 / 离谱值），再连着开三次 live resize 的壳改框 —— 崩溃报告里死的那条
    /// 链子（`_setFrameCommon` → `_adjustNeedsDisplayRegionForNewFrame`）程序改框也走，
    /// 只是拖边那一趟还多了比例锁的账。每一趟都先记账后动手，死了也能看出死在第几步。
    private func exerciseVideoStateForCheck() {
        guard let vm else { return }
        let panel = VideoPanelController.shared
        panel.open(vm: vm)
        var lines: [String] = ["轨: A=\(vm.trackA?.url.lastPathComponent ?? "无") "
            + "B=\(vm.trackB?.url.lastPathComponent ?? "无") 摆着=\(vm.activeTrack == .a ? "A" : "B")"]
        for side in [TrackSide.a, .b] {
            let path = (side == .a ? vm.trackA : vm.trackB)?.url.path
            let facts = path.flatMap { vm.videoFacts[$0] }
            lines.append("\(side == .a ? "A" : "B") 画面: \(Self.vcFactsLine(facts))")
        }
        lines.append("=== 开窗后")
        lines.append(panel.stateDumpForCheck)
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".videostate")
        let env = ProcessInfo.processInfo.environment
        let pre = panel.preForCheck(env["AB_VIDEOPRE"] ?? "")
        func runDrag(_ tag: String) {
            let wh = (env["AB_VIDEODRAG"] ?? "").split(separator: "=").compactMap { Double($0) }
            guard wh.count == 2, let goal = env["AB_VIDEODRAG"] else { return }
            // 拖边那一下注不进真指针（实测 CGEventPost 送鼠标事件在这台机器上被丢），所以
            // 这一条只在 `AB_VIDEODRAG=<宽>=<高>` 时走：它自己会进 AppKit 的内层事件循环，
            // 先把账落完再动手，外面靠「有没有新的崩溃报告」分闪退和卡住。
            lines.append("=== \(tag) _resizeWithEvent＋定时器喂拖动"
                         + "（AB_VIDEODRAG=\(goal) 摘掉=\(pre)）")
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".videostate")
            lines.append("结果: \(panel.dragResizeForCheck(to: NSSize(width: wh[0], height: wh[1])))")
            lines.append(panel.stateDumpForCheck)
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".videostate")
        }
        // `dragfirst`：跳过下面那三趟程序化的 live resize，先拖一次。摘掉比例锁就不崩
        // 这件事有两个解释 —— 要么 AppKit 无约束拖边的数学本身出事，要么是我这几趟
        // `beginLiveResize`/`endLiveResize` 把窗口内部的 live resize 记账弄脏了。
        // 只有「在这几趟之前拖一次不崩」才支持第二个解释。
        if pre.contains("dragfirst") { runDrag("开窗后直接") }
        for step in [(CGFloat(40), CGFloat(-30)), (CGFloat(-80), CGFloat(50)), (CGFloat(0), CGFloat(0))] {
            let got = panel.liveResizeForCheck(step.0, step.1)
            lines.append("=== live resize \(Int(step.0))×\(Int(step.1)): \(got)")
            lines.append(panel.stateDumpForCheck)
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".videostate")
        }
        if !pre.contains("dragfirst") { runDrag("live resize 之后") }
        vcNote("VIDEOSTATE 全程活着")
    }

    /// 「为正在播放的那一轨重新指派 = 立刻停」逐拍盯（`AB_REASSIGN=watch`）。
    ///
    /// 停有三个地方可停：音频节点（`engine.isPlaying`）、画面那一台（`AVPlayer.rate`）、
    /// 界面那本旗标（`sideIsPlaying`）—— 少停哪一个都算没停，所以三件一起逐拍抄，另加
    /// 声音/画面各自这一拍走了多少、装载闸门、欠放。换完文件之后**一下按钮都不碰**，
    /// 连抄 5 s：只看它自己会不会又起来。
    ///
    /// 六趟 = 单轨视图/双轨视图 × 无缝开/关 × 被换的那一轨取「摆着又在放的」和
    /// 「收在看不见那层、还在放的」（单轨那一档只摆着一轨，所以少两趟）。素材走
    /// `AB_RS_DIR`（时长各不相同，挂着的时长就是证据）。
    private func runReassignWatch(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        let e = AudioEngine.shared
        let dir = ProcessInfo.processInfo.environment["AB_RS_DIR"] ?? "/tmp/ab220win/rs/"
        func track(_ name: String) -> Track { Track(url: URL(fileURLWithPath: dir + name)) }
        func t(_ d: Double) -> String { String(format: "%.2f", d) }
        let seamlessSnapshot = SettingsStore.shared.seamlessVideoSwitch
        var lines: [String] = []
        var start = 0.0
        var prevHead: [TrackSide: Double] = [:]
        var prevPic: [TrackSide: Double] = [:]
        var beat = 0
        panel.open(vm: vm)
        func note(_ s: String) {
            lines.append(s)
            writeDiag("REASSIGN-WATCH\n" + lines.joined(separator: "\n") + "\n", suffix: ".watch")
        }
        func later(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
        }
        func oneBeat() {
            beat += 1
            var line = "  b\(beat) +\(t(ProcessInfo.processInfo.systemUptime - start))s"
            for side in [TrackSide.a, .b] {
                let n = side == .a ? "A" : "B"
                let head = e.position(of: side)
                let feed = panel.feedForCheck(side)
                let pic = feed?.actual ?? -1
                let dh = prevHead[side].map { head - $0 }
                let dp = prevPic[side].flatMap { p -> Double? in
                    guard p >= 0, pic >= 0 else { return nil }
                    return pic - p
                }
                line += " ‖ \(n)声" + (dh.map { "+\(t($0))" } ?? "+—")
                    + " 画" + (dp.map { "+\(t($0))" } ?? "+—")
                    + " 速=" + (feed.map { String(format: "%.2f", $0.rate) } ?? "—")
                    + " 放\(e.isPlaying(side) ? 1 : 0)/界面\(vm.sideIsPlaying(side) ? 1 : 0)"
                    + " 闸=\(e.isLoading(side) ? 1 : 0) 欠=\(e.hasDeferredPlay(side) ? 1 : 0)"
                    + " 挂=\(t(e.laneDuration(side))) \(panel.laneFileForCheck(side))"
                prevHead[side] = head
                prevPic[side] = pic
            }
            note(line)
        }
        func run(_ tag: String, dual: Bool, watched: TrackSide, seamless: Bool,
                 then: @escaping () -> Void) {
            beat = 0
            prevHead.removeAll()
            prevPic.removeAll()
            SettingsStore.shared.seamlessVideoSwitch = seamless
            vm.compareMode = dual ? .reference : .versionCompare
            e.stopAll()
            vm.loadTrackAFromTrack(track("a_v1.mp4"))
            vm.loadTrackBFromTrack(track("a_v2.mp4"))
            awaitForCheck("\(tag)·两轨装完", remaining: 600) {
                !e.isLoading(.a) && !e.isLoading(.b) && vm.loadPending == 0
            } then: { _ in
                vm.setActiveTrack(.a)
                vm.play()
                later(1.0) {
                    start = ProcessInfo.processInfo.systemUptime
                    note("=== \(tag)（无缝=\(seamless ? "开" : "关")）："
                         + "\(watched == .a ? "A(摆着)" : "B(后台)") 放着被换成 a_v3.mp4")
                    if watched == .a { vm.loadTrackAFromTrack(track("a_v3.mp4")) }
                    else { vm.loadTrackBFromTrack(track("a_v3.mp4")) }
                    var i = 0
                    func step() {
                        oneBeat()
                        i += 1
                        if i < 50 { later(0.1, step) } else { then() }
                    }
                    step()
                }
            }
        }
        run("单轨·摆着那轨", dual: false, watched: .a, seamless: true) {
            run("单轨·摆着那轨", dual: false, watched: .a, seamless: false) {
                run("双轨·后台那轨", dual: true, watched: .b, seamless: true) {
                    run("双轨·后台那轨", dual: true, watched: .b, seamless: false) {
                        run("双轨·摆着那轨", dual: true, watched: .a, seamless: false) {
                            // 最后一趟走「无缝开 + 摆着那一轨被换」：默认档就是开，镜像和
                            // `followPlayState` 只在这一档活着 —— 停不干净的话只有这里会露。
                            run("双轨·摆着那轨", dual: true, watched: .a, seamless: true) {
                                e.stopAll()
                                SettingsStore.shared.seamlessVideoSwitch = seamlessSnapshot
                                note("=== WATCH 跑完（无缝还原成 \(seamlessSnapshot ? "开" : "关")）")
                            }
                        }
                    }
                }
            }
        }
    }

    /// 「重新指派文件 = 这一轨立刻停」的验收探针。三种情况连着跑，每一步抄一份
    /// 引擎账（放不放 / 播放头 / 节点上挂的那份有多长 / 装载闸门）；`AB_REASSIGN=video` 那
    /// 一档再多抄一层视频账（播放器速率 + 挂的是哪一份），音频那一半的停和画面那一半的停
    /// 是两条链子，得分开看。
    ///
    /// 素材：探针目录里时长各不相同的七支（wav 30/35/40/45 秒、mp4 30/35/40 秒）。
    /// 「节点上挂的是哪一份」就用时长当证据 —— 30 变 35、40 变 45，一看数就知道换没换；
    /// 挑这么长是因为每一档都要放着走完再换，短素材会在中途自己放完、账就脏了。
    /// 这台机器注不进指针和按键，所以三种情况里的每一下都直接调界面那颗按钮走的同一个方法。
    private func runReassignCheck(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        let video = (ProcessInfo.processInfo.environment["AB_REASSIGN"] ?? "") == "video"
        let dir = ProcessInfo.processInfo.environment["AB_RS_DIR"] ?? "/tmp/ab220win/rs/"
        func track(_ name: String) -> Track { Track(url: URL(fileURLWithPath: dir + name)) }
        let a1 = video ? "a_v1.mp4" : "a_a1.wav", a2 = video ? "a_v3.mp4" : "a_a2.wav"
        let b1 = video ? "a_v2.mp4" : "a_b1.wav", b2 = video ? "a_v1.mp4" : "a_b2.wav"
        var lines: [String] = []
        func t(_ d: TimeInterval) -> String { String(format: "%.2f", d) }
        func snap(_ tag: String) {
            let e = AudioEngine.shared
            var line = "\(tag) ｜ A 放=\(e.isPlaying(.a)) 头=\(t(e.position(of: .a))) 挂=\(t(e.laneDuration(.a))) 装=\(e.isLoading(.a))"
                + " ‖ B 放=\(e.isPlaying(.b)) 头=\(t(e.position(of: .b))) 挂=\(t(e.laneDuration(.b))) 装=\(e.isLoading(.b))"
                + " ‖ 选中=\(vm.activeTrack == .a ? "A" : "B") 模式=\(vm.compareMode.rawValue)"
            if video {
                line += " ‖ 画 A rate=\(String(format: "%.2f", panel.rateForCheck(.a))) \(panel.laneFileForCheck(.a))"
                    + " · B rate=\(String(format: "%.2f", panel.rateForCheck(.b))) \(panel.laneFileForCheck(.b))"
            }
            lines.append(line)
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".reassign")
        }
        func later(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
        }
        func settled(_ body: @escaping () -> Void) {
            awaitForCheck("两轨装完", remaining: 600) {
                !AudioEngine.shared.isLoading(.a) && !AudioEngine.shared.isLoading(.b)
            } then: { _ in body() }
        }
        if video { panel.open(vm: vm) }
        func finish() {
            AudioEngine.shared.stopAll()
            lines.append("=== REASSIGN 跑完")
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".reassign")
        }
        // === 情况1：单轨视图，对正在播放的 A 轨指派新文件 ===
        // === 情况2 / 3：双轨视图，B 轨被重新指派 ===
        // === 补一条（只看画面）：看不见那一轨的「停」也要跟到底（无缝关着）===
        // 三档从后往前排：`caseOne → caseTwo → caseFour → finish`，Swift 的局部函数要先见到
        // 声明再引用，链条就按这个顺序摆。
        func caseFour() {
            AudioEngine.shared.stopAll()
            vm.setActiveTrack(.b)
            vm.toggleSide(.b)
            later(1.0) {
                snap("4·B 摆着播")
                vm.setActiveTrack(.a)
                later(1.0) {
                    snap("4·切到 A（B 收进看不见那层）")
                    vm.toggleSide(.b)
                    snap("4·停 B 的声音（画面该跟着停）")
                    later(1.0) { snap("4·一秒后 B 的画面"); finish() }
                }
            }
        }
        func caseTwo() {
            AudioEngine.shared.stopAll()
            vm.compareMode = .reference
            vm.loadTrackAFromTrack(track(a1))
            vm.loadTrackBFromTrack(track(b1))
            settled {
                vm.play()
                snap("2·两轨同时播")
                later(1.0) {
                    vm.loadTrackBFromTrack(track(b2))
                    snap("2·指派 B 新文件那一拍（A 该照放）")
                    vm.setActiveTrack(.b)
                    snap("2·切到 B（既不该有旧也不该有新）")
                    settled {
                        snap("2·B 装完（还是停着）")
                        vm.toggleSide(.b)
                        snap("3·独立按钮起 B（该是 \(b2)）")
                        later(1.0) {
                            snap("3·B 在后台走")
                            vm.setActiveTrack(.b)
                            snap("3·切到 B")
                            later(1.0) {
                                snap("3·切过去还在走")
                                if video { caseFour() } else { finish() }
                            }
                        }
                    }
                }
            }
        }
        func caseOne() {
            vm.compareMode = .versionCompare
            AudioEngine.shared.stopAll()
            vm.loadTrackAFromTrack(track(a1))
            vm.loadTrackBFromTrack(track(b1))
            settled {
                snap("1·起步前")
                vm.setActiveTrack(.a)
                vm.play()
                snap("1·刚按下播放")
                later(1.0) {
                    snap("1·A 走起来了（挂的该是 \(a1)）")
                    vm.loadTrackAFromTrack(track(a2))
                    snap("1·指派新文件那一拍")
                    vm.togglePlayPause()
                    snap("1·装载中再按一次播放（这一轨该按不动）")
                    settled {
                        snap("1·新文件装完")
                        vm.togglePlayPause()
                        snap("1·装完再按播放（该放 \(a2)）")
                        later(1.0) {
                            snap("1·走起来了（挂的该是 \(a2)）")
                            caseTwo()
                        }
                    }
                }
            }
        }
        caseOne()
    }

    /// 视频窗口记忆那几条落成数字。前三条喂画面尺寸走 `fitWindow` 那一段
    /// 本身（真凑两份不同分辨率的视频要现编素材，而这一段只吃「画面宽高 + 当前窗口框」两个
    /// 数），最后一条是真换轨。要看的是：
    /// · 同一档比例、分辨率减半 → 缩放比不变，窗口跟着画面等比缩，锚点（midX、顶边）一动不动；
    /// · 换一档比例 → 高度和垂直位置一动不动，只有宽度按新比例重算，midX 照旧一动不动；
    /// · 关窗再开、以及「假装重启」把账读回来 → 框和上一次一模一样；
    /// · F 真换到另一轨 → 两轨画面同一档尺寸时该一动不动。
    private var vmMemLines: [String] = []

    private func vmMemPlace(_ tag: String) {
        let p = VideoPanelController.shared.windowPlaceForCheck
        let f = p.frame
        vmMemLines.append("\(tag): 框=\(Int(f.width))×\(Int(f.height))@(\(Int(f.minX)),\(Int(f.minY)))"
            + " midX=\(String(format: "%.1f", f.midX)) 顶边=\(String(format: "%.1f", f.maxY)) 屏=\(p.screen)")
    }

    private func reportVideoMemoryForCheck(_ settled: Bool) {
        guard let vm else { return }
        guard settled else {
            writeDiag("VIDEOMEMORY: 没等到画面摆上，跳过\n", suffix: ".videomemory")
            return
        }
        let panel = VideoPanelController.shared
        let path = (vm.activeTrack == .a ? vm.trackA : vm.trackB)?.url.path
        let facts = path.flatMap { vm.videoFacts[$0] } ?? VideoFacts()
        vmMemLines = []
        vmMemPlace("开窗（真画面 \(Int(facts.width))×\(Int(facts.height))）")
        vmMemLines.append("同比例·半分辨率: "
            + panel.fitForCheck(width: facts.width / 2, height: facts.height / 2))
        vmMemPlace("同上一步（锚点该照旧）")
        vmMemLines.append("换一档比例·方: " + panel.fitForCheck(width: 1000, height: 1000))
        vmMemLines.append("回原画面: " + panel.fitForCheck(width: facts.width, height: facts.height))
        vmMemLines.append("账: " + panel.memoryForCheck)
        panel.close()
        vmMemPlace("关窗后")
        panel.open(vm: vm)
        vmMemPlace("再开（同一份文件，该一动不动）")
        vmMemLines.append("假重启: " + panel.restoreForCheck())
        vmMemPlace("假重启后")
        // 真换轨：present() 排在 Combine 的 receive(on: main) 上，等一拍再读框。
        vm.switchTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let other = (vm.activeTrack == .a ? vm.trackA : vm.trackB)?.url.path
            let f2 = other.flatMap { vm.videoFacts[$0] } ?? VideoFacts()
            self.vmMemPlace("F 换到另一轨（画面 \(Int(f2.width))×\(Int(f2.height))）")
            self.writeDiag("VIDEOMEMORY:\n" + self.vmMemLines.joined(separator: "\n") + "\n",
                           suffix: ".videomemory")
        }
    }

    // 「差 −0.11 s」有三种来路，光看末值分不出来：① seek 落地要吃掉一段预备时间（差在
    // 吸附之后当场长回来，之后不动）② 播放器走得比引擎慢（差一直线性长大）
    // ③ 引擎报的是预约出去的位置、比听到的声音超前（那样画面其实没迟到，只是尺子不一样）。
    // 所以每 0.1 s 把「墙钟 + 引擎位 + 播放器位 + 播放器的表速率」四件一起抄下来：
    // ①看吸附头几拍的形状，②看斜率是不是 1，③的话两者的斜率都该是 1、只差一个常数。
    private struct vcPair { let now: Double, expected: Double, actual: Double, rate: Float }
    private var vcPairs: [vcPair] = []

    private func vcRateLoop(_ vm: PlayerViewModel, remaining: Int, then: @escaping () -> Void) {
        let side = vm.activeTrack
        if let r = VideoPanelController.shared.syncReadings(side) {
            vcPairs.append(.init(now: ProcessInfo.processInfo.systemUptime,
                                 expected: r.expected, actual: r.actual,
                                 rate: VideoPanelController.shared.rateForCheck(side)))
        }
        guard remaining > 1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: then)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.vcRateLoop(vm, remaining: remaining - 1, then: then)
        }
    }

    /// 把这一串数打出来：每拍一行（引擎、播放器、差），末尾两行是各自对墙钟的速率。
    /// 速率对不上 1 就是真在拖；速率都是 1 而差是常数，就是落地那一下吃掉的。
    /// 一拍 0.1 s，串太长没人看，超过 24 拍就每四拍挑一行（头尾一定留）。
    private func vcPairsReport(_ tag: String) {
        let first = vcPairs.first?.now ?? 0
        let every = vcPairs.count > 24 ? 4 : 1
        for (i, p) in vcPairs.enumerated() where i % every == 0 || i == vcPairs.count - 1 {
            vcNote("\(tag)·拍\(i + 1) 墙=+\(String(format: "%.2f", p.now - first))s "
                   + "引擎=\(String(format: "%.3f", p.expected)) "
                   + "播放器=\(String(format: "%.3f", p.actual)) "
                   + "差=\(String(format: "%+.3f", p.actual - p.expected))"
                   + " 表=\(String(format: "%.3f", p.rate))")
        }
        guard let a = vcPairs.first, let b = vcPairs.last, b.now > a.now else { return }
        let span = b.now - a.now
        vcNote("\(tag)·速率: 引擎=\(String(format: "%.4f", (b.expected - a.expected) / span)) "
               + "播放器=\(String(format: "%.4f", (b.actual - a.actual) / span)) "
               + "(墙钟走了 \(String(format: "%.2f", span))s，两者都该是 1.0000)")
        vcPairs = []
    }

    /// 探针走位表：一段跑完自己喊下一段，别把七步写成七层闭包。
    private var vcStage = 0

    /// 重载风暴那支探针的账（`AB_PANEL=reload`）。走位要跨好几次「等闸门放开」的回话，
    /// 局部函数嵌不进逃逸闭包（Swift 不许逃逸闭包引用非逃逸的局部函数），所以这几本记在属性上。
    private var rsVM: PlayerViewModel?
    private var rsFiles: [URL] = []
    private var rsRound = 0
    private var rsRounds = 0
    private var rsGap = 0.5
    private var rsRush = false
    private var rsKeySpace = false
    private var rsBeatRound = 0
    private var rsLines: [String] = []
    private var rsStalled: [String] = []
    private var rsPrevHead: [TrackSide: Double] = [:]
    private var rsPrevPic: [TrackSide: Double] = [:]
    /// 上一拍已经报过几笔「起播被按回」—— 只报新增的那几笔。
    private var rsSeenRejects = 0
    /// 采样的那 0.12 s 里空转的是主 run loop，别的走位可能插进来再采一次 —— 挡一下。
    private var rsCapturing = false
    /// 闸门放开后要是这一轨还没起，补按第二下（`AB_RELOAD_ENSURE=1`）。
    private var rsEnsure = false
    /// 轻账（`AB_RELOAD_LIGHT=1`）：一笔都不碰 `AVPlayer.currentTime()`／`timeControlStatus`。
    /// 重载风暴五次跑里有四次整进程冻死，栈尖都在探针自己那一笔 `currentTime()` 上
    /// （主线程 sync 进 item 的 accessor 队列，那一队正卡在 CoreMedia 的一把锁上）——
    /// 界面那一头本来也要读这一笔（`tick`／`align`），所以「是不是只有探针读才冻」得单独量一次。
    /// 轻账下主线程只剩生产那几笔读，能不能冻住看 `.watch` 那本 0.5 s 一拍的主队列账。
    private var rsLight = false
    /// 20 Hz 那一拍：量「旗标说在放、画面却没在放」一次能停多久。1 s 那一拍太粗 ——
    /// 补放的下一拍就落在两拍中间，看结果那一眼分不清「冻了一秒」和「冻了 30 ms」。
    private var rsFreezeTimer: Timer?
    private var rsFreezeStart: [TrackSide: Double] = [:]
    private var rsFreezeMax: [TrackSide: Double] = [:]
    private var rsFreezeRuns: [TrackSide: Int] = [:]

    /// 「随便重载入几次视频就全播不了」：照着人手的节奏一遍一遍换曲（A、B 轮流，素材轮着上），
    /// 每一轮换完立刻按播放，等这一轨的装载闸门放开，再抄两笔 —— 装载闸门上记了几笔、闸门按住时
    /// 欠没欠起播、引擎自己跑没跑、以及**最要紧的那一条**：这一秒里声音的播放头走了多少、画面的
    /// 表走了多少。一次都不停、走到第 N 轮两头忽然不动，那一眼就能看出是被哪一格按住的。
    ///
    /// 素材 `AB_RELOAD_FILES`（逗号分隔绝对路径）、`AB_RELOAD_N` 轮数（默认 6）、
    /// `AB_RELOAD_GAP` 每轮放开后再放几秒才换下一次（默认 0.5）。账落 `<base>.reload`。
    private func runReloadStormCheck(_ vm: PlayerViewModel) {
        let env = ProcessInfo.processInfo.environment
        rsFiles = (env["AB_RELOAD_FILES"] ?? "").split(separator: ",").map(String.init)
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        rsRounds = Int(env["AB_RELOAD_N"] ?? "") ?? 6
        rsGap = Double(env["AB_RELOAD_GAP"] ?? "") ?? 0.5
        rsRush = (env["AB_RELOAD_RUSH"] ?? "") == "1"
        rsKeySpace = (env["AB_RELOAD_KEY"] ?? "") == "space"
        rsEnsure = (env["AB_RELOAD_ENSURE"] ?? "") == "1"
        rsLight = (env["AB_RELOAD_LIGHT"] ?? "") == "1"
        rsRound = 0
        rsLines = []; rsStalled = []; rsPrevHead = [:]; rsPrevPic = [:]
        rsVM = vm
        let e = AudioEngine.shared
        let panel = VideoPanelController.shared
        guard !rsFiles.isEmpty else { rsNote("RELOAD: 缺 AB_RELOAD_FILES（或文件都不在）"); return }
        if let v = env["AB_SEAMLESS"] { SettingsStore.shared.seamlessVideoSwitch = v != "0" }
        panel.open(vm: vm)
        // 另开一本独立账：每 0.5 s 一拍抄「主队列排到了几笔 / run loop 源盘排到了几笔」。
        // 每一趟装载到底是在后台线程读的、还是回到了主线程上，看这一本就知道；反馈里那句
        // 「播不了」要是主线程被按住，也记在这一本上。
        hvStart = ProcessInfo.processInfo.systemUptime
        hvWatchStart()
        rsNote("RELOAD: \(rsRounds) 轮·闸门放开后再放 \(rsT(rsGap))s·无缝=\(SettingsStore.shared.seamlessVideoSwitch ? "开" : "关") "
               + "账=\(rsLight ? "轻(不碰播放器)" : "全") "
               + "引擎跑=\(e.engineRunningForCheck ? 1 : 0) 素材=\(rsFiles.map { $0.lastPathComponent }.joined(separator: ","))")
        // 先让第一份素材装完，免得第 1 轮的量全花在等闸门上（要量的不是这一次）。
        awaitForCheck("首份素材装完", remaining: 600) {
            vm.loadPending == 0 && !e.isLoading(.a) && !e.isLoading(.b)
        } then: { _ in
            e.clearPlaySideRejects()
            panel.clearPicControlForCheck()
            panel.clearClockLedgerForCheck()
            if !self.rsLight { panel.watchPicStatusForCheck() }
            self.rsSeenRejects = 0
            if !self.rsLight {
                let sampler = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.rsPicSample() }
                RunLoop.main.add(sampler, forMode: .common)
                self.rsFreezeTimer = sampler
            }
            self.rsRunRound()
        }
    }

    /// 一轮：把 `round % 2` 那一轨换成 `files[round % files.count]`，换完 0.05 s 立刻按播放
    /// （那一趟就是扔完文件按空格）。
    /// 两种走位：`AB_RELOAD_RUSH=1` 不等闸门、每 `AB_RELOAD_GAP` 秒换一次曲（抢跑：上一份还在装
    /// 就换下一份，闸门那本账最容易在这种摆法下漏），跑完连抄 8 秒收尾账；
    /// 默认等这一轨的闸门放开 —— 不等就量不到「放开了却放不响」那一档，那是比抢跑更坏的形状。
    private func rsRunRound() {
        guard let vm = rsVM else { return }
        let e = AudioEngine.shared
        guard rsRound < rsRounds else {
            guard rsRush else {
                rsFreezeTimer?.invalidate(); rsFreezeTimer = nil
                rsNote("RELOAD: === 跑完 \(rsRound) 轮，放着不走 \(rsStalled.count) 笔"
                       + (rsStalled.isEmpty ? "" : " ｜ " + rsStalled.suffix(10).joined(separator: " ; ")))
                if !rsLight { rsFreezeReport("RELOAD: ") }
                return
            }
            rsNote("— \(rsRounds) 轮抢跑完，再按一次播放，连抄 8 秒收尾账")
            vm.play()
            rsEnd(8)
            return
        }
        let round = rsRound
        rsRound += 1
        rsBeatRound = round + 1
        let side: TrackSide = round % 2 == 0 ? .a : .b
        let url = rsFiles[round % rsFiles.count]
        rsNote("— 第 \(round + 1) 轮：\(side == .a ? "A" : "B") 轨换成 \(url.lastPathComponent)"
               + "｜换之前 闸门=\(e.loadGateForCheck(.a))/\(e.loadGateForCheck(.b))")
        if side == .a { vm.loadTrackAFromTrack(Track(url: url)) } else { vm.loadTrackBFromTrack(Track(url: url)) }
        rsPrevHead[side] = nil
        rsPrevPic[side] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.rsPress(vm) }
        if rsRush {
            // 抢跑那一档也要有一拍落在两次换曲中间 —— 只有收尾那 8 拍的话，
            // 「从第几轮开始死的」就只剩收尾那一句，认不出是哪一次换曲按下去的。
            DispatchQueue.main.asyncAfter(deadline: .now() + rsGap * 0.5) { self.rsBeat(side, "抢跑\(round + 1)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + rsGap) { self.rsRunRound() }
            return
        }
        awaitForCheck("第 \(round + 1) 轮闸门放开", remaining: 600, { !e.isLoading(side) }) { settled in
            self.rsNote("  第\(round + 1)轮 闸门=\(settled ? "放开" : "还按着") 换完一按 放\(side == .a ? "A" : "B")=\(e.isPlaying(side) ? 1 : 0)")
            // 「换完文件按空格要听得见」：第一下要是对面那一轨正在放，它按的是全停，
            // 这一轨压根没起 —— 补第二下才起播。`AB_RELOAD_ENSURE=1` 就是补这第二下，
            // 补完声音那一格才有意义（全停的时候峰 0 不是 bug）。
            if self.rsEnsure, !e.isPlaying(side) { self.rsPress(vm) }
            self.rsBeat(side, "装完+1s")
            self.rsSound("第\(round + 1)轮·装完")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.rsBeat(side, "装完+2s") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + self.rsGap) { self.rsRunRound() }
        }
    }

    /// 手上那一下：空格走 `togglePlayPause`（走带按钮同一个），另一档是 `play()`。
    private func rsPress(_ vm: PlayerViewModel) {
        if rsKeySpace { vm.togglePlayPause() } else { vm.play() }
    }

    /// 两拍之间的机器负载：CPU（100 % = 一整核）和常驻内存。
    /// 「重载几次就全播不了」还有一种不是逻辑死的死法 —— 机器被自己压垮了：每一趟装载都要
    /// 把整份文件读成 PCM（这一支是 44 MB），再加上 4K 解码，CPU 顶到墙上时样本一样出不来。
    private var rsCpuSecs = 0.0
    private var rsCpuAt = 0.0
    private func rsLoad() -> String {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let secs = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1e-6
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let rss = kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        let now = ProcessInfo.processInfo.systemUptime
        var cpu = "—"
        if rsCpuAt > 0, now > rsCpuAt {
            cpu = String(format: "%.0f%%", (secs - rsCpuSecs) / (now - rsCpuAt) * 100)
        }
        rsCpuSecs = secs
        rsCpuAt = now
        return "CPU=\(cpu) 驻留=\(String(format: "%.0f", rss))MB"
    }

    /// 20 Hz 抄一眼「该放却没放」：起点、回数的账自己留着，最长那一截在最后报。
    /// 每一截超过 0.3 s 当场记一行 —— 重载的轮次和这一眼对得上，才知道是哪一趟换曲冻的。
    private func rsPicSample() {
        guard let vm = rsVM else { return }
        let panel = VideoPanelController.shared
        let now = ProcessInfo.processInfo.systemUptime
        for side in [TrackSide.a, .b] {
            guard let frozen = panel.picFrozenForCheck(side) else { continue }
            if frozen {
                if rsFreezeStart[side] == nil {
                    rsFreezeRuns[side, default: 0] += 1
                    rsFreezeStart[side] = now
                }
            } else if let start = rsFreezeStart[side] {
                let dur = now - start
                if dur >= rsFreezeMax[side, default: 0] { rsFreezeMax[side] = dur }
                if dur > 0.3 {
                    rsNote("  画面冻 \(side == .a ? "A" : "B") \(rsT(dur))s（起于 +\(rsT(start - hvStart))s，"
                        + "第\(rsBeatRound)轮 摆=\(panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占") "
                        + "\(panel.picStateForCheck(side))）")
                }
                rsFreezeStart[side] = nil
            }
        }
    }

    private func rsFreezeReport(_ prefix: String) {
        let text: [String] = [TrackSide.a, .b].map { side in
            "\(side == .a ? "A" : "B")：\(rsFreezeRuns[side, default: 0]) 回·最长 "
                + rsT(rsFreezeMax[side] ?? 0) + "s"
        }
        rsNote("\(prefix)画面冻住（旗标在放、timeControlStatus 不在放）‖ \(text.joined(separator: " ‖ "))")
    }

    /// 抢跑那一档的收尾：每 1 s 一笔，连 8 笔 —— 闸门漏了的话这一串会一直显示按着。
    private func rsEnd(_ remaining: Int) {
        guard remaining > 0 else {
            rsFreezeTimer?.invalidate(); rsFreezeTimer = nil
            rsNote("RELOAD: === 抢跑跑完 \(rsRounds) 轮，放着不走 \(rsStalled.count) 笔"
                   + (rsStalled.isEmpty ? "" : " ｜ " + rsStalled.suffix(10).joined(separator: " ; ")))
            rsFreezeReport("RELOAD: ")
            return
        }
        rsBeat(.a, "收尾\(9 - remaining)")
        rsSound("收尾\(9 - remaining)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.rsEnd(remaining - 1) }
    }

    private func rsT(_ d: Double) -> String { String(format: "%.2f", d) }

    /// 采 0.12 s 的输出（抽头在 EQ 之后、去输出之前，就是耳朵那一份），报峰。
    /// 这一格是整支探针里唯一能分清「在放」和「听得见」的：播放头、引擎旗标、音量都可能是
    /// 账面数字，只有峰 0 是「一个字都没有」。
    private func rsSound(_ tag: String) {
        guard !rsCapturing else { return }
        rsCapturing = true
        defer { rsCapturing = false }
        let e = AudioEngine.shared
        e.debugStartCapture()
        _ = e.debugWaitForCapture(frames: Int(e.debugConnectionRate * 0.12), timeout: 2.5)
        let c = e.debugFinishCapture()
        let peak = (c.ch0 + c.ch1).map { abs($0) }.max() ?? 0
        // 「该不该有声」先自己判：这一轨在放、且 A/B 选择器正好指着它，耳朵那一份才该有峰。
        let audible = (e.isPlaying(.a) && e.volumeA > 0) || (e.isPlaying(.b) && e.volumeB > 0)
        let verdict = audible ? (peak < 0.001 ? "该有声却没有(静音!)" : "有声") : "没人放或没选中"
        rsNote("  \(tag) 出声: 峰=\(String(format: "%.4f", peak)) [\(verdict)] 采=\(c.frameCount)帧 "
            + "回调=\(c.callbacks) 空窗=\(c.gaps) ‖ \(e.laneSelectorForCheck) "
            + "放A=\(e.isPlaying(.a) ? 1 : 0) 放B=\(e.isPlaying(.b) ? 1 : 0)")
    }

    private func rsNote(_ line: String) {
        rsLines.append("+\(rsT(ProcessInfo.processInfo.systemUptime - hvStart))s 拍=\(hvWatchBeats) \(line)")
        writeDiag(rsLines.joined(separator: "\n") + "\n", suffix: ".reload")
    }

    /// 一轨的一笔：闸门 / 欠放 / 引擎旗标和界面旗标 / 声音头 / 节点上挂的那份，
    /// 再加画面那一台的表、速率、item 状态和缓冲账。
    private func rsAccount(_ side: TrackSide) -> String {
        guard let vm = rsVM else { return "—" }
        let e = AudioEngine.shared
        let panel = VideoPanelController.shared
        let name = side == .a ? "A" : "B"
        // 轻账：`feedForCheck`／`picStateForCheck` 那一串读的是播放器的表和 item 状态，
        // 正是它们把主线程送进 MediaToolbox 的锁里 —— 一笔不碰。
        let feed = rsLight ? nil : panel.feedForCheck(side)
        let pic = feed.map { f in "表=\(rsT(f.actual)) 速=\(String(format: "%.2f", Double(f.rate))) "
                + "态=\(f.status) 备=\(f.keepUp ? 1 : 0) 空=\(f.empty ? 1 : 0) 满=\(rsT(f.ahead)) "
                + panel.picStateForCheck(side) }
            ?? "没绑"
        return "\(name)[闸门\(e.loadGateForCheck(side)) 欠放\(e.hasDeferredPlay(side) ? 1 : 0) "
            + "缓=\(e.bufferForCheck(side)) "
            + "放\(e.isPlaying(side) ? 1 : 0)/界面\(vm.sideIsPlaying(side) ? 1 : 0) "
            + "头=\(rsT(e.position(of: side))) 挂=\(rsT(e.laneDuration(side)))] "
            + "\(panel.laneFileForCheck(side))[\(pic)]"
    }

    /// 一笔账：两轨各自的「这一拍声音走了多少 / 画面走了多少」+ 全部闸门账。
    /// 「放着不走」= 引擎旗标说在放，可这一秒里播放头寸步不移 —— 那就是裁定的播不了。
    ///
    /// 播放头走了不等于出声：这个应用一次只给一条轨供电（非编辑图里 `playerX.volume` 是 0/1），
    /// 所以每一拍另外采 0.2 s 的输出量一次峰。峰 0 而两轨都在放，就是「全播不了」的那一种死法。
    private func rsBeat(_ reassigned: TrackSide, _ tag: String) {
        guard let vm = rsVM else { return }
        let e = AudioEngine.shared
        let panel = VideoPanelController.shared
        var line = "  第\(rsRound + 1)轮 \(tag)"
        for side in [TrackSide.a, .b] {
            let name = side == .a ? "A" : "B"
            let head = e.position(of: side)
            let pic = rsLight ? -1 : (panel.feedForCheck(side)?.actual ?? -1)
            let dHead = rsPrevHead[side].map { head - $0 }
            let dPic = rsPrevPic[side].flatMap { $0 >= 0 && pic >= 0 ? pic - $0 : nil }
            if let d = dHead { line += " \(name)声音+\(rsT(d))" }
            if let d = dPic { line += " 画面+\(rsT(d))" }
            if let d = dHead, e.isPlaying(side), abs(d) < 0.05 {
                let why = e.isLoading(side) ? "闸门按着" : (e.hasDeferredPlay(side) ? "欠着放" : "")
                rsStalled.append("第\(rsRound + 1)轮\(tag) \(name)不走[\(why) 挂=\(rsT(e.laneDuration(side))) 画\(dPic.map { rsT($0) } ?? "—")]")
            }
            rsPrevHead[side] = head
            rsPrevPic[side] = pic
        }
        line += " ‖ \(rsAccount(.a)) ‖ \(rsAccount(.b))"
        line += " ‖ 引擎跑=\(e.engineRunningForCheck ? 1 : 0) 装载在途=\(vm.loadPending) "
            + rsLoad() + " "
        line += "\(e.laneSelectorForCheck) "
        line += "摆=\(panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占") "
        line += "共=\(panel.sharingForCheck ? "一条流" : "两台")"
        // 起播被哪一条 guard 按回去的：这一串只在「上一拍到现在新发生了拒绝」时才附一句，
        // 否则每一拍都在重复同一句老账，真正的第 N 轮那一眼就淹了。
        let rejects = e.playSideRejectsForCheck
        if rejects.count > rsSeenRejects {
            line += " ‖ 起播被按回: " + rejects.suffix(max(0, rejects.count - rsSeenRejects)).joined(separator: "；")
            rsSeenRejects = rejects.count
        }
        // 画面那两台是谁按下去的、谁来看过：把最近 12 笔随每一拍一起抄出来。
        line += " ‖ 画面开关: \(panel.picControlTailForCheck(12))"
        // 生产链路自己读表那两笔（对表、观众帧）的笔数与单笔最长 —— 探针那一头的读数全走影子账，
        // 一笔不碰同步读，所以这一本量的就是界面自己会不会被按住。
        line += " ‖ 生产读表: \(panel.clockLedgerForCheck)"
        rsNote(line)
    }


    private func vcWait(_ seconds: Double, _ then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: then)
    }

    /// 连着抄 `beats` 拍（每 0.1 s 一对），抄完打账再走下一段。
    /// 顺带记这一段落了几个硬 seek —— 调速那一套要是管用，播中稳着走的那串该是 0。
    private func vcRate(_ vm: PlayerViewModel, beats: Int, tag: String) {
        vcPairs = []
        let seeksAtStart = VideoPanelController.shared.alignCountForCheck
        vcRateLoop(vm, remaining: beats) {
            self.vcPairsReport(tag)
            self.vcNote("\(tag)·这一段落了 "
                        + "\(VideoPanelController.shared.alignCountForCheck - seeksAtStart) 次硬 seek")
            self.vcStage += 1
            self.vcRunStage(vm)
        }
    }

    /// 声音比播放头晚多久出喇叭：引擎报的是「已经渲染进图的那一格」，这一段还要走过
    /// 设备延迟 + 安全余量 + 一块缓冲才听得到。画面的那 −0.1 s 到底是不是真迟到，
    /// 得拿这个数比。
    private func vcOutputLatency() -> String {
        func prop<T>(_ device: AudioDeviceID, _ selector: AudioDevicePropertyID, _ out: inout T) -> Bool {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &out) == noErr
        }
        var device = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &size, &device) == noErr, device != 0 else {
            return "读不到输出设备"
        }
        var latency = UInt32(0), safety = UInt32(0), frames = UInt32(0), rate = Float64(0)
        let okL = prop(device, kAudioDevicePropertyLatency, &latency)
        let okS = prop(device, kAudioDevicePropertySafetyOffset, &safety)
        let okF = prop(device, kAudioDevicePropertyBufferFrameSize, &frames)
        let okR = prop(device, kAudioDevicePropertyNominalSampleRate, &rate)
        guard okL, okF, okR, rate > 0 else { return "读不到延迟参数 l=\(okL) f=\(okF) r=\(okR)" }
        let ms = Double(latency) / 1e6 + Double(okS ? safety : 0) / 1e6 + Double(frames) / rate * 1000
        return String(format: "设备延迟 %.1f ms ＋安全余量 %.1f ms ＋一块缓冲 %.1f ms (%u 帧 @ %.0f Hz) ＝ %.1f ms",
                      Double(latency) / 1e6, Double(okS ? safety : 0) / 1e6,
                      Double(frames) / rate * 1000, frames, rate, ms)
    }

    /// 探针开的副窗跟着主窗去同一张屏。`center()` 认的是那一刻的 `NSScreen.main`
    /// （鼠标在哪张屏就算哪张），一不小心就把测试窗落在工作屏上。
    /// `NSApp.mainWindow` 在没有真焦点的探针启动里是 nil，所以要退回 `MainWindow` 那一本账。
    private func followMainScreen(_ window: NSWindow?) {
        guard let window,
              let screen = (MainWindow.windowForCheck ?? NSApp.mainWindow)?.screen ?? NSScreen.main
        else { return }
        let f = window.frame
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - f.width / 2,
                                      y: screen.frame.midY - f.height / 2 + screen.frame.height * 0.06))
    }

    private func vcRunStage(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        let side = vm.activeTrack
        switch vcStage {
        case 0:
            // 起播之前抄的数都是停着的，那一串没有意义，所以先等引擎真跑起来。
            awaitForCheck("播放中", remaining: 200, { vm.sideIsPlaying(vm.activeTrack) }) { _ in
                // 再让开窗 / 读参数 / 挂 item 那几下 seek 落完（它们都排在快照之前），
                // 这一段才只算调速那一套：这一串该是 0 次硬 seek。
                self.vcWait(2.2) {
                    self.vcNote("②a 播放中·稳态连着抄 40 拍（小差靠调速追，这一串该收进半帧、且一次硬 seek 都不落）")
                    self.vcNote("输出延迟账: \(self.vcOutputLatency())")
                    self.vcRate(vm, beats: 40, tag: "②a")
                }
            }
        case 1:
            vcNote("②b 播中拖一次播放头到 60 s（大跳当场吸附，之后连抄 70 拍看调速把那 0.1 s 收回收拢）")
            vm.seekSide(side, to: 60)
            vcRate(vm, beats: 70, tag: "②b")
        case 2:
            vcNote("②c 播中硬落一次 seek，记「发出 / 完成 / 完成后 0.3 s」三笔（量的就是 seek 自己吃掉的那一段，硬 seek 容差按它定）")
            panel.probeSeekForCheck(side) { self.vcNote($0) }
            vcRate(vm, beats: 10, tag: "②c")
        case 3:
            vm.pause()
            vcWait(0.3) {
                self.vcSync(vm, "②d 暂停后读（两边都停住，读的是位置本身差多少）")
                self.vcStage += 1
                self.vcRunStage(vm)
            }
        case 4:
            vm.seekSide(vm.activeTrack, to: 30)
            vcWait(0.35) {
                self.vcSync(vm, "③暂停后拖到 30 s（该当场吸附）")
                self.vcStage += 1
                self.vcRunStage(vm)
            }
        case 5:
            vm.switchTrack()
            // 多等一会儿再读：这一档要留时间给截图拍下「F 之后画面摆的是 B」。
            vcWait(1.5) {
                self.vcNote("F 之后: 画面摆的是=\(panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占位") "
                            + " 标题=\(panel.panelTitleForCheck) 占位=\(panel.isShowingPlaceholderForCheck ? "在" : "不在")")
                self.vcSync(vm, "④换到另一轨")
                self.vcStage += 1
                self.vcRunStage(vm)
            }
        case 6:
            vm.setEditMode(true)
            vcWait(0.2) {
                self.vcNote("⑤进编辑模式: 窗口可见=\(panel.isVisible ? "是" : "否")（该否）")
                self.vcStage += 1
                self.vcRunStage(vm)
            }
        case 7:
            vm.setEditMode(false)
            self.vcNote("⑥退编辑模式: 窗口可见=\(panel.isVisible ? "是" : "否")（该否，不自动重开）")
            vm.toggleVideo()
            self.vcNote("⑦⌘6 再开: 窗口可见=\(panel.isVisible ? "是" : "否")（该是）")
            vm.setCompareMode(.abx)
            self.vcNote("⑧开 ABX: 窗口可见=\(panel.isVisible ? "是" : "否")（该否）")
            vm.setCompareMode(.versionCompare)
            vm.toggleVideo()
            self.vcNote("⑨回单轨视图再开: 窗口可见=\(panel.isVisible ? "是" : "否")")
            panel.close()
        default:
            break
        }
    }

    /// 全程：参数 → 播放中漂移 → 暂停拖播放头 → F 换画面 → 编辑模式收窗 → 退模式能再开 → ABX 收窗。
    private func runVideoCheck(_ vm: PlayerViewModel) {
        vcLines = []
        vcPairs = []
        vcStage = 0
        let panel = VideoPanelController.shared
        awaitForCheck("两轨就位", remaining: 1_600, {
            vm.trackA != nil && vm.trackB != nil && vm.loadPending == 0
        }) { [weak self] settled in
            guard let self else { return }
            if !settled { self.vcNote("（等两轨就位超时，后面的读数不可信）") }
            // 这时候主窗口已经摆到 AB_WINDOW 指定的那张屏上了，副窗跟着它走，
            // 别把测试窗留在工作屏上。
            self.followMainScreen(panel.panel)
            self.vcFacts(vm)
            self.vcNote("窗口: 可见=\(panel.isVisible ? "是" : "否") 标题=\(panel.panelTitleForCheck) "
                        + "框=\(NSStringFromRect(panel.panelFrameForCheck)) "
                        + "画面摆的是=\(panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占位")")
            // 截图要按 Cocoa 那套（左下角原点）换成 screencapture 的（左上角、主屏为 0），
            // 所以顺手把每扇屏的框也抄下来，不然算不出主屏多高。
            self.vcNote("屏: \(NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: " "))")
            self.vcRunStage(vm)
        }
    }

    // MARK: 无缝切轨探针（AB_PANEL=seamless · #if DEBUG）
    //
    // 黑不黑隔着屏幕只能靠眼睛，所以这一支量的是「黑帧的来路」本身，三个数：
    // ①换轨**前**看不见那一轨挂没挂播放器、摆没摆准（摆准了才有帧可接）；
    // ②换轨那一下落了几次硬 seek（0 次 = 那一下压根没有愣）；
    // ③换轨后 0.06 s 新摆上来那一轨的位置差（老办法这一段还在 seek 里头）。
    // 同一支跑两遍（`AB_SEAMLESS=0` / `1`）就是两副面孔的对照。
    // `AB_PANEL=seamlessloop` 不抄读数，只每隔 1.2 s 真换一次轨，供外面录窗数黑帧。

    private var scLines: [String] = []
    private var scStage = 0
    private var scSeeksBefore = 0

    private func scNote(_ line: String) {
        scLines.append(line)
        writeDiag(scLines.joined(separator: "\n") + "\n", suffix: ".seamless")
    }

    /// 某一轨的同步账（和 `vcSync` 同一串数，区别是这里按位点读、不跟着主动轨跑）。
    /// 「对引擎」那一格含着一块设备延迟（量的 −0.1 s 上下），两轨一起带着，
    /// 所以它不是换轨那一跳的尺 —— 那一跳看 `scGap`。
    private func scSide(_ vm: PlayerViewModel, _ side: TrackSide, _ tag: String) {
        let panel = VideoPanelController.shared
        let name = side == .a ? "A" : "B"
        guard let r = panel.syncReadings(side) else {
            scNote("\(tag) \(name)轨: 读不到（没画面，或还没挂上 item）")
            return
        }
        let delta = r.actual - r.expected
        scNote("\(tag) \(name)轨: 引擎要=\(String(format: "%.3f", r.expected))s "
               + "画在=\(String(format: "%.3f", r.actual))s 对引擎=\(String(format: "%+.3f", delta))s "
               + "rate=\(String(format: "%.2f", Double(panel.rateForCheck(side))))")
    }

    /// 换轨那一跳有多高：两轨「实际画在哪」之差，再减掉两轨本该有的偏移差
    /// （`expected` 那两数之差就是 time trim 那本账）。剩下的就是按下 F 那一下画面跳多远，
    /// 换算成帧 —— 这一条才是「无缝」的尺。
    private func scGap(_ vm: PlayerViewModel, _ tag: String) {
        let panel = VideoPanelController.shared
        guard let a = panel.syncReadings(.a), let b = panel.syncReadings(.b) else {
            scNote("\(tag) 帧距: 读不全（有一轨没画面或没挂 item）")
            return
        }
        let gap = (b.actual - a.actual) - (b.expected - a.expected)
        let fps = a.halfFrame > 0 ? 0.5 / a.halfFrame : 24
        scNote("\(tag) 帧距: \(String(format: "%+.3f", gap))s ≈ \(String(format: "%+.1f", gap * fps)) 帧"
               + "（@\(String(format: "%.0f", fps)) fps，无缝那档该贴着 0；老办法这一格是「看不见那一轨停在老地方」）")
    }

    private func runSeamlessCheck(_ vm: PlayerViewModel) {
        scLines = []
        scStage = 0
        let panel = VideoPanelController.shared
        awaitForCheck("两轨就位", remaining: 1_600, {
            vm.trackA != nil && vm.trackB != nil && vm.loadPending == 0
        }) { settled in
            if !settled { self.scNote("（等两轨就位超时，后面的读数不可信）") }
            self.followMainScreen(panel.panel)
            self.scNote("设置·无缝切换视频轨=\(SettingsStore.shared.seamlessVideoSwitch ? "开" : "关") "
                        + "挂载账=\(panel.attachedForCheck)")
            self.scRunStage(vm)
        }
    }

    private func scRunStage(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        let hiddenLane = vm.activeTrack == .a ? TrackSide.b : .a
        switch scStage {
        case 0:
            awaitForCheck("摆着那一轨挂上画面", remaining: 200, {
                panel.shownLaneForCheck != nil
            }) { _ in
                // 让 1.5 s 那一拍先过一轮：`warm` 是靠那一拍把看不见那一轨养准的。
                self.vcWait(1.8) { self.scStage += 1; self.scRunStage(vm) }
            }
        case 1:
            scNote("①换轨前（摆着=\(vm.activeTrack == .a ? "A" : "B")，\(hiddenLane == .a ? "A" : "B") 轨是看不见的）")
            scSide(vm, .a, "  ")
            scSide(vm, .b, "  ")
            scGap(vm, "  ")
            scNote("  挂载账=\(panel.attachedForCheck)")
            scSeeksBefore = panel.alignCountForCheck
            scStage += 1
            scRunStage(vm)
        case 2:
            vm.switchTrack()
            vcWait(0.06) { self.scStage += 1; self.scRunStage(vm) }
        case 3:
            let fresh = vm.activeTrack
            scNote("②换轨后 0.06 s: 摆着=\(fresh == .a ? "A" : "B") 挂载账=\(panel.attachedForCheck) "
                   + "这一下落了 \(panel.alignCountForCheck - scSeeksBefore) 次硬 seek"
                   + "（无缝那档该是 0）｜来路 \(panel.alignTraceForCheck)")
            scSide(vm, fresh, "  ")
            scGap(vm, "  ")
            vcWait(1.7) { self.scStage += 1; self.scRunStage(vm) }
        case 4:
            scNote("③换轨后 1.7 s（又过了一拍）")
            scSide(vm, .a, "  ")
            scSide(vm, .b, "  ")
            scGap(vm, "  ")
            scNote("  挂载账=\(panel.attachedForCheck)")
            scSeeksBefore = panel.alignCountForCheck
            vm.switchTrack()   // 换回去，第二次那一下同样该是 0 次 seek
            vcWait(0.06) { self.scStage += 1; self.scRunStage(vm) }
        case 5:
            let fresh = vm.activeTrack
            scNote("④换回去后 0.06 s: 摆着=\(fresh == .a ? "A" : "B") "
                   + "这一下落了 \(panel.alignCountForCheck - scSeeksBefore) 次硬 seek"
                   + "｜来路 \(panel.alignTraceForCheck)")
            scSide(vm, fresh, "  ")
            scGap(vm, "  ")
            // 播着换完，再停着换一遍：暂停时 seek 落地实测差 0.000，那一档才是
            // 「盯着同一秒比较」最常走的路，得单独看。
            vm.pause()
            vcWait(2.0) { self.scStage += 1; self.scRunStage(vm) }
        case 6:
            scNote("⑤暂停 2 s 后（两轨都停住，warm 该把它们摆到同一处）")
            scSide(vm, .a, "  ")
            scSide(vm, .b, "  ")
            scGap(vm, "  ")
            scSeeksBefore = panel.alignCountForCheck
            vm.switchTrack()
            vcWait(0.06) { self.scStage += 1; self.scRunStage(vm) }
        case 7:
            let fresh = vm.activeTrack
            scNote("⑥暂停中换轨后 0.06 s: 摆着=\(fresh == .a ? "A" : "B") "
                   + "这一下落了 \(panel.alignCountForCheck - scSeeksBefore) 次硬 seek"
                   + "｜来路 \(panel.alignTraceForCheck)")
            scSide(vm, fresh, "  ")
            scGap(vm, "  ")
            panel.close()
        default:
            break
        }
    }

    /// 录窗那一跑用：不去抄账，只是稳稳当当地每隔 1.2 s 真换一次轨（十几次），
    /// 外面拿 `screencapture -l<窗口号> -v` 录这一扇窗，再逐帧看换轨那一下有没有黑。
    private func startSeamlessLoop(_ vm: PlayerViewModel) {
        awaitForCheck("摆着那一轨挂上画面", remaining: 400, {
            VideoPanelController.shared.shownLaneForCheck != nil
        }) { _ in
            self.scLoop(vm, remaining: 14)
        }
    }

    private func scLoop(_ vm: PlayerViewModel, remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            vm.switchTrack()
            self.scLoop(vm, remaining: remaining - 1)
        }
    }

    // MARK: 重负载探针（AB_PANEL=heavy · #if DEBUG）
    //
    // 换上的素材是两支 4K60 H.264（25 Mbps、24-bit PCM 音轨、关键帧隔 0.5 s 一个），
    // 无缝那一档两层都挂着播放器 —— 等于两台解码器同放。三条抱怨各有各的尺，这一支一次抄齐：
    // ①实时率：连着 40 拍（0.25 s）抄「播放器的表走了几秒 ÷ 墙钟走了几秒」，小于 1 就是真在顿。
    //   每拍旁边带着 item 自己的账（就绪没就绪、缓冲空没空、往后还备着几秒），
    //   「解码跟不上」和「seek 自己愣表」这两种顿法就靠这几个数分开。
    // ②换轨那一跳：按下 F 之前抄「刚放手那一轨画在哪」，当场抄「新摆上来那一轨画在哪」。
    //   两轨都还在走，所以这两个数必须同一瞬间取，隔一秒再比就把播放量算进去了；
    // 负数就是裁定的「往回倒退了一点点」，旁边数这一段落了几次硬 seek（那就是「顿一下」）。
    // ③重新指派：B 轨换文件，从那一拍起每 0.5 s 抄一层 item 账，直到画面回来 ——
    //   黑屏只有两种来路（item 没挂回来 / 回来了但没帧），这一串分得开。

    private var hvLines: [String] = []
    private var hvStage = 0
    private var hvStart: TimeInterval = 0
    /// 每一轨的第一笔 / 最后一笔（墙钟秒, 表读数），末尾算实时率。
    private var hvEdge: [TrackSide: (first: (Double, Double), last: (Double, Double))] = [:]
    private var hvStalls: [TrackSide: Int] = [:]
    /// 表连着几拍一动不动（0.25 s 一拍）—— 「画面卡住」那一截的尺。上一拍停在哪儿、
    /// 当前这串多长、最长一串多长、一共有几拍。
    private var hvPrev: [TrackSide: Double] = [:]
    private var hvHoldStreak: [TrackSide: Int] = [:]
    private var hvHoldMax: [TrackSide: Int] = [:]
    private var hvHoldTotal: [TrackSide: Int] = [:]
    private var hvSeeksAtStart = 0
    /// ⑦那一趟有没有在闸门按住时按过一次播放（欠放那一格要跟它对上）。
    private var hvAskedPlay = false
    /// 诊断用的看门狗（量完删）：探针那一串停在 b00，而主线程的定时器照走 ——
    /// 这条用 RunLoop Timer 走，不受主队列那把锁的影响，专门记「拍数还在不在加」，
    /// 旁边带上装载闸门和「先养后换」那两本账。
    private var hvWatchTimer: Timer?
    private var hvWatchLines: [String] = []
    private var hvWatchBeats = 0
    /// 主队列活着的证据：每一拍往主队列丢一个只加计数的块。它涨而拍数不涨 = 队列在转，
    /// 是探针那一串自己断了；它不涨 = 主队列真的没被排空。
    private var hvMainAlive = 0
    /// 第二把尺：`CFRunLoopPerformBlock` 走的是 run loop 自己那一层，不经过主队列。
    /// 它涨而主队列不涨 = 主队列被人按住了（AppKit / AVFoundation 会挂起主队列），
    /// 两个都不涨 = run loop 已经不理这一层源了。
    private var hvRunLoopAlive = 0

    private func hvWatchStart() {
        hvWatchTimer?.invalidate()
        hvWatchLines = []
        hvWatchBeats = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in self?.hvMainAlive += 1 }
            RunLoop.main.perform { [weak self] in self?.hvRunLoopAlive += 1 }
            let panel = VideoPanelController.shared
            let w = ProcessInfo.processInfo.systemUptime - self.hvStart
            let line = String(format: "w +%.2fs 拍=%d 主队列=%d 源盘=%d 装=%d/%d 养=%@ 欠放=%d/%d 摆=%@ %@",
                              w, self.hvWatchBeats, self.hvMainAlive, self.hvRunLoopAlive,
                              AudioEngine.shared.isLoading(.a) ? 1 : 0,
                              AudioEngine.shared.isLoading(.b) ? 1 : 0,
                              panel.preloadTraceForCheck,
                              AudioEngine.shared.hasDeferredPlay(.a) ? 1 : 0,
                              AudioEngine.shared.hasDeferredPlay(.b) ? 1 : 0,
                              panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占",
                              panel.laneFileForCheck(.b))
            self.hvWatchLines.append(line)
            if self.hvWatchLines.count > 400 { self.hvWatchLines.removeFirst() }
            self.writeDiag(self.hvWatchLines.joined(separator: "\n") + "\n", suffix: ".watch")
        }
        RunLoop.main.add(timer, forMode: .common)
        hvWatchTimer = timer
    }

    private func hvT(_ d: Double) -> String { String(format: "%.3f", d) }

    /// 这一轨绑的那份文件的画面参数（没读回来就是 nil）。
    private func hvFacts(_ vm: PlayerViewModel, _ side: TrackSide) -> VideoFacts? {
        guard let url = side == .a ? vm.trackA?.url : vm.trackB?.url else { return nil }
        return vm.videoFacts[url.path]
    }

    private func hvNote(_ line: String) {
        hvLines.append(line)
        writeDiag(hvLines.joined(separator: "\n") + "\n", suffix: ".heavy")
    }

    /// 一轨的一笔：位置 + item 自己的账。
    private func hvSide(_ side: TrackSide) -> String {
        let panel = VideoPanelController.shared
        let name = side == .a ? "A" : "B"
        guard let feed = panel.feedForCheck(side) else { return "\(name)[没绑文件]" }
        guard feed.item else {
            return "\(name)[无item 表=\(hvT(feed.actual)) 速=\(String(format: "%.2f", Double(feed.rate)))]"
        }
        let pos = panel.syncReadings(side).map {
            "画=\(hvT($0.actual)) 引擎=\(hvT($0.expected)) 差=\(hvT($0.actual - $0.expected))"
        } ?? "画=\(hvT(feed.actual)) 引擎=没摆准"
        return "\(name)[\(pos) 速=\(String(format: "%.2f", Double(feed.rate)))"
            + " 备=\(feed.keepUp ? 1 : 0) 空=\(feed.empty ? 1 : 0) 满=\(hvT(feed.ahead)) 态=\(feed.status)]"
    }

    /// 一拍的账：两轨各一层 + 帧距 + 窗口那头的三件（摆哪轨 / 挂没挂 / 占位在不在）。
    private func hvSample(_ vm: PlayerViewModel, _ tag: String) {
        hvWatchBeats += 1
        let panel = VideoPanelController.shared
        let w = ProcessInfo.processInfo.systemUptime - hvStart
        let shown = panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占"
        var gap = ""
        if let a = panel.syncReadings(.a), let b = panel.syncReadings(.b) {
            let d = (b.actual - a.actual) - (b.expected - a.expected)
            let fps = a.halfFrame > 0 ? 0.5 / a.halfFrame : 24
            gap = String(format: " 帧距=%+.3fs≈%+.1f帧", d, d * fps)
            hvBeats(a, .a)
            hvBeats(b, .b)
        }
        var line = "\(tag) +\(String(format: "%.2f", w))s 摆=\(shown)"
        line += " 共=\(panel.sharingForCheck ? "一条流" : "两台")"
        line += " 占位=\(panel.isShowingPlaceholderForCheck ? "在" : "不在")"
        line += " 顿=\(hvHoldStreak[.a] ?? 0)/\(hvHoldStreak[.b] ?? 0)"
        line += " \(hvSide(.a)) \(hvSide(.b))\(gap)"
        hvNote(line)
    }

    /// 按窗口单张抓一张（`AB_MENUDUMP` 的目录就是落点）。量「黑屏」用：连拍会把装载饿住，
    /// 单张按窗口的代价才小到可以忽略。
    private func hvShot(_ tag: String) {
        guard let base = ProcessInfo.processInfo.environment["AB_MENUDUMP"] else { return }
        let shot = VideoPanelController.shared
            .shotForCheck(tag, to: (base as NSString).deletingLastPathComponent)
        hvNote("  张 \(tag): \(shot)")
    }

    /// 顺手把这一拍的边上两笔、「缓冲不济」和「表停住」记进账。
    private func hvBeats(_ r: (expected: Double, actual: Double, halfFrame: Double),
                         _ side: TrackSide) {
        hvTouch(side, r.actual)
        if let previous = hvPrev[side], abs(r.actual - previous) < 0.001 {
            let streak = (hvHoldStreak[side] ?? 0) + 1
            hvHoldStreak[side] = streak
            hvHoldTotal[side, default: 0] += 1
            if streak > (hvHoldMax[side] ?? 0) { hvHoldMax[side] = streak }
        } else {
            hvHoldStreak[side] = 0
        }
        hvPrev[side] = r.actual
        if let feed = VideoPanelController.shared.feedForCheck(side), feed.item, !feed.keepUp {
            hvStalls[side, default: 0] += 1
        }
    }

    private func hvTouch(_ side: TrackSide, _ actual: Double) {
        let w = ProcessInfo.processInfo.systemUptime - hvStart
        guard var edge = hvEdge[side] else {
            hvEdge[side] = (first: (w, actual), last: (w, actual))
            return
        }
        edge.last = (w, actual)
        hvEdge[side] = edge
    }

    private func hvRateReport(_ tag: String, _ total: Int) {
        for side in [TrackSide.a, .b] {
            let name = side == .a ? "A" : "B"
            guard let e = hvEdge[side] else {
                hvNote("\(tag) \(name)轨: 一笔都没抄到（没画面 / 没挂 item）")
                continue
            }
            let dt = e.last.0 - e.first.0
            let da = e.last.1 - e.first.1
            hvNote("\(tag) \(name)轨: 墙钟走 \(String(format: "%.2f", dt))s 表走 \(String(format: "%.2f", da))s "
                   + "实时率=\(String(format: "%.3f", dt > 0 ? da / dt : 0))"
                   + " 缓冲不济=\(hvStalls[side] ?? 0)/\(total) 拍"
                   + " 表停住: 最长 \(hvHoldMax[side] ?? 0) 拍(≈\(String(format: "%.1f", Double(hvHoldMax[side] ?? 0) * 0.26))s)"
                   + " 共 \(hvHoldTotal[side] ?? 0) 拍")
        }
        let panel = VideoPanelController.shared
        hvNote("\(tag) 这一趟落了 \(panel.alignCountForCheck - hvSeeksAtStart) 次硬 seek"
               + "（每 0.26 s 一拍，共 \(total) 拍）｜来路 \(panel.alignTraceForCheck)")
    }

    private func hvLoop(_ vm: PlayerViewModel, remaining: Int, total: Int, tag: String) {
        guard remaining > 0 else {
            hvRateReport(tag, total)
            hvStage += 1
            hvRunStage(vm)
            return
        }
        hvSample(vm, "  b\(String(format: "%02d", total - remaining))")
        vcWait(0.25) { self.hvLoop(vm, remaining: remaining - 1, total: total, tag: tag) }
    }

    private func runHeavyCheck(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        hvLines = []
        hvStage = 0
        hvEdge = [:]
        hvStalls = [:]
        awaitForCheck("两轨就位", remaining: 1_600, {
            vm.trackA != nil && vm.trackB != nil && vm.loadPending == 0
        }) { settled in
            self.hvStart = ProcessInfo.processInfo.systemUptime
            self.hvWatchStart()
            self.followMainScreen(panel.panel)
            self.hvNote("HEAVY A=\(vm.trackA?.url.lastPathComponent ?? "—") "
                        + "B=\(vm.trackB?.url.lastPathComponent ?? "—") "
                        + "无缝=\(SettingsStore.shared.seamlessVideoSwitch ? "开" : "关") "
                        + "两轨就位=\(settled) 起点=\(String(format: "%.3f", Date().timeIntervalSince1970))")
            self.hvRunStage(vm)
        }
    }

    private func hvRunStage(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        switch hvStage {
        case 0:
            awaitForCheck("摆着那一轨挂上画面", remaining: 400, {
                panel.shownLaneForCheck != nil
            }) { settled in
                self.hvNote("①画面挂上（+\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - self.hvStart))s）"
                            + " 等到=\(settled) 挂=\(panel.attachedForCheck) "
                            + "摆=\(panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占")"
                            + " 框=\(NSStringFromRect(panel.panelFrameForCheck))")
                for side in [TrackSide.a, .b] {
                    let name = side == .a ? "A" : "B"
                    if let f = self.hvFacts(vm, side) {
                        self.hvNote("  参数\(name): \(Int(f.width))×\(Int(f.height)) \(f.frameRate) "
                                    + "\(f.codec) 视频码率=\(f.bitrate)")
                    } else {
                        self.hvNote("  参数\(name): 还没读回来")
                    }
                }
                self.hvStage += 1
                self.hvRunStage(vm)
            }
        case 1:
            // 起播 + 稳走 10 s：这一趟不碰 F、不拖播放头，纯看两台解码器同放走不走得动。
            if !vm.sideIsPlaying(vm.activeTrack) { vm.play() }
            hvEdge = [:]
            hvStalls = [:]
            hvPrev = [:]
            hvHoldStreak = [:]
            hvHoldMax = [:]
            hvHoldTotal = [:]
            hvSeeksAtStart = VideoPanelController.shared.alignCountForCheck
            hvLoop(vm, remaining: 40, total: 40, tag: "②稳走 10 s")
        case 2:
            hvSwitch(vm, remaining: 3)
        case 3:
            hvDiverge(vm)
        case 4:
            hvConverge(vm)
        case 5:
            hvNote("④一次播中硬 seek 自己吃多少（重负载下的愣表长度）")
            panel.probeSeekForCheck(vm.activeTrack) { self.hvNote("  " + $0) }
            vcWait(1.5) { self.hvStage += 1; self.hvRunStage(vm) }
        case 6:
            hvReassign(vm)
        default:
            break
        }
    }

    /// ③b 共享的退出路：切进参照模式（那一档下两轨的播放头各走各的，这正是它存在的理由），
    /// 把没摆着的 B 轨拖开 2 s。两轨的时钟一岔过 0.1 s，0.25 s 那一拍就该认「分家」：
    /// B 那一层收回自己那台播放器、自己追自己的时钟 —— 借来的画不能跟着别人的播放头走。
    private func hvDiverge(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        hvNote("③b分家: 切参照模式并把 B 轨播放头挪开 2 s（起手 共=\(panel.sharingForCheck ? "一条流" : "两台")）")
        vm.setCompareMode(.reference)
        vm.seekSide(.b, to: vm.position(of: .b) + 2)
        hvLoop(vm, remaining: 20, total: 20, tag: "③b分家 5 s")
    }

    /// ③c 共享的再进场：切回版本对比，那一下会把两轨吸回同一个位置 —— 位置一对上就该重新
    /// 合流（`共=一条流` 回来），换轨也回到白送的那一档（跳=0）。
    private func hvConverge(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        hvNote("③c合流: 切回版本对比（两轨吸回同一位置）再放起来（起手 共=\(panel.sharingForCheck ? "一条流" : "两台")）")
        vm.setCompareMode(.versionCompare)
        vcWait(0.3) {
            if !vm.isPlaying { vm.play() }
            self.hvLoop(vm, remaining: 20, total: 20, tag: "③c合流 5 s")
        }
    }

    /// 来回换三次轨，每一次都抄「同一瞬间两轨各画在哪」。
    private func hvSwitch(_ vm: PlayerViewModel, remaining: Int) {
        guard remaining > 0 else { hvStage += 1; hvRunStage(vm); return }
        let panel = VideoPanelController.shared
        let old = vm.activeTrack
        let before = panel.syncReadings(old)?.actual ?? -1
        let seeks = panel.alignCountForCheck
        vm.switchTrack()
        let fresh = vm.activeTrack
        let just = panel.syncReadings(fresh)?.actual ?? -1
        hvSample(vm, "  F\(remaining)·当场")
        hvNote("  F\(remaining)·这一跳: \(old == .a ? "A" : "B")→\(fresh == .a ? "A" : "B") "
               + "刚放手画在=\(hvT(before)) 新摆上画在=\(hvT(just)) 跳=\(hvT(just - before))s"
               + "（负=往回倒退）｜起手时硬 seek 总数=\(seeks) 来路=\(panel.alignTraceForCheck)")
        vcWait(0.35) {
            self.hvSample(vm, "  F\(remaining)·0.35s")
            self.hvNote("  F\(remaining)·这一下落了 \(panel.alignCountForCheck - seeks) 次硬 seek")
        }
        vcWait(1.4) {
            self.hvSample(vm, "  F\(remaining)·1.4s")
            self.hvSwitch(vm, remaining: remaining - 1)
        }
    }

    /// ⑦「正摆着、而且正在放的那一轨被重新指派」—— 反馈里那句「B 轨画面可能卡死，且可能黑屏」
    /// 摆的就是这一档：换曲那一拍 item 摘掉，新文件的参数还没读回来时 `present()` 读到的
    /// `hasVideo` 是 nil，于是盖占位那一档 —— 屏上就是黑的；参数读回来、item 挂回来之前
    /// 按下的播放指令有没有人接，也在这一站看。`AB_HEAVY_COLD` 给一份这个进程没读过的文件，
    /// 把这一截撑到最长。
    private func hvShownSwap(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        let path = ProcessInfo.processInfo.environment["AB_HEAVY_COLD"] ?? ""
        guard !path.isEmpty else {
            hvNote("⑦缺 AB_HEAVY_COLD，摆着那一轨被换曲那一档没跑")
            AudioEngine.shared.stopAll()
            hvNote("=== HEAVY 跑完")
            return
        }
        AudioEngine.shared.stopAll()
        vm.setActiveTrack(.b)
        vcWait(0.4) { vm.play() }
        vcWait(1.8) {
            self.hvSample(vm, "  ⑦换之前（B 摆着且在放）")
            self.hvShot("before")
            self.hvAskedPlay = false
            self.hvNote("  ⑦B 换成没读过的冷文件 \(URL(fileURLWithPath: path).lastPathComponent)")
            vm.loadTrackBFromTrack(Track(url: URL(fileURLWithPath: path)))
            self.hvSwapPoll(vm, remaining: 16)
        }
    }

    /// 换曲之后每 0.25 s 抄一层账（这一截就是「眼睛看见的那几秒」），
    /// 第二拍上补按一次播放 —— 那一趟是换完文件立刻按播放。
    private func hvSwapPoll(_ vm: PlayerViewModel, remaining: Int) {
        guard remaining > 0 else {
            AudioEngine.shared.stopAll()
            hvNote("=== HEAVY 跑完")
            return
        }
        let panel = VideoPanelController.shared
        let w = ProcessInfo.processInfo.systemUptime - hvStart
        let shown = panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占"
        var line = "  s\(String(format: "%02d", 16 - remaining)) +\(String(format: "%.2f", w))s"
        line += " 摆=\(shown) 占位=\(panel.isShowingPlaceholderForCheck ? "在" : "不在")"
        line += " 挂=\(panel.attachedForCheck) 装=\(AudioEngine.shared.isLoading(.b))"
        line += " 引擎放B=\(AudioEngine.shared.isPlaying(.b))"
        line += " 欠放=\(AudioEngine.shared.hasDeferredPlay(.b) ? "有" : "无")"
        line += " 求放=\(hvAskedPlay ? "按过" : "没按")"
        line += " seek=\(panel.alignCountForCheck)"
        line += " 参数=\(hvFacts(vm, .b) != nil ? "有" : "无")"
        line += " \(panel.laneFileForCheck(.b)) \(hvSide(.b))"
        hvNote(line)
        if remaining == 15 { hvAskedPlay = true; vcWait(0.1) { vm.play() } }
        if remaining == 15 || remaining == 13 || remaining == 11 || remaining == 8 {
            hvShot("s\(String(format: "%02d", 16 - remaining))")
        }
        vcWait(0.25) { self.hvSwapPoll(vm, remaining: remaining - 1) }
    }

    /// 重新指派那一拍之后每 0.5 s 抄一层 item 账，直到画面回来。
    private func hvReassign(_ vm: PlayerViewModel) {
        let panel = VideoPanelController.shared
        let path = ProcessInfo.processInfo.environment["AB_HEAVY_RE"] ?? ""
        guard !path.isEmpty else {
            hvNote("⑤缺 AB_HEAVY_RE，换曲那一档没跑")
            AudioEngine.shared.stopAll()
            hvNote("=== HEAVY 跑完")
            return
        }
        hvNote("⑤重新指派: B 轨换成 \(URL(fileURLWithPath: path).lastPathComponent)"
               + "（摆着=\(panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占")）")
        vm.loadTrackBFromTrack(Track(url: URL(fileURLWithPath: path)))
        hvPoll(vm, remaining: 24)
    }

    private func hvPoll(_ vm: PlayerViewModel, remaining: Int) {
        guard remaining > 0 else {
            let panel = VideoPanelController.shared
            hvNote("⑥切到刚换过的那一轨（黑屏/卡死就在这一下）")
            vm.setActiveTrack(.b)
            hvSample(vm, "  切过去·当场")
            vcWait(0.5) { self.hvSample(vm, "  切过去·0.5s") }
            vcWait(2.0) {
                self.hvSample(vm, "  切过去·2s")
                self.hvNote("  B 轨失败原因=\(panel.feedFailureForCheck(.b))")
                self.hvShownSwap(vm)
            }
            return
        }
        let panel = VideoPanelController.shared
        let w = ProcessInfo.processInfo.systemUptime - hvStart
        let shown = panel.shownLaneForCheck.map { $0 == .a ? "A" : "B" } ?? "占"
        var line = "  p\(String(format: "%02d", 24 - remaining)) +\(String(format: "%.2f", w))s"
        line += " 摆=\(shown) 占位=\(panel.isShowingPlaceholderForCheck ? "在" : "不在")"
        line += " 挂=\(panel.attachedForCheck) 装=\(AudioEngine.shared.isLoading(.b))"
        line += " seek=\(panel.alignCountForCheck)"
        line += " 参数=\(hvFacts(vm, .b) != nil ? "有" : "无")"
        line += " \(panel.laneFileForCheck(.b)) \(hvSide(.b)) 标题=\(panel.panelTitleForCheck)"
        hvNote(line)
        if remaining == 23 || remaining == 21 || remaining == 18 {
            hvShot("p\(String(format: "%02d", 24 - remaining))")
        }
        vcWait(0.5) { self.hvPoll(vm, remaining: remaining - 1) }
    }

    /// 裁切走 AVFoundation 还是 ffmpeg，探针里量不出来（这边没有解码器），
    /// 所以只负责按开关切一份出来、把产物路径记账；入点偏移由外面的定位脚本对着源文件逐字节量。
    /// `AB_TRIM_SRC` 源文件、`AB_TRIM_S`/`AB_TRIM_E` 区间秒、`AB_TRIM_OUT` 落点目录、
    /// `AB_TRIM_AV` = 1/0 直接拨「优先使用AVFoundation「裁切」」。
    private func runTrimEngineForCheck() {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["AB_TRIM_SRC"], let out = env["AB_TRIM_OUT"] else {
            writeDiag("TRIM: 缺 AB_TRIM_SRC / AB_TRIM_OUT\n", suffix: ".trim")
            return
        }
        if let av = env["AB_TRIM_AV"] {
            SettingsStore.shared.preferAVFoundationTrim = av != "0"
        }
        let s = Double(env["AB_TRIM_S"] ?? "") ?? 3
        let e = Double(env["AB_TRIM_E"] ?? "") ?? 8
        FFmpegService.exportClip(inputURL: URL(fileURLWithPath: src),
                                startTime: s, endTime: e,
                                outputDirectory: URL(fileURLWithPath: out)) { result, fallback in
            let av = SettingsStore.shared.preferAVFoundationTrim
            switch result {
            case .success(let url):
                self.writeDiag("TRIM: av=\(av ? 1 : 0) 回落ffmpeg=\(fallback ? 1 : 0) 区间=\(s)..\(e) 产出=\(url.path)\n",
                               suffix: ".trim")
            case .failure(let error):
                self.writeDiag("TRIM: av=\(av ? 1 : 0) 回落ffmpeg=\(fallback ? 1 : 0) 失败 \(error.localizedDescription)\n",
                               suffix: ".trim")
            }
        }
    }

    /// 把「裁切当前/全部轨道范围…」在面板之后那一步跑起来，好给三种反馈拍照。
    /// `AB_TRIM_OUT` 落点目录、`AB_TRIM_AV` 拨裁切引擎开关、`AB_TRIM_FEEDBACK` = current/all，
    /// `AB_TRIM_FEEDBACK_FILES` 用竖线分开的源文件（走的就是拖进列表那一条 `openFiles`，
    /// 第一份落 A 轨、第二份落 B 轨），`AB_TRIM_RANGE_A`/`_B` = "3-8" 给对应轨铺一条范围
    /// （不铺就用现在的）。
    /// 弹窗是模态的、会把主线程按住，所以这一支只管起跑，账落在 `<base>.feedback`。
    private func exerciseTrimFeedbackForCheck(_ which: String) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AB_TRIM_OUT"] else {
            writeDiag("FEEDBACK: 缺 AB_TRIM_OUT\n", suffix: ".feedback")
            return
        }
        if let av = env["AB_TRIM_AV"] { SettingsStore.shared.preferAVFoundationTrim = av != "0" }
        guard let vm = vm else {
            writeDiag("FEEDBACK: 主界面还没站住，拿不到 vm\n", suffix: ".feedback")
            return
        }
        func range(_ spec: String?) -> ABRange? {
            guard let spec = spec else { return nil }
            let parts = spec.split(separator: "-")
            guard parts.count == 2, let s = Double(parts[0]), let e = Double(parts[1]) else { return nil }
            return ABRange(start: s, end: e)
        }
        if let files = env["AB_TRIM_FEEDBACK_FILES"] {
            let urls = files.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            vm.openFiles(urls: urls)
            writeDiag("FEEDBACK: 已载入 \(urls.map { $0.lastPathComponent }.joined(separator: ","))\n",
                      suffix: ".feedback")
        }
        if let r = range(env["AB_TRIM_RANGE_A"]) { vm.rangeA = r }
        if let r = range(env["AB_TRIM_RANGE_B"]) { vm.rangeB = r }
        let current = which != "all"
        let lane = current ? "当前轨 \(vm.currentTrack?.url.lastPathComponent ?? "nil")"
                           : "两轨 范围A=\(vm.rangeA != nil) 范围B=\(vm.rangeB != nil)"
        writeDiag("FEEDBACK: 起跑 \(which) av=\(SettingsStore.shared.preferAVFoundationTrim ? 1 : 0) \(lane)\n",
                  suffix: ".feedback")
        vm.checkTrimMenuFeedback(currentOnly: current, to: URL(fileURLWithPath: out))
    }

    /// 这一档不点按钮（这台机器注入不了鼠标），而是把三页各自管着的格子全拧离
    /// 默认，再按页复位，逐格对账。开头照一张原值快照、结尾原样写回，所以机器上的偏好
    /// 不会因为跑了一次探针就变了。
    private func runResetPagesForCheck() {
        let s = SettingsStore.shared
        let sc = ShortcutStore.shared
        let snap = (s.invertWheel, s.waveformDepthDB, s.waveformPanDivisor, s.waveformSplitStereo,
                    s.waveformFollowPlayhead, s.transportGlass, s.listGlass, s.seamlessVideoSwitch,
                    s.editModeExitPrompt, s.autoRestoreSession, s.playlistFontSize,
                    s.preferAVFoundationTrim)
        let picked = Array(ShortcutAction.allCases.prefix(2))
        let snapKeys = picked.map { sc.key(for: $0) }

        s.invertWheel = true; s.waveformDepthDB = 41; s.waveformPanDivisor = 7
        s.waveformSplitStereo = true; s.waveformFollowPlayhead = true
        s.transportGlass = false; s.listGlass = false; s.seamlessVideoSwitch = false
        s.editModeExitPrompt = false
        s.autoRestoreSession = true; s.playlistFontSize = 17; s.preferAVFoundationTrim = false
        for a in picked { sc.bindings[a] = "⌃q" }
        sc.save()
        // 扰动本身要先成立，否则下面的对账是空的（键位这一格尤其：写进去没粘住就看不出错）。
        let disturbedKeys = picked.map { sc.key(for: $0) }

        var lines = ["RESET: 九格显示 + 三格数据 + 两枚键位，逐格对账"]
        func check(_ name: String, _ got: Any, _ want: Any) {
            let g = String(describing: got), w = String(describing: want)
            lines.append("\(g == w ? "OK  " : "FAIL") \(name): 复位后=\(g) 该是=\(w)")
        }

        s.resetDisplaySettings()
        check("显示/反转滚轮", s.invertWheel, false)
        check("显示/动态深度", s.waveformDepthDB, SettingsStore.defaultDepthDB)
        check("显示/滚轮每格", s.waveformPanDivisor, SettingsStore.defaultWaveformPanDivisor)
        check("显示/分声道", s.waveformSplitStereo, false)
        check("显示/跟随播放头", s.waveformFollowPlayhead, false)
        check("显示/走带栏毛玻璃", s.transportGlass, true)
        check("显示/列表栏毛玻璃", s.listGlass, true)
        check("显示/无缝切换", s.seamlessVideoSwitch, true)
        check("显示/退出弹窗", s.editModeExitPrompt, true)
        // 越界检查：数据页那三格此刻还该停在扰动后的值，显示页复位不该碰它们。
        check("越界/会话恢复（数据页）", s.autoRestoreSession, true)
        check("越界/列表字号（数据页）", s.playlistFontSize, 17.0)
        check("越界/裁切引擎（数据页）", s.preferAVFoundationTrim, false)

        s.resetDataSettings()
        check("数据/会话恢复", s.autoRestoreSession, false)
        check("数据/列表字号", s.playlistFontSize, SettingsStore.defaultPlaylistFontSize)
        check("数据/裁切引擎", s.preferAVFoundationTrim, true)

        sc.resetToDefaults()
        for (i, a) in picked.enumerated() {
            check("扰动/\(a.rawValue)", disturbedKeys[i] != a.defaultKey, true)
            check("键位/\(a.rawValue)", sc.key(for: a), a.defaultKey)
            lines.append("     扰动=\(disturbedKeys[i]) 探针前=\(snapKeys[i])")
        }
        // 复位是不是真落了盘：@Published 的 didSet 该在赋值那一刻写进 UserDefaults。
        func persisted(_ key: String) -> String {
            (UserDefaults.standard.object(forKey: key) as? Bool).map { "\($0)" } ?? "nil"
        }
        check("落盘/editModeExitPrompt", persisted("editModeExitPrompt"), "true")
        check("落盘/preferAVFoundationTrim", persisted("preferAVFoundationTrim"), "true")

        // 快照原样写回。
        (s.invertWheel, s.waveformDepthDB, s.waveformPanDivisor, s.waveformSplitStereo,
         s.waveformFollowPlayhead, s.transportGlass, s.listGlass, s.seamlessVideoSwitch,
         s.editModeExitPrompt, s.autoRestoreSession, s.playlistFontSize,
         s.preferAVFoundationTrim) = snap
        for (a, k) in zip(picked, snapKeys) { sc.bindings[a] = k }
        sc.save()
        lines.append("RESET: 已还原快照 深度=\(snap.1) 字号=\(snap.10) "
                     + "键位=\(picked.map { sc.key(for: $0) }.joined(separator: ","))")
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".reset")
    }

    /// Diagnostic: raise 设置 or 使用帮助 so the panel can be photographed.
    /// Neither a click nor a keystroke reaches this app, and a sheet is the only
    /// way those two panels ever appear.
    private func openPanelForCheck(_ which: String) {
        guard let vm = vm else { return }
        switch which {
        case "settings": vm.showSettings = true
        case "about": AboutPanel.show()
        case "help": vm.showHelp = true
        case "info":
            // 那张两列表要有真轨道才拍得出内容，所以这一档配 --autoplay 用。
            InfoPanelController.shared.open(vm: vm)
            followMainScreen(InfoPanelController.shared.panel)
        case "editmode": showEditModeForCheck()
        case "mixer":
            showEditModeForCheck()
            MixerPanelController.shared.open(vm: vm)
            // 混音器那一本窗口账（内容宽高 + 下限）隔着截图量不准，抄一行到 stderr。
            if let m = MixerPanelController.shared.panel {
                followMainScreen(m)
                let c = m.contentRect(forFrameRect: m.frame).size
                writeDiag("MIXERSIZE 内容=\(Int(c.width))×\(Int(c.height))"
                          + " 框=\(Int(m.frame.width))×\(Int(m.frame.height))"
                          + " 下限=\(Int(m.contentMinSize.width))×\(Int(m.contentMinSize.height))\n",
                          suffix: ".mixer")
            } else {
                writeDiag("MIXERSIZE 窗口没开成\n", suffix: ".mixer")
            }
        case "video":
            // 开窗 + 跑一遍同步账。配 --autoplay 两支 mp4 用。
            VideoPanelController.shared.open(vm: vm)
            runVideoCheck(vm)
        case "videosize":
            // 「窗口大小=视频大小」「整块画面可拖」两条在窗口那本账上，隔着
            // 截图量不准，所以读数 + 连屏一起报。「拖拽缩放时同步」这一条量不了：程序改尺寸
            // 不走比例锁（实测递 800×600 就落 800×600），而真指针那一趟这台机器注不进按键。
            VideoPanelController.shared.open(vm: vm)
            awaitForCheck("视频窗口摆上画面", remaining: 200) {
                VideoPanelController.shared.shownLaneForCheck != nil
            } then: { settled in
                self.reportVideoSizeForCheck(settled)
            }
        case "videomemory":
            // 视频窗口大小和位置的记忆。三条规则各喂一份画面尺寸走一遍
            // `fitWindow`（同比例换分辨率 / 异比例 / 回原画面），再关窗重开、假装重启各读一次框。
            VideoPanelController.shared.open(vm: vm)
            awaitForCheck("视频窗口摆上画面", remaining: 200) {
                VideoPanelController.shared.shownLaneForCheck != nil
            } then: { settled in
                self.reportVideoMemoryForCheck(settled)
            }
        case "seamless", "seamlessloop":
            // 无缝切换视频轨。`AB_SEAMLESS=0` 拿老办法当对照跑同一支。
            if let v = ProcessInfo.processInfo.environment["AB_SEAMLESS"] {
                SettingsStore.shared.seamlessVideoSwitch = v != "0"
            }
            VideoPanelController.shared.open(vm: vm)
            if which == "seamless" { runSeamlessCheck(vm) } else { startSeamlessLoop(vm) }
        case "reassign":
            // 「重新指派 = 这一轨立刻停」的三种验收情况。`AB_REASSIGN=video` 换成
            // mp4 素材、并把视频窗开起来一起抄账；`AB_REASSIGN=watch` 走逐拍那一条（换完不按
            // 任何按钮，看它自己会不会又起来）。
            if (ProcessInfo.processInfo.environment["AB_REASSIGN"] ?? "") == "watch" {
                runReassignWatch(vm)
            } else {
                runReassignCheck(vm)
            }
        case "heavy":
            // 重负载三条（换曲后 B 轨卡死/黑屏、常常卡顿、切换往回跳一下）。
            // 素材走 `--autoplay`（两轨同一支就是裁定的那种摆法），换曲那一档的文件走
            // `AB_HEAVY_RE`，`AB_SEAMLESS=0` 拿老办法当对照，账落 `<base>.heavy`。
            if let v = ProcessInfo.processInfo.environment["AB_SEAMLESS"] {
                SettingsStore.shared.seamlessVideoSwitch = v != "0"
            }
            VideoPanelController.shared.open(vm: vm)
            runHeavyCheck(vm)
        case "reload":
            // 「随便重载入几次视频就全播不了」：一遍一遍换曲、每一轮立刻按播放，
            // 每一轮把两轨的四本账（装载闸门 / 欠放 / 引擎旗标 / 播放头走不走、画面走不走）抄下来。
            runReloadStormCheck(vm)
        case "laneb", "dim":
            // 走带三条：B 轨进度条那支蓝填充、和模式2 里另一条通道变暗（0.55），
            // 都要先把主动轨切过去 / 把对比模式摆出来才看得见 —— 那颗 A/B 色块点不到。
            showEditModeForCheck()
            vm.activeTrack = .b
            if which == "dim" { vm.compareMode = .reference }
        case "editexit":
            showEditModeForCheck()
            // 确认框要等模式真切进去再按：早一步按下走的是"进模式"那条分支，
            // prompt 当然不置位，看着像 BUG 其实是探针抢跑。
            pressEditExitForCheck(remaining: 300)
        case "browser":
            // 进模式、开窗口、弹浏览器都得一步一交还：主队列不会在半路排第二次，
            // 所以在主线程里自旋等不到任何回调（实测）。
            showEditModeForCheck()
            awaitForCheck("进编辑模式", { vm.editMode }) { settled in
                guard settled else {
                    self.writeDiag("PANEL: 没进得了编辑模式，跳过 browser\n", suffix: ".panel")
                    return
                }
                MixerPanelController.shared.open(vm: vm)
                vm.openBrowser(for: 0, side: .a)
                self.writeDiag("PANEL: browser 已打开\n", suffix: ".panel")
            }
            return
        case "projectsave", "projectopen":
            // 两张面板拍照：runModal 会把主线程钉在那里，所以这一支只管把面板摆出来，
            // 截完直接杀进程 —— 完成回调那条路（选目录、写盘）由 AB_PROJECT_CHECK 证过了。
            // 预设那两张面板早前就从菜单里拿掉了（改成直接列文件夹），所以不再拍照。
            self.writeDiag("PANEL: \(which) 已打开\n", suffix: ".panel")
            if which == "projectsave" { vm.saveProjectAs() } else { vm.openProject() }
            return
        case "slots":
            // 通道条截图：A 轨第 1 格装一个插件（名字该是 #266EB8），B 轨整轨旁通（该是橙色）。
            showEditModeForCheck()
            awaitForCheck("进编辑模式", { vm.editMode }) { settled in
                guard settled else {
                    self.writeDiag("PANEL: 没进得了编辑模式，跳过 slots\n", suffix: ".panel")
                    return
                }
                let delay = PluginCatalog.effects().first { $0.subtype == PluginCatalog.fourCC("dely")
                                                        && $0.manufacturer == PluginCatalog.fourCC("appl") }
                if let delay {
                    vm.loadPlugin(delay, at: 0, for: .a)
                }
                self.awaitForCheck("装载 AUDelay", { vm.slots(.a)[0].plugin != nil }) { loaded in
                    vm.toggleLaneBypass(.b)
                    MixerPanelController.shared.open(vm: vm)
                    self.writeDiag("PANEL: slots 已打开（装载=\(loaded)）\n", suffix: ".panel")
                }
            }
            return
        case "export":
            // 截图：对话框开着，选中「渲染，应用插件效果」。
            // 先等轨就绪再框范围、再进编辑模式 —— 不然摘要行和提示语拍出来是空/另一套。
            showEditModeForCheck()
            awaitForCheck("进编辑模式", { vm.editMode }) { _ in
                vm.rangeA = ABRange(start: 12, end: 47)
                vm.exportRequest = PlayerViewModel.ExportRequest(scope: .current, mode: .render)
                self.writeDiag("PANEL: export 对话框已打开（编辑模式=\(vm.editMode)）\n", suffix: ".panel")
            }
            return
        case "exporttrim":
            // 另一张：选「裁切」，文件名栏和位深栏该是灰的。
            awaitForCheck("两轨就绪", { AudioEngine.shared.durationB > 0 }, then: { _ in
                vm.exportRequest = PlayerViewModel.ExportRequest(scope: .all, mode: .trim)
                self.writeDiag("PANEL: export(裁切) 对话框已打开\n", suffix: ".panel")
            })
            return
        case "trimengine":
            // 两条裁切引擎各切一份出去，入点差多少拿到外面逐字节量。
            runTrimEngineForCheck()
            return
        case "resetpages":
            // 三枚「将本页设置恢复默认」没有鼠标可点，逐项拧离默认再复位，对账。
            runResetPagesForCheck()
            return
        case "bar":
            // 走带条拍照：条上播放头（2×20 #FFD60A）、范围两端的手柄（3.15×8.65 #F5AD44）、
            // 一颗全局标记、一颗侧标记。标记只写进显示用的数组，不落 MarkerStore。
            awaitForCheck("音轨就绪", { AudioEngine.shared.durationA > 0 }, then: { _ in
                vm.seekSide(.a, to: 33)
                vm.rangeA = ABRange(start: 12, end: 47)
                let demo: [Marker] = [Marker(position: 8, kind: .global), Marker(position: 20, kind: .sideA)]
                // 峰值解码收尾会 refreshMarkers()，把这份只拿来看的标记冲掉，所以等它解完再写。
                self.awaitForCheck("波形解完", { vm.waveformPeaksA.binCount > 0 }, then: { _ in
                    vm.markersA = demo
                    self.writeDiag("PANEL: bar 已就位 range=\(vm.rangeA.map { String(format: "%.0f–%.0f", $0.start, $0.end) } ?? "无") "
                                   + "markers=\(vm.markersA.count) 时长=\(String(format: "%.0f", AudioEngine.shared.durationA))\n",
                                   suffix: ".panel")
                })
            })
            return
        case "layout":
            // 双轨视图把走带栏顶出窗外。先抄单轨那一份账，半秒后切双轨再抄
            // 一份，截图停在出事的那一档。窗口尺寸由外面的 AB_WINDOW 给。
            dumpLayoutForCheck(vm: vm)
            return
        case "trim":
            // 截图：双轨视图（那颗小停止按钮所在的一档），A 轨拧 +2 s
            // —— 底色该是橙的、读数 2000；B 轨一个样本 —— 0.023，橙底照旧。
            awaitForCheck("两轨就绪", { AudioEngine.shared.durationB > 0 }, then: { _ in
                vm.setCompareMode(.reference)
                vm.seekSide(.a, to: 0)
                vm.setTimeTrim(2, for: .a)
                let rate = AudioEngine.shared.sampleRate(for: .b)
                vm.setTimeTrim(rate > 0 ? 1 / rate : 0.001, for: .b)
                self.writeDiag(String(format: "PANEL: trim A=%.3f B=%.5f 刻度 A=%.3f B=%.3f\n",
                                      vm.timeTrim(.a), vm.timeTrim(.b),
                                      vm.laneDuration(.a), vm.laneDuration(.b)), suffix: ".panel")
            })
            return
        case "trimbig":
            // 波形跟着偏移走格子的证据：+30 s 该把 A 的波形压掉 12% 并在曲首让出一段
            // 空白，−30 s 该把 B 的曲头直接剪掉。刻度一并写在 .panel 上对账。
            awaitForCheck("两轨就绪", { AudioEngine.shared.durationB > 0 }, then: { _ in
                vm.setCompareMode(.reference)
                vm.seekSide(.a, to: 0)
                vm.setTimeTrim(30, for: .a)
                vm.setTimeTrim(-30, for: .b)
                self.writeDiag(String(format: "PANEL: trimbig A=%.3f（文件 %.3f → 刻度 %.3f）B=%.3f（文件 %.3f → 刻度 %.3f）\n",
                                      vm.timeTrim(.a), AudioEngine.shared.durationA, vm.laneDuration(.a),
                                      vm.timeTrim(.b), AudioEngine.shared.durationB, vm.laneDuration(.b)),
                               suffix: ".panel")
            })
            return
        case "triminput":
            // 图示那一版的输入框：三格 + 每格一颗分隔点（改白）+ 底下那行
            // 「±x.xxx 秒」（青）「(±N 个样本)」（亮灰）。
            // 框是模态的，所以这一趟会停在 runModal 里等外面的截图，进程由外面收掉。
            self.writeDiag("PANEL: triminput 开框\n", suffix: ".panel")
            _ = TimeTrimInput.ask(sampleRate: 44100)
            return
        case "abxshot":
            // 置信度：造一份 12/15 的成绩（前 12 轮答对），把结果页拍下来。
            vm.abxRounds = (1...15).map { ABXRound(roundNumber: $0, xIsA: true, userAnswer: $0 <= 12) }
            vm.abxShowResult = true
            vm.abxIsActive = true
            return
        case "rangecolors":
            // 两枚橙底按钮各读一个置位 ——「选择」= isSelectingRange（barRangeOn），
            // 「范围播放」= rangeCompareEnabled（barRangePlayOn），鼠标点不进来只能自己置位。
            // 顺带带着编辑模式拍：时钟和播放键现在共用同一档深紫底色（barPlayBgEdit）
            // 加同一圈描边（abModePurple），两张色在同一张截图里对。
            showEditModeForCheck()
            awaitForCheck("进编辑模式", { vm.editMode }) { settled in
                guard settled else {
                    self.writeDiag("PANEL: 没进得了编辑模式，跳过 rangecolors\n", suffix: ".panel")
                    return
                }
                vm.isSelectingRange = true
                vm.rangeCompareEnabled = true
                self.writeDiag("PANEL: rangecolors 选择=\(vm.isSelectingRange) "
                               + "范围播放=\(vm.rangeCompareEnabled) 编辑=\(vm.editMode)\n", suffix: ".panel")
            }
            return
        case "abxtestA", "abxtestB":
            // 盲听页那条进度条画的就是当前路由到的那一轨，照旧绿／蓝分轨等于把
            // X 是 A 还是 B 写在脸上。两张按两轨各拍一次，填充该是同一支 .abxPlayed。
            awaitForCheck("音轨就绪", { AudioEngine.shared.durationA > 0 }, then: { _ in
                vm.pause()
                vm.seekSide(.a, to: 33)
                vm.seekSide(.b, to: 37)
                vm.abxTotalRounds = 0
                vm.abxRounds = [ABXRound(roundNumber: 1, xIsA: which == "abxtestA", userAnswer: nil)]
                vm.abxCurrentRoundIndex = 0
                vm.abxShowSetup = false
                vm.abxShowConfirm = false
                vm.abxShowResult = false
                vm.abxIsActive = true
                if which == "abxtestA" { vm.abxSelectA() } else { vm.abxSelectB() }
                self.writeDiag("PANEL: \(which) 路由=\(vm.activeTrack.rawValue) "
                               + "进度=\(String(format: "%.0f", vm.clock.position(of: vm.activeTrack)))s\n",
                               suffix: ".panel")
            })
            return
        case "helpshot":
            vm.showHelp = true
            awaitForCheck("help sheet 挂载", remaining: 100, { self.visibleSheet() != nil }) { settled in
                self.photographSheetForCheck(settled ? "使用帮助" : "使用帮助（超时）")
            }
            return
        case "settingsshot":
            vm.showSettings = true
            awaitForCheck("settings sheet 挂载", remaining: 100, { self.visibleSheet() != nil }) { settled in
                self.photographSheetForCheck(settled ? "设置" : "设置（超时）")
            }
            return
        case "editor":
            // 截图：A 格 1 装 Apple AUDelay，混音器和它的编辑浮窗都开着。
            showEditModeForCheck()
            awaitForCheck("进编辑模式", { vm.editMode }) { settled in
                guard settled else {
                    self.writeDiag("PANEL: 没进得了编辑模式，跳过 editor\n", suffix: ".panel")
                    return
                }
                let delay = PluginCatalog.effects().first { $0.subtype == PluginCatalog.fourCC("dely")
                                                            && $0.manufacturer == PluginCatalog.fourCC("appl") }
                if let delay { vm.loadPlugin(delay, at: 0, for: .a) }
                self.awaitForCheck("装载 AUDelay", { vm.slots(.a)[0].plugin != nil }) { loaded in
                    guard loaded else {
                        self.writeDiag("PANEL: 插件没装上，跳过 editor\n", suffix: ".panel")
                        return
                    }
                    // 参数面板里挪一格，截图才不是「四行都停在出厂值」：0.25 s 走的是界面那条路。
                    if let unit = AudioEngine.shared.unit(.a, at: 0),
                       let time = unit.auAudioUnit.parameterTree?.allParameters.first(where: {
                            $0.displayName.contains("延迟") || $0.displayName.lowercased().contains("delay") }) {
                        time.value = 0.25
                    }
                    MixerPanelController.shared.open(vm: vm)
                    vm.toggleSlotEditor(0, for: .a)
                    self.writeDiag("PANEL: editor 已打开（A格1=\(vm.slots(.a)[0].plugin?.name ?? "空") "
                                   + "窗=\(PluginEditorController.shared.openCount)）\n", suffix: ".panel")
                }
            }
            return
        default:
            writeDiag("PANEL: 不认识的面板 \(which)\n", suffix: ".panel")
            return
        }
        writeDiag("PANEL: \(which) 已打开\n", suffix: ".panel")
    }

    /// Diagnostic: 进编辑模式并开播，好让截图看见紫色时钟底、紫描边和播放中的绿底。
    /// pre-gain 归零是为了截图时电平不掉。
    private func showEditModeForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("PANEL: 音轨未在 60s 内就绪，跳过 editmode\n", suffix: ".panel")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.showEditModeForCheck(remaining: remaining - 1)
            }
            return
        }
        vm.setEditMode(true)
        vm.setPreGain(0, for: .a)
        vm.setPreGain(0, for: .b)
        vm.playFromStart()
    }

    /// Diagnostic: 面板现在挂在哪张 sheet 上（找不到就是 nil）。
    private func visibleSheet() -> NSWindow? {
        NSApp.windows.compactMap { $0.sheets.first }.first { $0.isVisible }
    }

    /// Diagnostic: 把 sheet 里那段滚动内容整张画下来。这台机器注入不了滚轮和按键，
    /// 分段截图只能拍到最上面一屏，而这一轮改的正是长文本的排版和分区。
    private func photographSheetForCheck(_ label: String) {
        guard let sheet = visibleSheet(), let content = sheet.contentView else {
            writeDiag("SHOT: \(label) 没有 sheet\n", suffix: ".shot"); return
        }
        let doc = firstScrollView(in: content)?.documentView ?? content
        let bounds = NSRect(origin: .zero, size: doc.frame.size)
        guard bounds.height > 1 else {
            writeDiag("SHOT: \(label) 内容高度为 0\n", suffix: ".shot"); return
        }
        let base = ProcessInfo.processInfo.environment["AB_MENUDUMP"] ?? "/tmp/panel"
        let pdf = doc.dataWithPDF(inside: bounds)
        let sheetPDF = content.dataWithPDF(inside: content.bounds)   // 标题栏在滚动区外面
        do {
            try pdf.write(to: URL(fileURLWithPath: base + ".shot.pdf"))
            try sheetPDF.write(to: URL(fileURLWithPath: base + ".sheet.pdf"))
            writeDiag("SHOT: \(label) 视口 \(Int(sheet.frame.width))×\(Int(sheet.frame.height)) · "
                      + "整段 \(Int(bounds.width))×\(Int(bounds.height)) pt · \(pdf.count) B → \(base).shot.pdf\n",
                      suffix: ".shot")
        } catch {
            writeDiag("SHOT: \(label) 写盘失败 \(error)\n", suffix: ".shot")
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = firstScrollView(in: sub) { return scroll }
        }
        return nil
    }

    /// Diagnostic: print the installed menu tree so the ⌘/ bindings and the new
    /// 「播放列表」/「窗口」items can be checked without driving the UI.
    ///
    /// Measure the tree, not the `enabled` column: a headless launch is never the
    /// active app, and SwiftUI only pushes a rebuilt command tree (titles as well
    /// as `.disabled`) into its NSMenuItems when the menu is about to open. Both
    /// were checked — a rebind and a flag flip made at 3 s were still invisible to
    /// a dump taken at 4 s, while the command body itself had re-evaluated. So an
    /// item bound to `.disabled(...)` reads whatever it was at build time, and the
    /// `active=`/`key=`/`main=` trailer says why.
    func dumpMenusForCheck(suffix: String = "") {
        guard let main = NSApp.mainMenu else {
            FileHandle.standardError.write("MENUDUMP: no main menu\n".data(using: .utf8)!)
            return
        }
        main.update()
        var lines: [String] = []
        for item in main.items {
            lines.append("• \(item.title)")
            guard let submenu = item.submenu else { continue }
            for sub in submenu.items {
                if sub.isSeparatorItem { continue }
                let key = sub.keyEquivalent.uppercased()
                var mods = ""
                let f = sub.keyEquivalentModifierMask
                if f.contains(.command) { mods += "⌘" }
                if f.contains(.shift) { mods += "⇧" }
                if f.contains(.option) { mods += "⌥" }
                if f.contains(.control) { mods += "⌃" }
                lines.append("  - \(sub.title) [\(mods)\(key)] enabled=\(sub.isEnabled)")
            }
        }
        lines.append("savedWindowSize=\(String(describing: SettingsStore.shared.savedWindowSize))")
        lines.append("active=\(NSApp.isActive) key=\(WindowDefaults.target?.isKeyWindow.description ?? "-") "
                     + "main=\(WindowDefaults.target?.isMainWindow.description ?? "-")")
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: suffix)

        #if DEBUG
        // dump 跳过分隔线（它没有标题），所以「某两条之间到底有没有那条线」只能拍照。
        // AB_MENUPOP=模式 把整张菜单在主窗口里弹出来，popUp 会把主线程钉在那里，
        // 拍照由外面的进程做，拍完直接杀进程。
        if let which = ProcessInfo.processInfo.environment["AB_MENUPOP"],
           let item = main.items.first(where: { $0.title == which }), let menu = item.submenu,
           let view = WindowDefaults.target?.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: 60, y: view.bounds.height - 40), in: view)
        }
        #endif
    }

    /// "1700x520" → CGSize；认不出来就当没写。尾巴上可以挂一段 "@x,y"：
    /// 那是屏幕全局坐标（原点在左上、y 朝下）里的窗口左上角，用来把测试窗摆到
    /// 主屏之外（副屏那一块的全局坐标）。
    static func parseWindowSize(_ spec: String) -> CGSize? {
        let head = spec.lowercased().split(separator: "@").first.map(String.init) ?? spec
        let parts = head.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
              w >= 400, h >= 200 else { return nil }
        return CGSize(width: w, height: h)
    }

    static func parseWindowPlace(_ spec: String) -> CGPoint? {
        guard let at = spec.range(of: "@") else { return nil }
        let parts = spec[at.upperBound...].split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// AB_PANEL=layout：把主窗口里真实落位的 AppKit 视图树抄成账（每行「缩进 类名
    /// x/y/w/h」，坐标是窗口坐标、原点在下）。这一条要分清：双轨视图把走带栏
    /// 顶出窗外，到底是左栏那两段波形各自的最小高咬住了窗口，还是列表那一栏又把高度
    /// 报了回来 —— 两种病因改法不同，只能先看落位。上表起手高用 AB_LIST_UPPER 起进程。
    /// 先抄单轨那一份，半秒后切双轨再抄一份（截图停在出事的那一档）。
    private func dumpLayoutForCheck(vm: PlayerViewModel) {
        guard let window = MainWindow.windowForCheck else {
            writeDiag("LAYOUT: 主窗口没接上\n", suffix: ".layout")
            return
        }
        var lines: [String] = []
        func walk(_ view: NSView, depth: Int) {
            let f = view.convert(view.bounds, to: nil)
            lines.append(String(repeating: "  ", count: depth)
                         + "\(type(of: view)) x=\(String(format: "%.1f", f.minX)) "
                         + "y=\(String(format: "%.1f", f.minY)) "
                         + "w=\(String(format: "%.1f", f.width)) "
                         + "h=\(String(format: "%.1f", f.height))")
            view.subviews.forEach { walk($0, depth: depth + 1) }
        }
        func report(_ mode: String, suffix: String) {
            lines.removeAll()
            if let root = window.contentView { walk(root, depth: 0) }
            let content = window.contentRect(forFrameRect: window.frame)
            writeDiag("LAYOUT: \(mode) 窗口内容区 w=\(String(format: "%.1f", content.width)) "
                      + "h=\(String(format: "%.1f", content.height)) "
                      + "框高=\(String(format: "%.1f", window.frame.height)) "
                      + "minSize=\(String(format: "%.1f", window.contentMinSize.width))"
                      + "x\(String(format: "%.1f", window.contentMinSize.height)) "
                      + "承载高=\(String(format: "%.1f", window.contentView?.frame.height ?? -1))\n"
                      + lines.joined(separator: "\n") + "\n", suffix: suffix)
        }
        vm.setCompareMode(.versionCompare)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            report("单轨", suffix: ".layout-single")
            vm.setCompareMode(.reference)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                report("双轨", suffix: ".layout-dual")
                // 第三档：把列表那一栏整个收掉，分清顶走带栏的是左栏那两格波形、还是列表栏
                // 又把高度报了回来。实测两档抄出来一字不差 —— 是前者，列表栏洗脱了嫌疑。
                vm.showPlaylistSidebar = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    report("双轨无列表栏", suffix: ".layout-nosidebar")
                    // 末档：把列表栏放回来，截图停在出事的那一档（双轨＋列表栏）。
                    vm.showPlaylistSidebar = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        report("双轨恢复列表栏", suffix: ".layout-restored")
                    }
                }
            }
        }
    }

    /// Diagnostics only: echo to stderr and, when AB_MENUDUMP names a file,
    /// write there too so a headless launch can be read back after it exits.
    private func writeDiag(_ text: String, suffix: String = "") {
        if let path = ProcessInfo.processInfo.environment["AB_MENUDUMP"],
           path != "1", !path.isEmpty {
            try? text.write(toFile: path + suffix, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }

    #if DEBUG
    /// AB_KEYLOG：把每一个真实 keyDown 的 keyCode / characters / charactersIgnoringModifiers
    /// / modifierFlags 原样追加进 `<base>.keylog`。这台机器注不进真键（合成的 CGEvent 被丢，
    /// 合成的 NSEvent 又只能自己造），所以「⇧1 那一下到底送进来什么字符」这类问题只能由用户
    /// 按一遍、再回来看这份账。Release 二进制里连开关都不带。
    private func logKeyForCheck(_ event: NSEvent) {
        guard let base = ProcessInfo.processInfo.environment["AB_KEYLOG"],
              base != "1", !base.isEmpty else { return }
        let path = base + ".keylog"
        var names: [String] = []
        let mods = event.modifierFlags
        if mods.contains(.command) { names.append("⌘") }
        if mods.contains(.option) { names.append("⌥") }
        if mods.contains(.control) { names.append("⌃") }
        if mods.contains(.shift) { names.append("⇧") }
        let line = "kc=\(event.keyCode) c=\(keyLogText(event.characters)) "
            + "cim=\(keyLogText(event.charactersIgnoringModifiers)) "
            + "mods=\(names.isEmpty ? "-" : names.joined())"
            + "(0x" + String(mods.rawValue, radix: 16) + ")\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 字符照原样记，但换行、制表这类控制字符写成 escapes：一行一条才好读。
    private func keyLogText(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return "[\(out)]"
    }
    #endif

    /// Diagnostic: drive 「保存当前窗口大小为默认」and「应用默认窗口大小」against the
    /// live window and report the frames, the one part of the pair the menu dump
    /// cannot show. Leaves the stored default as it found it.
    private func exerciseWindowDefaultsForCheck() {
        var lines: [String] = []
        let before = SettingsStore.shared.savedWindowSize
        defer {
            SettingsStore.shared.savedWindowSize = before
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".win")
        }
        guard let window = WindowDefaults.target else {
            lines.append("WINDOW: no target; have \(NSApp.windows.enumerated().map { "\($0.offset)=\($0.element.className)/vis=\($0.element.isVisible)/main=\($0.element.canBecomeMain)" }.joined(separator: " "))")
            return
        }
        let start = window.frame
        WindowDefaults.saveCurrentSize()
        let saved = SettingsStore.shared.savedWindowSize
        // Shrink away from the saved size, then apply: the window has to grow back
        // to it while its top edge stays where the shrunken one was.
        var scratch = start
        scratch.size = CGSize(width: start.width - 240, height: start.height - 160)
        scratch.origin.y = start.maxY - scratch.height
        window.setFrame(scratch, display: false)
        lines.append("save \(Int(start.width))x\(Int(start.height)) → stored \(String(describing: saved))")
        let topBefore = window.frame.maxY
        WindowDefaults.applySavedSize()
        let after = window.frame
        lines.append("apply from \(Int(scratch.width))x\(Int(scratch.height)) → "
                     + "\(Int(after.width))x\(Int(after.height)) "
                     + "sizeOK=\(abs(after.width - start.width) < 1 && abs(after.height - start.height) < 1) "
                     + "topKept=\(abs(after.maxY - topBefore) < 1)")
        window.setFrame(start, display: false)
        lines.append("restored \(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    /// Diagnostic: drive the undo/redo stack inside the shipping binary. The
    /// record beginEdit pushes snapshots state that is already true and the walk
    /// returns to it, so nothing the user can see changes and the stack ends
    /// cleared. The menu reports the same flags through `.disabled`, which a
    /// background launch cannot read back (see dumpMenusForCheck).
    private func exerciseHistoryForCheck() {
        guard let vm = vm else { return }
        let start = "start canUndo=\(vm.canUndo) canRedo=\(vm.canRedo)"
        vm.beginEdit()
        writeDiag(start + "\nafter beginEdit canUndo=\(vm.canUndo)\n", suffix: ".hist")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            vm.undoEdit()
            vm.redoEdit()
            vm.undoEdit()
            let walked = "after undo/redo/undo canUndo=\(vm.canUndo) canRedo=\(vm.canRedo)"
            vm.clearEditHistory()
            self.writeDiag(walked + "\ncleared canUndo=\(vm.canUndo) canRedo=\(vm.canRedo)\n",
                           suffix: ".hist2")
        }
    }

    /// Diagnostic: click 「文件」→「检测响度」 through the menu item itself, so the
    /// wiring is what is under test. The dialog it raises is modal, so a screenshot
    /// taken after it appears is the proof the replica renders.
    private func exerciseLoudnessForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        // 没有轨就没得测：detectLoudness 会直接 return，探针会拍到一个永远不出现的
        // 胶囊。所以先等两轨登记好（解码还在路上也不要紧，测的是文件本身）。
        if vm.trackA == nil || vm.trackB == nil {
            guard remaining > 0 else {
                writeDiag("LOUDNESS: 音轨未在 60s 内登记，跳过\n", suffix: ".loud")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseLoudnessForCheck(remaining: remaining - 1)
            }
            return
        }
        let item = NSApp.mainMenu?.item(withTitle: "文件")?.submenu?
            .items.first { $0.title.hasPrefix("检测响度") || $0.title == "检测中…" }
        guard let action = item?.action else {
            writeDiag("LOUDNESS: 没有 检测响度 菜单项或它没有 action\n", suffix: ".loud")
            vm.detectLoudness()
            return
        }
        // A menu click sends through the item's own target; SwiftUI's command items
        // carry one, so the probe has to pass it or it tests nothing.
        let sent = NSApp.sendAction(action, to: item?.target, from: item)
        writeDiag("LOUDNESS: sendAction=\(sent) target=\(String(describing: item?.target)) "
                 + "A=\(vm.trackA?.url.lastPathComponent ?? "-") "
                 + "B=\(vm.trackB?.url.lastPathComponent ?? "-")\n", suffix: ".loud")
        if !sent { vm.detectLoudness() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // Still true means the measurement is running; the dialog it ends in is
            // modal, so this line is the last thing the log sees from here on.
            self.writeDiag("2s 后 detecting=\(vm.isDetectingLoudness)\n", suffix: ".loud2")
        }
    }

    /// Diagnostic: 验收。采输出末级的样本，问三个问题——
    /// 1) 1.x 拓扑和编辑拓扑（pre-gain 0 dB）渲染出的样本是否逐帧相同；
    /// 2) pre-gain 标称 −6 / −20 dB 时电平是否正好低 6.00 / 20.00 dB；
    /// 3) 非编辑模式下 pre-gain 是否真的完全不在图里（回到 1.x 且带 −6 仍与基线相同）。
    ///
    /// 每轮采样之间都重启一次引擎，播放器起播前的静音周期长度并不固定，所以两段样本
    /// 不能按数组下标直接比：先按峰值位置定整数偏移，再在偏移附近找匹配帧最多的那个。
    private func exerciseChainForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("CHAIN: 音轨未在 60s 内就绪，跳过\n", suffix: ".chain")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseChainForCheck(remaining: remaining - 1)
            }
            return
        }
        let e = AudioEngine.shared
        let frames = 96_000
        var lines: [String] = []
        vm.setOutputGain(0)
        vm.setActiveTrack(.a)

        func capture(_ label: String, edit: Bool, pre: Double,
                     pan: Int? = nil, fader: Double? = nil) -> AudioEngine.DebugCapture {
            vm.stopPlayback()
            vm.setEditMode(edit)
            vm.setPreGain(pre, for: .a)
            vm.setPreGain(pre, for: .b)
            if let pan { vm.setPan(pan, for: .a); vm.setPan(pan, for: .b) }
            if let fader { vm.setLaneFader(fader, for: .a); vm.setLaneFader(fader, for: .b) }
            var result = AudioEngine.DebugCapture(ch0: [], ch1: [], gaps: 0, callbacks: 0)
            for attempt in 1...3 {
                vm.seekSide(.a, to: 0)
                vm.play()
                // outputVolume 是带淡变的，上一档增益要等起播后一段时间才彻底让位，
                // 所以在静音段之后先空跑一秒再开始采样。
                let settle = Date().addingTimeInterval(4)
                while vm.position(of: .a) < 1.0, Date() < settle {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                e.debugStartCapture()
                let timedOut = !e.debugWaitForCapture(frames: frames)
                let c = e.debugFinishCapture()
                vm.pause()
                result = c
                lines.append("\(label) #\(attempt): \(timedOut ? "TIMEOUT " : "")"
                             + "frames=\(c.frameCount) cb=\(c.callbacks) "
                             + "pos=\(String(format: "%5.2f", vm.position(of: .a)))s "
                             + "err=\"\(e.debugStartError)\" gaps=\(c.gaps)")
                if c.gaps == 0, !timedOut { break }
            }
            return result
        }

        let base = capture("1.x 拓扑          ", edit: false, pre: 0)
        let twin = capture("编辑拓扑 pre 0    ", edit: true, pre: 0)
        let m6 = capture("编辑拓扑 pre -6   ", edit: true, pre: -6)
        let m20 = capture("编辑拓扑 pre -20  ", edit: true, pre: -20)
        let back = capture("回到 1.x pre -6   ", edit: false, pre: -6)
        vm.setPreGain(Double(AudioEngine.preGainDefaultDB), for: .a)
        vm.setPreGain(Double(AudioEngine.preGainDefaultDB), for: .b)

        func compare(_ a: AudioEngine.DebugCapture, _ b: AudioEngine.DebugCapture, _ label: String) {
            let lag = alignForCheck(a, b, limit: frames)
            let ov = overlapForCheck(a, b, lag: lag, limit: frames)
            let matched = matchedFramesForCheck(a, b, lag: lag, count: ov.count)
            let sa = statsForCheck(a, start: ov.aStart, count: ov.count)
            let sb = statsForCheck(b, start: ov.bStart, count: ov.count)
            func d(_ v: Double) -> String { String(format: "%7.2f", v) }
            lines.append("\(label): lag=\(lag) n=\(ov.count) 逐帧相同=\(matched == ov.count ? "YES" : "NO")(\(matched)) "
                         + "peak \(d(sa.peakDB))/\(d(sb.peakDB)) Δ=\(String(format: "%6.3f", sa.peakDB - sb.peakDB)) "
                         + "rms \(d(sa.rmsDB))/\(d(sb.rmsDB)) Δ=\(String(format: "%6.3f", sa.rmsDB - sb.rmsDB)) dB")
            // 六段峰值排开能直接看出电平是不是还在爬：平了就是已 settling，一路抬就是淡变。
            let n = ov.count / 6
            guard n > 0 else { return }
            var chunks: [String] = []
            for k in 0..<6 {
                chunks.append(String(format: "%6.2f", statsForCheck(b, start: ov.bStart + k * n, count: n).peakDB))
            }
            lines.append("        b 的分段峰值: " + chunks.joined(separator: " "))
        }

        compare(base, twin, "拓扑 1.x vs 编辑 ")
        compare(base, m6, "pre-gain -6      ")
        compare(base, m20, "pre-gain -20     ")
        compare(base, back, "1.x 带 pre -6    ")

        // 验收：声道抽头是就地改样本的，得证明改动真的到了输出，而不是只被
        // 抽头自己看见。中置应与不挂声像时逐帧相同；硬左要右声道彻底静音、左声道
        // 与基线持平；推子 +6 则两声道同步抬 6.000 dB。
        let hardL = capture("编辑 硬左 pan-64", edit: true, pre: 0, pan: -64)
        let up6 = capture("编辑 推子 +6    ", edit: true, pre: 0, pan: 0, fader: 6)
        let neutral = capture("编辑 中置复位   ", edit: true, pre: 0, pan: 0, fader: 0)
        lines.append(String(format: "硬左: L=%6.2f R=%6.2f | 中置: L=%6.2f R=%6.2f | 基线: L=%6.2f R=%6.2f",
                            chanPeakForCheck(hardL, hardL.ch0), chanPeakForCheck(hardL, hardL.ch1),
                            chanPeakForCheck(neutral, neutral.ch0), chanPeakForCheck(neutral, neutral.ch1),
                            chanPeakForCheck(base, base.ch0), chanPeakForCheck(base, base.ch1)))
        compare(base, neutral, "编辑 中置 vs 1.x ")
        compare(neutral, up6, "推子 +6 对中置   ")

        // ⇧↩ 承诺的是"任何模式下都把两轨播放头归零"，所以两种模式都走一遍本机按键查表
        // 路径（drive 是 app 内部的 dispatch 入口，不是外部注入）；顺带确认单独的 ↩ 在
        // 参考曲里仍旧只管当前轨，别把既有行为改坏了。
        if vm.trackB != nil {
            for mode in [CompareMode.versionCompare, .reference] {
                vm.setCompareMode(mode)
                vm.stopPlayback()
                vm.seekSide(.a, to: 5)
                vm.seekSide(.b, to: 8)
                let a0 = vm.position(of: .a), b0 = vm.position(of: .b)
                let pressed = pressForCheck(keyCode: 36, modifiers: [.shift], vm: vm)
                lines.append("⇧↩ \(mode.rawValue): 命中=\(pressed) "
                             + "A \(String(format: "%5.2f", a0))→\(String(format: "%5.2f", vm.position(of: .a))) "
                             + "B \(String(format: "%5.2f", b0))→\(String(format: "%5.2f", vm.position(of: .b)))")
            }
            vm.setCompareMode(.reference)
            vm.seekSide(.a, to: 5)
            vm.seekSide(.b, to: 8)
            let pressed = pressForCheck(keyCode: 36, modifiers: [], vm: vm)
            lines.append("↩ 参考曲(当前轨 A): 命中=\(pressed) "
                         + "A=\(String(format: "%5.2f", vm.position(of: .a))) "
                         + "B=\(String(format: "%5.2f", vm.position(of: .b)))")
            vm.setCompareMode(.versionCompare)
        } else {
            lines.append("⇧↩: 只加载了 A 轨，跳过")
        }
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".chain")
    }

    /// 链序改成 pre-gain → 声像 → 插件 → 推子。顺序本身不靠电平推断，直接读
    /// 引擎的接线表（`debugLaneTrace`）：空槽一趟、挂一支 AUDelay 一趟，看声像落在插件的
    /// 哪一边。剩下两档是回归——换了顺序之后声像还得照样作用到输出，中置那档是尺子。
    ///
    /// 顺带记一笔踩过的坑：把抽头装到 AVAudioUnitEffect 的输入总线上量不到上游的声像
    /// （硬左时它的右声道照旧满电平，把声像那级静音也只掉 10 dB），同一条链上装在
    /// 混音器输入总线上的抽头是跟得上的（实测）。所以这一档只能读接线表，别再用
    /// 插件节点的抽头。
    private func exerciseOrderForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("ORDER: 音轨未在 60s 内就绪，跳过\n", suffix: ".order")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseOrderForCheck(remaining: remaining - 1)
            }
            return
        }
        let e = AudioEngine.shared
        var lines: [String] = []
        vm.setOutputGain(0)
        vm.setActiveTrack(.a)
        vm.setEditMode(true)
        lines.append("图形(空槽): \(e.debugLaneTrace)")
        // AUDelay 是这台机器上验证过装得进去的那支（slots 截图用的就是它）。
        let delay = PluginCatalog.effects().first {
            $0.subtype == PluginCatalog.fourCC("dely") && $0.manufacturer == PluginCatalog.fourCC("appl")
        }

        func measure(_ label: String, pan: Int) {
            var note = ""
            var l = -99.0, r = -99.0
            for _ in 1...3 {
                vm.stopPlayback()
                vm.setPan(pan, for: .a)
                vm.seekSide(.a, to: 0)
                vm.play()
                // 起播那一秒是淡变，采样从它之后才开始（实测）。
                let settle = Date().addingTimeInterval(4)
                while vm.position(of: .a) < 1.0, Date() < settle {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                e.debugStartCapture()
                let timedOut = !e.debugWaitForCapture(frames: 96_000)
                let c = e.debugFinishCapture()
                vm.pause()
                l = chanPeakForCheck(c, c.ch0)
                r = chanPeakForCheck(c, c.ch1)
                note = timedOut ? "TIMEOUT " : (c.gaps > 0 ? "gaps=\(c.gaps) " : "")
                if !timedOut, c.gaps == 0 { break }
            }
            lines.append(String(format: "%@: %@L=%6.2f R=%6.2f dBFS", label, note, l, r))
        }

        func finish() {
            vm.setPan(0, for: .a)
            vm.stopPlayback()
            writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".order")
        }

        func run() {
            lines.append("图形(挂了插件): \(e.debugLaneTrace)")
            measure("总输出 中置      ", pan: 0)
            measure("总输出 硬左-64  ", pan: -64)
            finish()
        }

        guard let delay else {
            lines.append("ORDER: 机器上没有 appl:dely，读不了带插件的接线，跳过")
            finish()
            return
        }
        vm.loadPlugin(delay, at: 0, for: .a)
        awaitForCheck("装载 AUDelay", { vm.slots(.a)[0].plugin != nil }) { loaded in
            guard loaded else {
                lines.append("ORDER: AUDelay 没装上，跳过")
                finish()
                return
            }
            run()
        }
    }

    /// 等 showEditModeForCheck 把编辑模式真的切进去，再按一次退出，读 prompt 的落点。
    /// 2 s 后还在 true 说明确认框立着（它是模态的，主线程不会再往前跑多少），
    /// 变成 false 则说明要么没摆出来，要么已经点了按钮。
    private func pressEditExitForCheck(remaining: Int) {
        guard let vm = vm else { return }
        guard vm.editMode else {
            guard remaining > 0 else {
                writeDiag("EXIT: 60s 内没进编辑模式，跳过\n", suffix: ".exit")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.pressEditExitForCheck(remaining: remaining - 1)
            }
            return
        }
        vm.toggleEditMode()
        writeDiag("按下当下: editMode=\(vm.editMode) prompt=\(vm.showEditModeExitPrompt)\n", suffix: ".exitNow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.writeDiag("EXIT: editMode=\(vm.editMode) prompt=\(vm.showEditModeExitPrompt) "
                           + "active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.title)) "
                           + "windows=\(NSApp.windows.map { "\($0.title)|key=\($0.isKeyWindow)" }.joined(separator: ", "))\n",
                           suffix: ".exit")
        }
    }

    /// 把一次按键交给 app 自己的快捷键查表。本机没有辅助功能权限，外部注入的事件根本
    /// 到不了进程，所以按下只能在这儿做—— keyCode 36 是 Return，⌘ 之外不需要别的字符。
    private func pressForCheck(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                               vm: PlayerViewModel) -> Bool {
        drive(keyCode: keyCode, modifiers: modifiers, charactersIgnoringModifiers: "\r", vm: vm)
    }

    /// 峰值样本在文件里只有一个位置，它在两段采样里的下标差就是播放器前导静音之差。
    /// 这个猜测对纯增益变化不敏感，所以 pre-gain 那几轮也能用同一把尺子对齐。
    private func peakAnchorForCheck(_ a: AudioEngine.DebugCapture, _ b: AudioEngine.DebugCapture) -> Int {
        guard a.frameCount > 64, b.frameCount > 64 else { return 0 }
        var iA = 0, iB = 0
        var mA: Float = -.greatestFiniteMagnitude, mB: Float = -.greatestFiniteMagnitude
        for (i, v) in a.ch0.enumerated() where v > mA { mA = v; iA = i }
        for (i, v) in b.ch0.enumerated() where v > mB { mB = v; iB = i }
        let guess = iA - iB
        return abs(guess) < min(a.frameCount, b.frameCount) / 2 ? guess : 0
    }

    /// 同一个最大值的相邻两帧会让峰值锚点差出一帧，偏移差一帧匹配数就塌下去，所以在
    /// 猜测附近再试一小段，取匹配帧最多的；打平时保留锚点，免得电平不同的两轮被挪跑。
    private func alignForCheck(_ a: AudioEngine.DebugCapture, _ b: AudioEngine.DebugCapture,
                               limit: Int) -> Int {
        let anchor = peakAnchorForCheck(a, b)
        var best = anchor
        var bestMatched = matchedFramesForCheck(a, b, lag: anchor,
                                                count: overlapForCheck(a, b, lag: anchor, limit: limit).count)
        for delta in 1...32 {
            for lag in [anchor - delta, anchor + delta] {
                let n = matchedFramesForCheck(a, b, lag: lag,
                                              count: overlapForCheck(a, b, lag: lag, limit: limit).count)
                if n > bestMatched { bestMatched = n; best = lag }
            }
        }
        return best
    }

    /// lag > 0：b 比 a 早 lag 帧起采，比的是 a[lag+i] 与 b[i]。
    private func overlapForCheck(_ a: AudioEngine.DebugCapture, _ b: AudioEngine.DebugCapture,
                                 lag: Int, limit: Int) -> (aStart: Int, bStart: Int, count: Int) {
        let aStart = max(0, lag)
        let bStart = max(0, -lag)
        return (aStart, bStart, max(0, min(min(a.frameCount - aStart, b.frameCount - bStart), limit)))
    }

    private func matchedFramesForCheck(_ a: AudioEngine.DebugCapture, _ b: AudioEngine.DebugCapture,
                                       lag: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let ov = overlapForCheck(a, b, lag: lag, limit: count)
        guard ov.count == count else { return 0 }
        var m = 0
        for k in 0..<count where a.ch0[ov.aStart + k] == b.ch0[ov.bStart + k]
            && a.ch1[ov.aStart + k] == b.ch1[ov.bStart + k] { m += 1 }
        return m
    }

    private func statsForCheck(_ c: AudioEngine.DebugCapture, start: Int, count: Int)
        -> (peakDB: Double, rmsDB: Double) {
        guard count > 0 else { return (-99, -99) }
        var peak: Float = 0
        var energy: Double = 0
        for k in 0..<count {
            for v in [c.ch0[start + k], c.ch1[start + k]] {
                peak = max(peak, abs(v))
                energy += Double(v) * Double(v)
            }
        }
        return (peak > 0 ? 20 * log10(Double(peak)) : -99,
                energy > 0 ? 10 * log10(energy / Double(count * 2)) : -99)
    }

    /// 分声道峰值：pan 只能靠左右两路各读一次来判断，混在一处的峰值看不出声道。
    private func chanPeakForCheck(_ c: AudioEngine.DebugCapture, _ ch: [Float]) -> Double {
        var p: Float = 0
        for v in ch where abs(v) > p { p = abs(v) }
        return p > 0 ? 20 * log10(Double(p)) : -99
    }

    /// 归一化自相关：比 x[n] 和 x[n+lag] 在 window 帧上的相似度。回声会把 lag=延迟
    /// 那一格抬起来；电平、音量、混音比例都影响这个比值很小，所以它比峰值可靠。
    private func autocorrForCheck(_ x: [Float], lag: Int, start: Int, window: Int) -> Double {
        guard lag > 0, start >= 0, start + window + lag <= x.count else { return -2 }
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        // 裸指针走一遍：这个函数每次扫描要被叫上万次，Debug 构建里数组的下标越界检查
        // 就是那几分钟（实测同一个文件 60 s → 不到 1 s）。
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i < window {
                let a = Double(p[start + i]), b = Double(p[start + i + lag])
                sxy += a * b; sxx += a * a; syy += b * b
                i += 1
            }
        }
        let denom = (sxx * syy).squareRoot()
        return denom > 0 ? sxy / denom : 0
    }

    /// 先按 25 帧粗扫一遍，再在最优点附近按帧收；Debug 构建里整段按帧扫要跑到天荒地老。
    private func bestAutocorrForCheck(_ x: [Float], from: Int, to: Int,
                                      start: Int, window: Int) -> (lag: Int, r: Double) {
        var best = (lag: from, r: autocorrForCheck(x, lag: from, start: start, window: window))
        var lag = from
        while lag <= to {
            let r = autocorrForCheck(x, lag: lag, start: start, window: window)
            if r > best.r { best = (lag, r) }
            lag += 25
        }
        for l in max(from, best.lag - 25)...min(to, best.lag + 25) {
            let r = autocorrForCheck(x, lag: l, start: start, window: window)
            if r > best.r { best = (l, r) }
        }
        return best
    }

    /// 验收：AU 到底有没有在算。
    ///
    /// 用系统自带的 Apple AUDelay（aufx/dely/appl，没有 shell、参数表实测就四项：
    /// Dry/Wet 0…100、Delay Time 0.0001…2 秒、Feedback −99.9…99.9 %、Lowpass 10…22050 Hz）。
    /// 把延迟设成 0.5 秒，采一段输出做自相关：真在算的话，相关峰就该落在 0.5 s × 采样率
    /// 那一格；按下 bypass 之后峰要塌回干信号那一档，卸掉之后要跟干信号逐帧相同。
    ///
    /// 每一步都得交还给事件循环才能走下一步：块还在主队列上跑的时候，libdispatch 不会
    /// 半路再排一次主队列（实测：instantiate 的完成块 1 秒就回来了，探针却在主线程里自旋
    /// 了 60 秒也没排到它）。所以装载之后的每一段都是 asyncAfter 串起来的，不是顺序代码。
    private func exerciseAUForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("AU: 音轨未在 60s 内就绪，跳过\n", suffix: ".au")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseAUForCheck(remaining: remaining - 1)
            }
            return
        }
        auLines = []
        vm.setOutputGain(0)
        vm.setActiveTrack(.a)
        vm.stopPlayback()
        vm.setEditMode(true)
        vm.setPreGain(0, for: .a)
        vm.setLaneFader(0, for: .a)
        vm.setPan(0, for: .a)

        // 1) 清单：读 plist 的耗时和条数，是浏览器打开时用户等的时间。
        let t0 = Date()
        let catalog = PluginCatalog.effects()
        let aufxCount = catalog.filter { $0.kind == .effect }.count
        auNote("清单: \(catalog.count) 条（aufx \(aufxCount) / aumf \(catalog.count - aufxCount)）"
                + " · 读 plist \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        guard let delay = catalog.first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
            auNote("本机 plist 里没有 Apple AUDelay，跳过")
            auFinish()
            return
        }
        auPlugin = delay
        // 2) 干信号：什么插件都没装的基线。
        auDry = auCapture("干信号          ")
        auLoad()
    }

    /// 3) 装载：走 vm.loadPlugin（异步），等 published 状态落定。
    private func auLoad() {
        guard let vm = vm, let delay = auPlugin else { return }
        let e = AudioEngine.shared
        auLoadedAt = Date()
        vm.loadPlugin(delay, at: 0, for: .a)
        awaitForCheck("装载 \(delay.name)", { vm.slots(.a)[0].plugin != nil }) { settled in
            let ms = Int(Date().timeIntervalSince(self.auLoadedAt) * 1000)
            self.auNote("装载 \(delay.name): 等到=\(settled) · \(ms) ms · "
                        + "attach 数=\(e.debugAttachedPluginCount) · err=\"\(vm.pluginError ?? "")\"")
            self.auNote("  装载轨迹: \(e.debugSlotTrace)")
            guard e.debugSlotUnit(.a, 0) != nil else {
                self.auNote("拿不到 unit，跳过音频比对")
                self.auFinish()
                return
            }
            self.auSetDelayTime()
            self.auWetCapture()
        }
    }

    /// 4) 参数表：后面几轮要靠它，先在这里确认桥接是通的。顺手把延迟设成 0.5 秒。
    private func auSetDelayTime() {
        guard let unit = AudioEngine.shared.debugSlotUnit(.a, 0) else { return }
        let tree = unit.auAudioUnit.parameterTree
        for p in tree?.allParameters ?? [] {
            auNote("  参数 addr=\(p.address) \(p.displayName) \(p.minValue)…\(p.maxValue) "
                   + "\(p.unitName ?? "") 值=\(p.value)")
        }
        auDelaySeconds = 0
        // 参数名是本地化的：这台机器上 Apple AUDelay 报出来的是「延迟时间 / 秒」，
        // 按英文名找会一无所获（上一轮就这么把 1 秒的默认值当成 0.5 秒量了）。
        // 所以名字认中英文，认不出再退一步按单位「秒」找。
        if let time = tree?.allParameters.first(where: {
                $0.displayName.lowercased().contains("delay") || $0.displayName.contains("延迟")
                || $0.unitName == "Secs" || $0.unitName == "秒" }) {
            time.value = min(max(Self.auWantedDelay, time.minValue), time.maxValue)
            auDelaySeconds = Double(time.value)   // 读回来的才算数，插件可以不老实
            auNote("  设的是「\(time.displayName)」(addr=\(time.address)) → \(auDelaySeconds) \(time.unitName ?? "")")
        } else {
            auNote("  没找到延迟参数，湿信号无从比对")
        }
    }

    /// 5) 湿信号：自相关峰该出现在延迟那一格。
    private func auWetCapture() {
        let rate = AudioEngine.shared.debugConnectionRate
        guard auDelaySeconds > 0 else {
            _ = auCapture("AUDelay 默认   ")
            auSlotBypassCapture()
            return
        }
        let wet = auCapture("AUDelay \(auDelaySeconds)s")
        let expect = Int(auDelaySeconds * (rate > 0 ? rate : 44_100))
        auNote("  延迟 \(auDelaySeconds) s → 期望相关峰在 \(expect) 帧"
               + "（链路 \(String(format: "%.0f", rate)) Hz）")
        auNote(auAutocorrLine("湿", wet, expect: expect))
        auNote("  " + auAutocorrLine("干", auDry, expect: expect))
        auExpect = expect
        auSlotBypassCapture()
    }

    /// 自相关一行：全曲最亮的峰在哪一帧，期望帧上有多亮，以及期望帧附近最亮到多少。
    /// 音乐本身就有节拍性的自相关峰（实测这首在 2020 帧），所以只看全局峰会把回声
    /// 混在里面；期望帧附近那一个峰才是插件加进去的。
    private func auAutocorrLine(_ label: String, _ c: AudioEngine.DebugCapture, expect: Int) -> String {
        let start = 4_000, window = 20_000
        let best = bestAutocorrForCheck(c.ch0, from: 2_000,
                                        to: max(2_001, c.frameCount - window - 1),
                                        start: start, window: window)
        let near = bestAutocorrForCheck(c.ch0, from: max(1, expect - 2_000), to: expect + 2_000,
                                        start: start, window: window)
        return String(format: "%@ 自相关: 全局峰=%6.3f@%d帧 · 期望 %d 帧处=%6.3f · 期望±2000 内峰=%6.3f@%d帧",
                      label, best.r, best.lag, expect,
                      autocorrForCheck(c.ch0, lag: expect, start: start, window: window), near.r, near.lag)
    }

    /// 6) 单格 bypass：AVAudioUnitEffect.bypass 到底管不管用。
    private func auSlotBypassCapture() {
        guard let vm = vm else { return }
        let e = AudioEngine.shared
        vm.toggleSlotBypass(0, for: .a)
        let off = auCapture("单格 bypass    ")
        auNote(auAutocorrLine("单格 bypass", off, expect: auExpect))
        auNote("  bypass 开关=\(e.debugSlotUnit(.a, 0)?.bypass == true ? "true" : "false") · \(e.debugLaneState)")
        vm.toggleSlotBypass(0, for: .a)
        auLaneBypassCapture()
    }

    /// 7) 整轨 bypass：整条链该哑掉。
    private func auLaneBypassCapture() {
        guard let vm = vm else { return }
        let e = AudioEngine.shared
        vm.toggleLaneBypass(.a)
        let off = auCapture("整轨 bypass    ")
        auNote(auAutocorrLine("整轨 bypass", off, expect: auExpect))
        auNote("  laneBypass=\(e.isLaneBypassed(.a) ? "true" : "false")")
        vm.toggleLaneBypass(.a)
        auUnloadCapture()
    }

    /// 8) 卸掉：应当和干信号逐帧相同，证明重接线没有留下野连接。
    private func auUnloadCapture() {
        guard let vm = vm else { return }
        vm.unloadSlot(0, for: .a)
        let gone = auCapture("卸掉之后      ")
        let lag = alignForCheck(auDry, gone, limit: Self.auCaptureFrames)
        let ov = overlapForCheck(auDry, gone, lag: lag, limit: Self.auCaptureFrames)
        let matched = matchedFramesForCheck(auDry, gone, lag: lag, count: ov.count)
        auNote("卸掉 vs 干信号: lag=\(lag) n=\(ov.count) 逐帧相同=\(matched == ov.count ? "YES" : "NO")(\(matched))")
        auHistory()
    }

    /// 9) 撤销链路：装载 → 撤销 → 重做 → [A→B] → 撤销复制，全靠快照里的身份重新实例化。
    private func auHistory() {
        guard let vm = vm, let delay = auPlugin else { auFinish(); return }
        let steps: [(label: String, fire: () -> Void, settled: () -> Bool)] = [
            ("重新装载", { vm.loadPlugin(delay, at: 0, for: .a) }, { vm.slots(.a)[0].plugin != nil }),
            ("撤销装载", { vm.undoEdit() },
             { vm.slots(.a)[0].plugin == nil && !vm.slots(.a)[0].loading }),
            ("重做装载", { vm.redoEdit() }, { vm.slots(.a)[0].plugin != nil }),
            ("复制 [A→B]", { vm.copyChannelStrip(from: .a, to: .b) }, { vm.slots(.b)[0].plugin != nil }),
            ("撤销复制", { vm.undoEdit() }, { vm.slots(.b)[0].plugin == nil }),
        ]
        auRun(steps)
    }

    private func auRun(_ steps: [(label: String, fire: () -> Void, settled: () -> Bool)], index: Int = 0) {
        guard let vm = vm else { return }
        guard index < steps.count else {
            vm.stopPlayback()
            auFinish()
            return
        }
        let step = steps[index]
        step.fire()
        awaitForCheck(step.label, step.settled) { settled in
            self.auNote("\(step.label): 成=\(settled) "
                        + "A槽1=\(vm.slots(.a)[0].plugin?.name ?? "空") "
                        + "B槽1=\(vm.slots(.b)[0].plugin?.name ?? "空") "
                        + "attach 数=\(AudioEngine.shared.debugAttachedPluginCount)")
            self.auRun(steps, index: index + 1)
        }
    }

    // MARK: 播放头跟随动画探针（AB_FOLLOW_CHECK）

    /// τ 是这段动画唯一的旋钮，所以量它：先开「画面跟随播放头」并把缩放拉到 8×
    /// （不放大跟画面根本不动），等缩放那一段自己收敛完，再往前跳 25 s 让画面重新
    /// 追一次目标点。每段动画收敛完由 WaveformNSView 记一行到 <路径>.follow。
    /// 它不动播放状态，跑完停在 45 s。
    private func exerciseFollowForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseFollowForCheck(remaining: remaining - 1)
            }
            return
        }
        vm.pause()
        vm.setActiveTrack(.a)
        vm.seekSide(.a, to: 20)
        SettingsStore.shared.waveformFollowPlayhead = true
        writeDiag("FOLLOW: 探针开跑 loadPending=\(vm.loadPending) zoom=\(vm.waveformHorizontalZoom) 跟随=\(SettingsStore.shared.waveformFollowPlayhead)\n")
        vm.waveformHorizontalZoom = 8
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            vm.seekSide(.a, to: 45)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                vm.waveformHorizontalZoom = 1
            }
        }
    }

    // MARK: 播放头帧率探针（AB_PLAYHEAD_PERF）
    //
    // 「跟随 + 水平缩放后播放，动画卡顿，似乎帧率很低」——这句话能拿数字说的只有三件：
    // 一秒画几帧、一帧按住主线程多少毫秒、播放头的值一秒到几次。所以这一支把 8× 缩放和
    // 跟随摆好，分「贴右沿（画面在推）/ 不贴右沿（只有一根线在动）/ 关掉跟随」三段，
    // 每秒抄一行。
    private func exercisePlayheadPerfForCheck(remaining: Int = 300) {
        guard let vm = vm, let path = WaveformNSView.perfPath else { return }
        // 音轨没就绪就先别播：那 6 秒量到的是装载，不是播放。
        if vm.loadPending > 0 {
            guard remaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exercisePlayheadPerfForCheck(remaining: remaining - 1)
            }
            return
        }
        func step(_ line: String) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
            }
        }
        try? "".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        let dur = max(1.0, AudioEngine.shared.durationA)
        vm.setActiveTrack(.a)
        vm.waveformHorizontalZoom = 8
        SettingsStore.shared.waveformFollowPlayhead = true
        // 三段各播 6 / 6 / 3 秒：
        // ① 贴右沿 —— 跟随真正在推画面（裁定的那一态）；视野起点 s = ph − 1/8 + 0.01。
        // ② 窗口中间 —— 播放头自己走、画面不动：`ph < s` 那支把 s 钉在播放头上，
        //    之后要走到右margin（0.115 × 全曲 ≈ 27 s）才开始推，所以 6 秒里画面是静的。
        // ③ 关掉跟随 —— 对照，只剩那一根线在动。
        vm.seekSide(.a, to: dur * 0.5)
        vm.seekSide(.a, to: dur * 0.62)
        vm.play()
        step(String(format: "开跑：缩放 %.0f× · 跟随=开 · 全曲 %.1f s · 贴右沿 %.1f s 起\n",
                    vm.waveformHorizontalZoom, dur, dur * 0.62))
        WaveformNSView.perfReset()
        var followTick = 0
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            followTick += 1
            step(WaveformNSView.perfLineAndReset(label: "跟随·贴右沿 第\(followTick)秒"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            timer?.invalidate()
            vm.seekSide(.a, to: dur * 0.55)
            WaveformNSView.perfReset()
            var midTick = 0
            var midTimer: Timer?
            midTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                midTick += 1
                step(WaveformNSView.perfLineAndReset(label: "跟随·不贴右沿 第\(midTick)秒"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                midTimer?.invalidate()
                SettingsStore.shared.waveformFollowPlayhead = false
                WaveformNSView.perfReset()
                var offTick = 0
                var offTimer: Timer?
                offTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    offTick += 1
                    step(WaveformNSView.perfLineAndReset(label: "不跟随 第\(offTick)秒"))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    offTimer?.invalidate()
                    vm.pause()
                    SettingsStore.shared.waveformFollowPlayhead = true
                    vm.waveformHorizontalZoom = 1
                    step("已暂停，探针结束\n")
                }
            }
        }
    }

    // MARK: 探针（AB_EDITOR_CHECK）

    /// 四件事，每件都要有实据：
    /// 1) 参数面板那条路（滑杆 → beginGesture → AUParameter.address → unit）写得进音频：
    ///    把延迟设成 0.25 s，自相关峰就该搬到 0.25 s × 链路采样率那一格；
    /// 2) fullState 带得走：[A→B] 复制、撤销、重做之后，那格的延迟还得是 0.25 s，
    ///    而撤销到「写参数之前」得把它退回默认值；
    /// 3) 原生界面取取得到，参数表有几行，浮窗跟不跟得上槽位（卸掉就关、退模式全收）；
    /// 4) ⌘F 落在活动轨从上往下第一个空槽，V 收得起来也放得回去。
    private func exerciseEditorForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("EDITOR: 音轨未在 60s 内就绪，跳过\n", suffix: ".editor")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseEditorForCheck(remaining: remaining - 1)
            }
            return
        }
        edLines = []
        auLines = []            // 采样的行跟着 .au 文件走，别混进编辑器报告
        vm.setOutputGain(0)
        vm.setActiveTrack(.a)
        vm.stopPlayback()
        vm.setEditMode(true)
        vm.setPreGain(0, for: .a)
        vm.setLaneFader(0, for: .a)
        vm.setPan(0, for: .a)
        guard let delay = PluginCatalog.effects().first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                                && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
            edNote("本机 plist 里没有 Apple AUDelay，跳过")
            edFinish()
            return
        }
        edDry = auCapture("干信号          ")
        vm.loadPlugin(delay, at: 0, for: .a)
        awaitForCheck("装载 AUDelay", { vm.slots(.a)[0].plugin != nil }) { loaded in
            self.edNote("装载 \(delay.name): 等到=\(loaded)")
            guard loaded, let unit = AudioEngine.shared.unit(.a, at: 0),
                  let tree = unit.auAudioUnit.parameterTree else {
                self.edNote("拿不到 unit 或参数树，跳过")
                self.edFinish()
                return
            }
            self.edDumpParams(tree.allParameters)
            self.edWriteParam(unit: unit, plugin: delay, vm: vm)
        }
    }

    private func edDumpParams(_ params: [AUParameter]) {
        edNote("参数树: \(params.count) 行")
        for p in params {
            edNote("  addr=\(p.address) 「\(p.displayName)」 量程 \(p.minValue)…\(p.maxValue) "
                   + "当前=\(p.value) 单位=\"\(p.unitName ?? "")\" 对数=\(PluginEditorModel.isLogarithmic(p)) "
                   + "可写=\(PluginEditorModel.isWritable(p)) 读数=\"\(PluginEditorModel.detailString(for: p))\"")
        }
    }

    /// 走界面那条路写参数：先 beginGesture（那记的就是撤销要回到的状态），再把折回
    /// 量程的值按地址写进去。同一个 AUParameter 对象，和滑杆拖的是一根线。
    private func edWriteParam(unit: AVAudioUnitEffect, plugin: AUPlugin, vm: PlayerViewModel) {
        edStep("写参数")
        guard let tree = unit.auAudioUnit.parameterTree else { edNativeCheck(vm: vm); return }
        // 参数名是本地化的（这台机器上 AUDelay 报「延迟时间」），按名字认不出就退回单位。
        guard let time = tree.allParameters.first(where: {
                $0.displayName.lowercased().contains("delay") || $0.displayName.contains("延迟")
                || $0.unitName == "Secs" || $0.unitName == "秒" }) else {
            edNote("没有延迟参数，音频比对跳过")
            edNativeCheck(vm: vm)
            return
        }
        edDelayAddress = time.address
        let log = PluginEditorModel.isLogarithmic(time)
        let original = Double(time.value)      // 写之前那一档，撤销就该退回到这儿
        let model = PluginEditorModel(side: .a, index: 0, unit: unit, plugin: plugin)
        var gestures = 0
        model.onWillEdit = { gestures += 1; vm.beginEdit() }
        let position = PluginEditorScale.position(value: Self.edWantedDelay, min: Double(time.minValue),
                                                  max: Double(time.maxValue), logarithmic: log)
        let back = PluginEditorScale.value(position: position, min: Double(time.minValue),
                                           max: Double(time.maxValue), logarithmic: log)
        model.beginGesture()
        model.setValue(AUValue(back), address: time.address)
        let read = tree.allParameters.first { $0.address == time.address }?.value ?? .nan
        edOriginal = original
        edNote(String(format: "界面写参数: 想要 %.2f s（原来是 %.2f）· 滑杆位置 %.4f · 折回 %.4f · "
                      + "读回 %.4f（「%@」addr=%d）",
                      Self.edWantedDelay, original, position, back, Double(read),
                      time.displayName, time.address))
        edNote("  onWillEdit=\(gestures) 次 · 记完这笔 canUndo=\(vm.canUndo)")
        edWetCapture(vm: vm, seconds: Double(read))
    }

    private func edWetCapture(vm: PlayerViewModel, seconds: Double) {
        edStep("采样湿信号")
        let rate = AudioEngine.shared.debugConnectionRate
        edDelaySeconds = seconds
        guard seconds > 0, seconds.isFinite else {
            edNote("延迟值不像话（\(seconds)），不做音频比对")
            edNativeCheck(vm: vm)
            return
        }
        let expect = Int(seconds * (rate > 0 ? rate : 44_100))
        let wet = auCapture("界面写入 \(seconds)s")
        edNote(String(format: "延迟 %.2f s → 期望相关峰 %d 帧（链路 %.0f Hz）", seconds, expect, rate))
        edNote("  " + auAutocorrLine("湿", wet, expect: expect))
        edNote("  " + auAutocorrLine("干", edDry, expect: expect))
        vm.stopPlayback()
        edCopyAndHistory(vm: vm)
    }

    /// 2) fullState：复制 → 撤销 → 重做 → 撤销两次（退到写参数之前）。
    private func edCopyAndHistory(vm: PlayerViewModel) {
        edStep("复制与历史")
        vm.copyChannelStrip(from: .a, to: .b)
        awaitForCheck("复制 [A→B]", { AudioEngine.shared.unit(.b, at: 0) != nil }) { ok in
            let copied = self.edParamValue(.b, 0)
            self.edNote("[A→B] 之后 B槽1 延迟=\(self.f(copied)) 期望=\(self.f(self.edDelaySeconds)) → "
                        + "\(self.near(copied, self.edDelaySeconds) ? "带上来了" : "没带上来")（成=\(ok)）")
            vm.undoEdit()
            self.awaitForCheck("撤销复制", { vm.slots(.b)[0].plugin == nil }) { undone in
                let stillA = self.edParamValue(.a, 0)
                self.edNote("撤销复制: B槽1 空=\(undone) · A槽1 延迟=\(self.f(stillA))（该没被牵动）")
                vm.redoEdit()
                self.awaitForCheck("重做复制", { AudioEngine.shared.unit(.b, at: 0) != nil }) { again in
                    let redone = self.edParamValue(.b, 0)
                    self.edNote("重做复制: B槽1 有=\(again) · 延迟=\(self.f(redone)) → "
                                + "\(self.near(redone, self.edDelaySeconds) ? "参数也回来了" : "参数丢了")")
                    // 再撤两下：第一下撤掉复制，第二下撤掉那次写参数 —— 撤的是 fullState。
                    vm.undoEdit()
                    vm.undoEdit()
                    self.edUndoToDefault(vm: vm)
                }
            }
        }
    }

    private func edUndoToDefault(vm: PlayerViewModel) {
        edStep("撤到写参数之前")
        awaitForCheck("撤到写参数之前", { vm.slots(.b)[0].plugin == nil }) { ok in
            let back = self.edParamValue(.a, 0)
            self.edNote("撤销写参数: 等到=\(ok) · A槽1 延迟=\(self.f(back)) · 写之前=\(self.f(self.edOriginal)) → "
                        + "\(self.near(back, self.edOriginal ?? -.infinity) ? "fullState 把人带回了写之前那一档" : "没退回")")
            self.edNativeCheck(vm: vm)
        }
    }

    /// 3) 浮窗：原生界面、参数表行数和窗口尺寸。
    private func edNativeCheck(vm: PlayerViewModel) {
        edStep("原生界面")
        let editors = PluginEditorController.shared
        // 载入即开窗是这一轮新加的手感，走到这里 A 格 1 的浮窗其实已经开着了；
        // 再 toggle 一下只会把它关掉，所以只在没开的时候开。
        if !editors.isShowing(.a, index: 0) { vm.toggleSlotEditor(0, for: .a) }
        edNote("开浮窗: isShowing=\(editors.isShowing(.a, index: 0)) · 窗口数=\(editors.openCount)")
        awaitForCheck("原生界面", remaining: 400, { editors.debugNativeView(.a, index: 0) != nil }) { got in
            let view = editors.debugNativeView(.a, index: 0)
            let window = editors.window(for: .a, 0)
            self.edNote("原生界面: 取到=\(got) · 视图=\(Self.sizeText(view?.frame.size)) · "
                        + "窗口=\(Self.sizeText(window?.frame.size)) · 标题=\"\(window?.title ?? "-")\" · "
                        + "还在等=\(editors.debugAwaitingNative(.a, index: 0))")
            // 数的是模型里的参数表数据：浮窗只在插件没有原生界面时才画这张表（裁决②），
            // 所以这一行有数字不代表界面多画了一层，上面那行「取到=true」才是判据。
            let params = editors.debugParams(.a, index: 0)
            self.edNote("参数表数据: \(params.count) 行（只在没有原生界面时才上屏）· "
                        + "首行=\"\(params.first.map { "\($0.name) \($0.detail)" } ?? "-")\"")
            // 橡皮擦指针只能这样验：这台机器进不去合成鼠标事件，截图也拍不到光标。
            self.edNote("⌘ 橡皮擦指针: \(EraserCursor.debugLabel)")
            if let base = ProcessInfo.processInfo.environment["AB_MENUDUMP"], base != "1" {
                EraserCursor.debugWriteImage(to: base + ".eraser.png")
            }
            self.edSearchAndPages(vm: vm)
        }
    }

    /// 4) ⌘F 找插件 + V 收放全部页面。
    private func edSearchAndPages(vm: PlayerViewModel) {
        edStep("搜索框与 V")
        vm.closeBrowser()
        vm.openPluginSearch()
        let target = vm.browserTarget
        edNote("⌘F: 混音器可见=\(MixerPanelController.shared.isVisible) · "
               + "目标槽=\(target.map { "\($0.side == .a ? "A" : "B") 格 \($0.index + 1)" } ?? "无") · 期望「A 格 2」"
               + "（A 格 1 还占着）")
        vm.closeBrowser()
        let editors = PluginEditorController.shared
        vm.toggleAllPluginPages()
        edNote("V 收起: 窗口数=\(editors.openCount) · 可见=\(editors.anyVisible)")
        vm.toggleAllPluginPages()
        edNote("V 放回: 窗口数=\(editors.openCount) · 可见=\(editors.anyVisible)")
        edReopenCheck(vm: vm)
    }

    /// 5) 关掉再开：实测 requestViewController 对同一个 unit 只回一次话（第一次给
    ///    484×255 的界面，往后一律 nil），所以取到的那位得按 unit 存着。
    ///    这就是「第二次打开变成参数表」那道的验收。
    private func edReopenCheck(vm: PlayerViewModel) {
        edStep("重开浮窗")
        let editors = PluginEditorController.shared
        let wasShowing = editors.isShowing(.a, index: 0)
        if wasShowing { vm.toggleSlotEditor(0, for: .a) }
        let closed = !editors.isShowing(.a, index: 0)
        vm.toggleSlotEditor(0, for: .a)
        awaitForCheck("重开浮窗", remaining: 200, { editors.debugNativeView(.a, index: 0) != nil }) { got in
            self.edNote("重开 A格1（先前开着=\(wasShowing) · 关掉=\(closed)）: 仍是原生界面=\(got) · "
                        + "视图=\(Self.sizeText(editors.debugNativeView(.a, index: 0)?.frame.size)) · "
                        + "还在等=\(editors.debugAwaitingNative(.a, index: 0))")
            self.edMusicEffectCheck(vm: vm)
        }
    }

    /// 6) aumf（音乐效果器）：清单收不收、通道槽接不接得住、装完有没有声音、
    ///    有没有原生界面。FabFilter 全在线就是这一类，用户报的「部分插件未显示」是它。
    private func edMusicEffectCheck(vm: PlayerViewModel) {
        edStep("aumf")
        let editors = PluginEditorController.shared
        let catalog = PluginCatalog.effects()
        let mfxCount = catalog.filter { $0.kind == .musicEffect }.count
        let fab = PluginCatalog.fourCC("FabF")
        guard let mfx = catalog.first(where: { $0.kind == .musicEffect && $0.manufacturer == fab })
                ?? catalog.first(where: { $0.kind == .musicEffect }) else {
            edNote("aumf: 清单 \(catalog.count) 条里没有音乐效果器，跳过")
            edSlotKeyCheck(vm: vm)
            return
        }
        vm.loadPlugin(mfx, at: 1, for: .a)
        awaitForCheck("装载 \(mfx.name)", remaining: 600, { vm.slots(.a)[1].plugin != nil }) { loaded in
            self.edNote("aumf: 清单 \(catalog.count) 条（其中 aumf \(mfxCount) 条）· 装「\(mfx.name)」"
                        + "(\(mfx.kind.rawValue)/\(PluginCatalog.string(mfx.subtype))/\(mfx.manufacturerName))"
                        + " 进 A格2: 装上=\(loaded)")
            guard loaded else {
                self.edNote("  轨迹=\(AudioEngine.shared.debugSlotTrace)")
                self.edSlotKeyCheck(vm: vm)
                return
            }
            // 混音器的表也在抽同一个抽头，它在场就轮不到探针读数，先收掉。
            MixerPanelController.shared.close()
            vm.seekSide(.a, to: 60)
            vm.play()
            // 抽头 100 ms 才来一包，等 1.5 s 攒够十几包再读一次；A 格 1 那颗 AUDelay
            // 这会儿是默认 1 s 延迟，等短了只会读到干信号那一半。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let tap = vm.lanePeakDB(.a)
                vm.stopPlayback()
                self.edNote(String(format: "  A轨输出峰值 L=%.2f R=%.2f dBFS（非 −96 就是音频真过了这一级）",
                                    tap.left, tap.right))
                vm.toggleSlotEditor(1, for: .a)
                self.awaitForCheck("aumf 原生界面", remaining: 400,
                                   { editors.debugNativeView(.a, index: 1) != nil }) { got in
                    self.edNote("  原生界面: 取到=\(got) · "
                                + "视图=\(Self.sizeText(editors.debugNativeView(.a, index: 1)?.frame.size)) · "
                                + "参数行=\(editors.debugParams(.a, index: 1).count)")
                    self.edSlotKeyCheck(vm: vm)
                }
            }
        }
    }

    /// 7) 硬编码的插槽键：裸数字开 A 轨那一格、⇧ + 数字开 B 轨那一格。用户报的正是
    ///    「⇧1…⇧6 打不开 B 轨窗口」，所以两轨各按一遍，顺带确认 ⌃1 依旧不吃这一下
    ///    （⌃ 要留给走带栏的 J/K/L 收窄）。合成事件进的是监听闭包里那同一个 `slotKey`
    ///    入口——这台机器注入不了真按键，探针不另抄一份规则才有意义。
    private func edSlotKeyCheck(vm: PlayerViewModel) {
        edStep("插槽键 1 / ⇧1")
        let editors = PluginEditorController.shared
        let catalog = PluginCatalog.effects()
        guard let delay = catalog.first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
            edNote("插槽键: 本机 plist 里没有 Apple AUDelay，跳过")
            edSlotSync(vm: vm)
            return
        }
        vm.setEditMode(true)
        vm.loadPlugin(delay, at: 0, for: .b)
        awaitForCheck("B格1 装上", remaining: 600, { vm.slots(.b)[0].plugin != nil }) { loaded in
            guard loaded else {
                self.edNote("插槽键: B格1 装不上，跳过 · 轨迹=\(AudioEngine.shared.debugSlotTrace)")
                self.edSlotSync(vm: vm)
                return
            }
            // 两边的窗口先各自收平，免得把「先前就开着」记成这一下按开的。
            if editors.isShowing(.a, index: 0) { vm.toggleSlotEditor(0, for: .a) }
            if editors.isShowing(.b, index: 0) { vm.toggleSlotEditor(0, for: .b) }
            func shown(_ side: TrackSide) -> Bool { editors.isShowing(side, index: 0) }
            var lines = ["插槽键（1＝A格1 · ⇧1＝B格1）: 开跑前 A开着=\(shown(.a)) B开着=\(shown(.b))"]
            if let one = Self.digitKeyForCheck(modifiers: []) {
                let first = self.slotKey(one, vm: vm)
                lines.append("按 1: 吃掉=\(first) · A开着=\(shown(.a))（该开） · B开着=\(shown(.b))（该关）")
                let again = self.slotKey(one, vm: vm)
                lines.append("再按 1: 吃掉=\(again) · A开着=\(shown(.a))（该关，toggle 走得回去）")
            } else { lines.append("按 1: 造不出事件") }
            if let shift = Self.digitKeyForCheck(modifiers: [.shift]) {
                let took = self.slotKey(shift, vm: vm)
                lines.append("按 ⇧1（cim=\(shift.charactersIgnoringModifiers ?? "-") kc=\(shift.keyCode)）: "
                             + "吃掉=\(took) · A开着=\(shown(.a))（该关） · B开着=\(shown(.b))（该开）")
                let took2 = self.slotKey(shift, vm: vm)
                lines.append("再按 ⇧1: 吃掉=\(took2) · B开着=\(shown(.b))（该关）")
            } else { lines.append("按 ⇧1: 造不出事件") }
            if let ctrl = Self.digitKeyForCheck(modifiers: [.control]) {
                let took = self.slotKey(ctrl, vm: vm)
                lines.append("按 ⌃1: 吃掉=\(took)（该是 false） · A开着=\(shown(.a)) · B开着=\(shown(.b))")
            }
            lines.forEach { self.edNote($0) }
            self.edSlotSync(vm: vm)
        }
    }

    /// 卸掉一格（⌘+点走的就是这条路）：浮窗得跟着关，因为那格的插件身份变了。
    private func edSlotSync(vm: PlayerViewModel) {
        edStep("卸格与退模式")
        let editors = PluginEditorController.shared
        vm.unloadSlot(0, for: .a)
        edNote("卸掉 A格1: 浮窗跟着关=\(!editors.isShowing(.a, index: 0)) · 窗口数=\(editors.openCount)")
        vm.toggleSlotEditor(0, for: .a)
        edNote("空槽开窗: isShowing=\(editors.isShowing(.a, index: 0))（该是 false）")
        vm.setEditMode(false)
        edNote("退编辑模式: 窗口数=\(editors.openCount) · 混音器可见=\(MixerPanelController.shared.isVisible) · "
               + "模式=\(vm.editMode) · attach 数=\(AudioEngine.shared.debugAttachedPluginCount)（实例该留着）")
        edFinish()
    }

    private func edParamValue(_ side: TrackSide, _ index: Int) -> Double? {
        guard let address = edDelayAddress,
              let value = AudioEngine.shared.unit(side, at: index)?.auAudioUnit.parameterTree?
                    .allParameters.first(where: { $0.address == address })?.value else { return nil }
        return Double(value)
    }

    private func near(_ a: Double?, _ b: Double) -> Bool { abs((a ?? -.infinity) - b) < 0.01 }
    private func f(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
    private static func sizeText(_ size: NSSize?) -> String {
        size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "-"
    }

    /// 造一把数字键（keyCode 18 = 美式键盘的「1」）。两个字符字段按真机送的样子分开写：
    /// ⇧+1 时 charactersIgnoringModifiers 也是 "!"，不是 "1" —— 旧写法把它写成 "1"，于是
    /// 探针一直在按一个真机上不存在的事件，所以「探针过了、用户按着还是不通」。现在这条
    /// 按的是用户实际按下去的那一下。
    private static func digitKeyForCheck(modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        let shifted = modifiers.contains(.shift)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                timestamp: 0, windowNumber: 0, context: nil,
                                characters: shifted ? "!" : "1",
                                charactersIgnoringModifiers: shifted ? "!" : "1",
                                isARepeat: false, keyCode: 18)
    }

    /// 每一相开跑前留一颗面包屑：探针半路崩掉时整份报告一个字都出不来
    /// （writeDiag 只在终点落盘），这一行是唯一还看得见「死在哪一步」的东西。
    private func edStep(_ label: String) { writeDiag("STEP: \(label)\n", suffix: ".step") }

    private func edNote(_ line: String) { edLines.append(line) }
    private func edFinish() {
        // 采样那几行是助手写的，单独落一份，别丢。
        auFinish()
        writeDiag(edLines.joined(separator: "\n") + "\n", suffix: ".editor")
    }

    // MARK: 首次进编辑模式自动开混音器探针（AB_MIXEROPEN_CHECK）
    //
    // 规格是「一个进程只自动开一次」：头一回进模式该开，之后进出不该再开。这条不碰音频、
    // 不等装载，四下 setEditMode 就量得完。开窗是同步的，但仍隔 0.4 秒再抄一次，免得把
    // 「窗口刚建好还没 isVisible」记成「没开」。
    private func exerciseMixerAutoOpenForCheck() {
        guard let vm = vm else { return }
        let panel = MixerPanelController.shared
        var lines: [String] = []
        panel.close()
        vm.setEditMode(false)
        lines.append("第一次进模式前: 混音器可见=\(panel.isVisible)（该是 false）")
        vm.setEditMode(true)
        lines.append("第一次进模式后（立刻）: 混音器可见=\(panel.isVisible)（该是 true）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            lines.append("第一次进模式后（0.4 秒）: 混音器可见=\(panel.isVisible)（该是 true，这一开就用掉了那一次性额度）")
            panel.close()
            vm.setEditMode(false)
            vm.setEditMode(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                lines.append("第二次进模式后: 混音器可见=\(panel.isVisible)（该是 false，额度已用完）")
                vm.setEditMode(false)
                lines.append("收尾: 模式=\(vm.editMode) · 混音器可见=\(panel.isVisible)")
                self.writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".mixeropen")
            }
        }
    }

    // MARK: 预设菜单探针（AB_PRESET_CHECK）
    //
    // 把「预设」那一格从两个开访达的面板改成「直接列文件夹 + 默认档进出」，四条动作
    // 全挂在 PlayerViewModel 上，菜单只是把它们摆出来。这一支证的就是那四条：默认档写得
    // 出去、默认档不混进载入列表（它有正门）、列表认得出真预设、恢复能把 pre-gain 和旋钮
    // 一起带回来、移除一次清干净且只记一笔历史（一笔撤销就该全回来）。

    private var presetLines: [String] = []
    private func presetNote(_ line: String) {
        presetLines.append(line)
        writeDiag(presetLines.joined(separator: "\n") + "\n", suffix: ".preset")
    }

    private func exercisePresetsForCheck() {
        guard let vm = vm else { return }
        showEditModeForCheck()
        awaitForCheck("进编辑模式", { vm.editMode }) { settled in
            guard settled else { self.presetNote("PRESET: 没进得了编辑模式，跳过"); return }
            let dir = ProjectStore.presetDirectory
            let extra = dir.appendingPathComponent("探针预设.abpreset")
            let defURL = ProjectStore.defaultPresetURL(for: .a)
            let defWasThere = FileManager.default.fileExists(atPath: defURL.path)
            self.presetNote("目录: 预设=\(dir.path) 默认档=\(defURL.lastPathComponent)"
                            + "（同一处=\(dir.path == ProjectStore.fixedPresetDirectory.path)）")
            let catalog = PluginCatalog.effects()
            // 两格用同一颗：这正好顺带证「同一轨两格同款」不会把两格接到同一个节点
            // （那一条修过一次，见 restoreSlots 的按 id 排队）。
            guard let delay = catalog.first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                    && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
                self.presetNote("PRESET: 本机没有 Apple AUDelay，跳过"); return
            }
            vm.setPreGain(-6.5, for: .a)
            vm.loadPlugin(delay, at: 0, for: .a)
            vm.loadPlugin(delay, at: 1, for: .a)
            self.awaitForCheck("两格都装上", remaining: 2_400, {
                vm.slots(.a)[0].plugin != nil && vm.slots(.a)[1].plugin != nil
            }) { loaded in
                guard loaded else { self.presetNote("PRESET: 插件没装上，跳过"); return }
                vm.saveDefaultPreset(for: .a)
                self.presetNote("存默认: 文件在盘=\(FileManager.default.fileExists(atPath: defURL.path))")
                let listed = ProjectStore.channelPresets().map { $0.lastPathComponent }
                self.presetNote("列表(只存了默认档): \(listed) · 默认档没混进来=\(!listed.contains(defURL.lastPathComponent))")
                try? ProjectStore.write(preset: vm.channelPreset(for: .a), to: extra)
                let listed2 = ProjectStore.channelPresets().map { $0.lastPathComponent }
                self.presetNote("列表(又写了一份真预设): \(listed2) · 收进来了=\(listed2.contains(extra.lastPathComponent))")

                vm.setPreGain(0, for: .a)
                vm.removeAllPlugins(for: .a)
                let emptied = vm.slots(.a).allSatisfy { $0.plugin == nil }
                self.presetNote("移除全部: 六格都空=\(emptied) · pre-gain 没被动=\(vm.preGainA == 0)")
                vm.undoEdit()
                self.awaitForCheck("一笔撤销把两格都带回", remaining: 2_400, {
                    vm.slots(.a)[0].plugin != nil && vm.slots(.a)[1].plugin != nil
                }) { bothBack in
                    self.presetNote("撤销一笔: 两格同时回来=\(bothBack)")
                    vm.removeAllPlugins(for: .a)
                    vm.restoreDefaultPreset(for: .a)
                    self.awaitForCheck("默认档落地", remaining: 2_400, {
                        vm.slots(.a)[0].plugin != nil && vm.slots(.a)[1].plugin != nil
                    }) { restored in
                        self.presetNote("恢复默认: 两格=\(restored) · pre-gain=\(String(format: "%.1f", vm.preGainA))"
                                        + "（该是 -6.5）· 格1=\(vm.slots(.a)[0].plugin?.name ?? "空")"
                                        + " 格2=\(vm.slots(.a)[1].plugin?.name ?? "空")")
                        try? FileManager.default.removeItem(at: extra)
                        if !defWasThere { try? FileManager.default.removeItem(at: defURL) }
                        self.presetNote("收尾: 探针文件已清 · B 轨默认档还在=\(ProjectStore.hasDefaultPreset(for: .b))")
                    }
                }
            }
        }
    }

    // MARK: 工程文件与轨道预设探针（AB_PROJECT_CHECK / AB_RESTORE_CHECK）
    //
    // 两支探针各管一半：这一支证「写得出去、读得回来，而且只回到自己那一轨」；另一支
    // 不带 --autoplay 启动，证「下次打开直接恢复」真发生在启动那一下。
    //
    // NSSavePanel/NSOpenPanel 是模态的，主线程一进去就出不来，所以存取都直接把路径交给
    // 落盘那一步，面板那条路交给眼睛（截图）；⌘S 则真的按下去 —— 递进 NSMenu 的
    // performKeyEquivalent，那一刻工程已经挂着路径，所以它不该弹窗，只该改盘上的数字。
    //
    // 三个 scratch 文件都固定放在 /tmp/abproj，两支探针共用。标记库是用户自己的数据
    // （存在偏好里），探针往里写过就必须还原，所以动手前先把那一份快照落盘。

    private static let projScratch = "/tmp/abproj"
    private static var projPresetURL: URL { URL(fileURLWithPath: "\(projScratch)/preset.abpreset") }
    private static var projProjectURL: URL { URL(fileURLWithPath: "\(projScratch)/project.abpl") }
    private static var projMarkersURL: URL { URL(fileURLWithPath: "\(projScratch)/markers.json") }

    private var projLines: [String] = []
    /// 每行都顺手落一次盘：装载是异步的，中途卡在哪一格只有边跑边写看得见。
    private func projNote(_ line: String) {
        projLines.append(line)
        writeDiag(projLines.joined(separator: "\n") + "\n", suffix: ".proj")
    }
    private func projFinish() { projNote("—— 完 ——") }

    private func exerciseProjectForCheck() {
        guard let vm = vm else { return }
        try? FileManager.default.createDirectory(atPath: Self.projScratch, withIntermediateDirectories: true)
        let markersBefore = MarkerStore.shared.allMarkers
        if let data = try? JSONEncoder().encode(markersBefore) {
            try? data.write(to: Self.projMarkersURL)
        }
        projNote("scratch: 预设=\(Self.projPresetURL.path) 工程=\(Self.projProjectURL.path)")
        projNote("动手前: 列表=\(vm.tracks.count) 条 · 标记库=\(markersBefore.count) 个文件 · 编辑模式=\(vm.editMode)")
        awaitForCheck("音轨就绪", remaining: 2400, { vm.loadPending == 0 }) { ready in
            guard ready else {
                self.projNote("音轨没在 120 秒内就绪，跳过")
                self.projFinish()
                return
            }
            self.projStripCheck(vm)
        }
    }

    /// ① A 轨摆出一整条通道条：pre-gain、推子、声像、一格插件（带旋钮位置和单格旁通）
    /// 外加整轨旁通。这一副样子就是预设该带走的东西。
    private func projStripCheck(_ vm: PlayerViewModel) {
        let catalog = PluginCatalog.effects()
        guard let delay = catalog.first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
            projNote("本机 plist 里没有 Apple AUDelay，跳过")
            projFinish()
            return
        }
        vm.setEditMode(true)
        vm.setPreGain(-3, for: .a)
        vm.setLaneFader(-2.5, for: .a)
        vm.setPan(-20, for: .a)
        vm.loadPlugin(delay, at: 0, for: .a)
        awaitForCheck("A 轨装载 AUDelay", { vm.slots(.a)[0].plugin != nil }) { loaded in
            guard loaded, let unit = AudioEngine.shared.unit(.a, at: 0) else {
                self.projNote("① AUDelay 没装上，跳过")
                self.projFinish()
                return
            }
            Self.projSetDelay(unit, to: 0.25)
            vm.toggleSlotBypass(0, for: .a)
            vm.toggleLaneBypass(.a)
            self.projNote("① A 轨摆好: preGain=\(vm.preGainA) 推子=\(vm.laneFaderA) 声像=\(vm.panA) "
                          + "槽0=\(vm.slots(.a)[0].plugin?.name ?? "-")(旁通=\(vm.slots(.a)[0].bypass)) "
                          + "整轨旁通=\(vm.laneBypass(.a)) 延迟=\(Self.projDelayText(unit))")
            self.projPresetRoundTrip(vm)
        }
    }

    /// ②③ 预设写盘、读回来逐字节比一份，然后只贴到 B 轨 —— 两轨各装各的 unit，
    /// A 轨该原样留着（用户要的是「同一个插件两轨各一份、各自可调」）。
    private func projPresetRoundTrip(_ vm: PlayerViewModel) {
        let live = vm.channelPreset(for: .a)
        do {
            try ProjectStore.write(preset: live, to: Self.projPresetURL)
        } catch {
            projNote("② 预设写盘失败：\(error.localizedDescription)")
            projFinish()
            return
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: Self.projPresetURL.path))?[.size]
            as? Int) ?? 0
        let back: ChannelPreset
        do { back = try ProjectStore.readPreset(from: Self.projPresetURL) }
        catch {
            projNote("② 预设读回来失败：\(error.localizedDescription)")
            projFinish()
            return
        }
        projNote("② 预设落盘 \(bytes) B · 读回来与内存里那份一致=\(back == live) "
                 + "（AU 状态走的是 base64，\(live.slots.compactMap { $0 }.first?.state?.count ?? 0) B）")
        vm.applyChannelPreset(back, for: .b)
        awaitForCheck("B 轨插件就位", { vm.slots(.b)[0].plugin != nil }) { loaded in
            self.projNote("③ 贴到 B 轨: 槽0 有插件=\(loaded) · preGainB=\(vm.preGainB) 推子B=\(vm.laneFaderB) "
                          + "声像B=\(vm.panB) 槽0=\(vm.slots(.b)[0].plugin?.name ?? "-")"
                          + "(旁通=\(vm.slots(.b)[0].bypass)) 整轨旁通B=\(vm.laneBypass(.b)) "
                          + "延迟=\(Self.projDelayText(AudioEngine.shared.unit(.b, at: 0)))")
            self.projNote("   A 轨原样没动: preGainA=\(vm.preGainA) 槽0=\(vm.slots(.a)[0].plugin?.name ?? "-") "
                          + "延迟=\(Self.projDelayText(AudioEngine.shared.unit(.a, at: 0)))")
            self.projMissingPluginCheck(vm)
        }
    }

    /// ④ 预设里有一格本机没有：要报出名字，其余各格照旧装上。引擎是顺序装的，
    /// 不在这里先点名的话，撞空那一格会把它后面几格一起带走。
    private func projMissingPluginCheck(_ vm: PlayerViewModel) {
        var bogus = (try? ProjectStore.readPreset(from: Self.projPresetURL)) ?? vm.channelPreset(for: .a)
        let ghost = AUPlugin(type: PluginCatalog.fourCC("aufx"),
                             subtype: PluginCatalog.fourCC("gone"),
                             manufacturer: PluginCatalog.fourCC("xxxx"),
                             name: "本机没有的插件",
                             manufacturerName: "xxxx",
                             kind: .effect,
                             bundleName: "不存在.component")
        bogus.slots[3] = SlotSnapshot(plugin: ghost, bypass: false, state: nil)
        vm.applyChannelPreset(bogus, for: .b)
        awaitForCheck("缺件预设落地", { vm.slots(.b)[0].plugin != nil }) { loaded in
            self.projNote("④ 缺件预设: 槽0 仍在=\(loaded) · 槽3 空=\(vm.slots(.b)[3].plugin == nil) "
                          + "· 提示=「\(vm.pluginError ?? "没有")」")
            self.projProjectRoundTrip(vm)
        }
    }

    /// ⑤⑥ 工程：摆好 → 写盘 → 拆干净 → 读回来逐项对。备用列表不动（它是用户自己的存量，
    /// 拆散只拆播放列表，那一张本来就是会话级的）。
    private func projProjectRoundTrip(_ vm: PlayerViewModel) {
        guard let url = vm.trackA?.url else {
            projNote("⑤ A 轨没曲子，跳过")
            projFinish()
            return
        }
        vm.rangeA = ABRange(start: 1.0, end: 2.5)
        vm.rangeB = ABRange(start: 3.0, end: 4.0)
        SettingsStore.shared.outputGainDB = -4.2
        vm.setOutputGain(-4.2)
        MarkerStore.shared.addMarker(at: 5.0, for: url, kind: .global)
        vm.writeProject(to: Self.projProjectURL)
        guard let onDisk = try? ProjectStore.readProject(from: Self.projProjectURL) else {
            projNote("⑤ 工程写出去却读不回来")
            projFinish()
            return
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: Self.projProjectURL.path))?[.size]
            as? Int) ?? 0
        projNote("⑤ 工程落盘 \(bytes) B · 挂上路径=\(vm.projectURL?.path ?? "-") · 盘上: 列表=\(onDisk.tracks.count) 条"
                 + " · A 指派=\(onDisk.trackAID == nil ? "空" : "有")"
                 + " · rangeA=\(Self.projRangeText(onDisk.rangeA)) · 监听=\(onDisk.outputGainDB)"
                 + " · 编辑模式=\(onDisk.editMode) · laneA 槽0=\(onDisk.laneA.slots[0]?.plugin?.name ?? "-")"
                 + " · 标记=\(onDisk.markers[url.path]?.count ?? 0) 个")
        vm.unloadSlot(0, for: .a)
        vm.unloadSlot(0, for: .b)
        vm.setPreGain(Double(AudioEngine.preGainDefaultDB), for: .a)
        vm.setPreGain(Double(AudioEngine.preGainDefaultDB), for: .b)
        vm.setLaneFader(0, for: .a)
        vm.setLaneFader(0, for: .b)
        vm.setPan(0, for: .a)
        vm.setPan(0, for: .b)
        vm.rangeA = nil
        vm.rangeB = nil
        SettingsStore.shared.outputGainDB = 0
        vm.setOutputGain(0)
        MarkerStore.shared.restoreAll(MarkerStore.shared.allMarkers.filter { $0.key != url.path })
        vm.trackA = nil
        vm.trackB = nil
        vm.tracks = []
        vm.setEditMode(false)
        projNote("   拆散之后: 列表=\(vm.tracks.count) 条 · A=\(vm.trackA?.displayName ?? "空") "
                 + "· 槽0A=\(vm.slots(.a)[0].plugin?.name ?? "空") · 模式=\(vm.editMode) "
                 + "· rangeA=\(Self.projRangeText(vm.rangeA)) · 监听=\(SettingsStore.shared.outputGainDB)")
        vm.loadProject(from: Self.projProjectURL)
        awaitForCheck("恢复后两轨插件就位",
                      { vm.slots(.a)[0].plugin != nil && vm.slots(.b)[0].plugin != nil }) { ready in
            self.projNote("⑥ 恢复回来: 两轨都装上=\(ready) · 列表=\(vm.tracks.count) 条 · A=\(vm.trackA?.displayName ?? "-")")
            self.projNote("   preGainA=\(vm.preGainA) 推子A=\(vm.laneFaderA) 声像A=\(vm.panA) "
                          + "槽0A=\(vm.slots(.a)[0].plugin?.name ?? "-")(旁通=\(vm.slots(.a)[0].bypass)) "
                          + "延迟=\(Self.projDelayText(AudioEngine.shared.unit(.a, at: 0))) "
                          + "整轨旁通A=\(vm.laneBypass(.a))")
            self.projNote("   rangeA=\(Self.projRangeText(vm.rangeA)) rangeB=\(Self.projRangeText(vm.rangeB)) "
                          + "· 监听=\(SettingsStore.shared.outputGainDB) · 编辑模式=\(vm.editMode) "
                          + "· 标记=\(vm.markersA.count) 个 · 窗口=\(Self.projSizeText(WindowDefaults.target?.frame.size))"
                          + "（盘上 \(Self.projSizeText(width: onDisk.windowWidth, height: onDisk.windowHeight))）")
            self.projCmdSCheck(vm)
        }
    }

    /// ⑦ ⌘S：按的是菜单那一级，所以「菜单项接不接得住这把键」和「按下到底写了什么」
    /// 一起量。附带查一句按键表：⌘S 不能被表里的任何一行认领（裸 s 是下一轨道），
    /// 否则本地监视器会把它吃掉、菜单再也收不到。
    private func projCmdSCheck(_ vm: PlayerViewModel) {
        let claimed = ShortcutStore.shared.action(forPressWithKeyCode: 15,
                                                  modifiers: [.command],
                                                  charactersIgnoringModifiers: "s")
        projNote("⑦ 按键表对 ⌘S 的说法: 认领=\(claimed.map { String(describing: $0) } ?? "没有（放行给菜单）")")
        vm.setPreGain(-12, for: .a)
        let taken = Self.projKeyDown("s", [.command]).flatMap { NSApp.mainMenu?.performKeyEquivalent(with: $0) } ?? false
        let after = (try? ProjectStore.readProject(from: Self.projProjectURL))?.laneA.preGainDB ?? .nan
        projNote("   ⌘S: 菜单接住=\(taken) · 盘上 laneA.preGainDB=\(after)（该是 -12.0） "
                 + "· 界面=\(vm.preGainA) · 路径=\(vm.projectURL?.path ?? "-")")
        projCleanup(vm)
    }

    /// 收尾：标记库还原成动手前那份；工程路径故意留着不清 —— 下一轮不带 --autoplay
    /// 启动时，「下次打开直接恢复」认的就是这条偏好，由那一轮自己收掉。
    private func projCleanup(_ vm: PlayerViewModel) {
        MarkerStore.shared.restoreAll(Self.projReadMarkerSnapshot())
        vm.setEditMode(false)
        ProjectStore.lastProjectURL = Self.projProjectURL
        projNote("收尾: 标记库还原=\(MarkerStore.shared.allMarkers.count) 个文件 · 模式=\(vm.editMode) "
                 + "· lastProject=\(ProjectStore.lastProjectURL?.path ?? "-")（留给启动恢复那一轮）")
        projFinish()
    }

    /// 第二轮：不带 --autoplay，所以启动那一下该把 lastProject 那份工程恢复回来。
    /// `offRound` 是规格另一半：开关按默认关着，启动那一下什么都不该动 ——
    /// 这一档不清盘，lastProject 要留给随后那一档。
    private func exerciseRestoreForCheck(offRound: Bool = false) {
        guard let vm = vm else { return }
        guard let last = ProjectStore.lastProjectURL else {
            projNote("启动恢复: 偏好里没有存过的工程，跳过（先跑 AB_PROJECT_CHECK 那一轮）")
            projFinish()
            return
        }
        if offRound {
            projNote("启动恢复(开关=关): 偏好里的工程=\(last.path)")
            projNote("   列表=\(vm.tracks.count) 条(该是 0) · 挂着的工程=\(vm.projectURL?.path ?? "无（对）") "
                     + "· A=\(vm.trackA?.displayName ?? "无（对）") · 设置里读到=\(SettingsStore.shared.autoRestoreSession)")
            projFinish()
            return
        }
        projNote("启动恢复: 偏好的工程=\(last.path) · 文件在=\(FileManager.default.fileExists(atPath: last.path))")
        // 自动恢复排在启动后 1 秒，这里已经晚了 2 秒；插件装载还是异步的，等一等。
        awaitForCheck("恢复的通道条就位", remaining: 1200,
                      { !vm.editMode || (vm.slots(.a)[0].plugin != nil && vm.slots(.b)[0].plugin != nil) }) { ready in
            let saved = try? ProjectStore.readProject(from: last)
            self.projNote("列表=\(vm.tracks.count) 条 · 备用=\(vm.backupTracks.count) 条 · A=\(vm.trackA?.displayName ?? "-") "
                          + "· B=\(vm.trackB?.displayName ?? "-") · 挂着的工程=\(vm.projectURL?.path ?? "-")")
            self.projNote("   preGainA=\(vm.preGainA)(该是 -12.0) 推子A=\(vm.laneFaderA) 声像A=\(vm.panA) "
                          + "槽0A=\(vm.slots(.a)[0].plugin?.name ?? "-")(旁通=\(vm.slots(.a)[0].bypass)) "
                          + "延迟=\(Self.projDelayText(AudioEngine.shared.unit(.a, at: 0))) "
                          + "整轨旁通A=\(vm.laneBypass(.a)) · 插件都到=\(ready)")
            var onDiskMarkers: Int?
            if let path = vm.trackA?.url.path { onDiskMarkers = saved?.markers[path]?.count }
            self.projNote("   rangeA=\(Self.projRangeText(vm.rangeA))（盘上 \(Self.projRangeText(saved?.rangeA))） "
                          + "· 监听=\(SettingsStore.shared.outputGainDB)（盘上 \(saved?.outputGainDB.description ?? "-")） "
                          + "· 编辑模式=\(vm.editMode)（盘上 \(saved?.editMode.description ?? "-")）")
            self.projNote("   标记: 界面=\(vm.markersA.count) 个 · 盘上这一轨=\(onDiskMarkers.map { String($0) } ?? "-") 个 "
                          + "· 窗口=\(Self.projSizeText(WindowDefaults.target?.frame.size))"
                          + "（盘上 \(Self.projSizeText(width: saved?.windowWidth, height: saved?.windowHeight))）")
            self.projRestoreCleanup()
        }
    }

    /// 这一轮把两片 scratch 都收掉：偏好里的工程路径、标记库快照，还有 /tmp/abproj。
    /// 快照要补落一次盘：探针里装载、换模式都是异步的，实测收尾那一下之后还有一次迟到的
    /// 写入把探针自己加的标记贴回偏好，第二次按回去才干净（上一轮的标记不该留下）。
    private func projRestoreCleanup() {
        let snapshot = Self.projReadMarkerSnapshot()
        MarkerStore.shared.restoreAll(snapshot)
        vm?.setEditMode(false)
        ProjectStore.lastProjectURL = nil
        try? FileManager.default.removeItem(atPath: Self.projScratch)
        projNote("收尾: 标记库=\(MarkerStore.shared.allMarkers.count) 个文件 · lastProject=\(ProjectStore.lastProjectURL?.path ?? "已清") "
                 + "· /tmp/abproj 已删")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MarkerStore.shared.restoreAll(snapshot)
            self.projNote("补落一次: 标记库=\(MarkerStore.shared.allMarkers.count) 个文件")
            self.projFinish()
        }
    }

    private static func projReadMarkerSnapshot() -> [String: [Marker]] {
        ((try? Data(contentsOf: projMarkersURL)).flatMap { try? JSONDecoder().decode([String: [Marker]].self, from: $0) }) ?? [:]
    }

    static func projRangeText(_ range: ABRange?) -> String {
        guard let range else { return "无" }
        return String(format: "%.1f–%.1f", range.start, range.end)
    }

    static func projSizeText(_ size: CGSize?) -> String {
        guard let size else { return "-" }
        return String(format: "%.0f×%.0f", size.width, size.height)
    }

    static func projSizeText(width: Double?, height: Double?) -> String {
        guard let width, let height else { return "-" }
        return String(format: "%.0f×%.0f", width, height)
    }

    /// AUDelay 的「延迟时间」那一个参数。名字是本地化的，中文界面下叫「延迟时间」，
    /// 所以两边都认（踩过这一条）。
    private static func projDelayParam(_ unit: AVAudioUnitEffect?) -> AUParameter? {
        unit?.auAudioUnit.parameterTree?.allParameters.first {
            $0.displayName.contains("延迟") || $0.displayName.lowercased().contains("delay")
        }
    }

    private static func projSetDelay(_ unit: AVAudioUnitEffect, to seconds: Double) {
        projDelayParam(unit)?.value = AUValue(seconds)
    }

    private static func projDelayText(_ unit: AVAudioUnitEffect?) -> String {
        guard let param = projDelayParam(unit) else { return "读不到" }
        return String(format: "%.3f", Double(param.value))
    }

    private static func projKeyDown(_ characters: String,
                                    _ mods: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 15)
    }

    // MARK: 插件槽拖拽调序探针（AB_SLOTORDER_CHECK）
    //
    // 手势那一层在这台机器上验不了：拖拽要真鼠标（合成的 CGEvent 注不进来，混音器还是浮层
    // 面板、不一定接得到 key），⌥ 也只能真人按（全局 modifierFlags 改不动）。所以探针落在
    // 松手那一喊上 —— SlotCell.dropped 唯一的动作就是 vm.applySlotDrag(from:to:copy:)，
    // 六条走法逐条摆：同轨移动、同轨调换、⌥ 复制、⌥ 覆盖、跨轨搬、跨轨调换，
    // 外加撤销/重做（含「一轨两格同款插件」这条新路子）、历史笔数、浮窗跟格子。
    // 认人靠 AUDelay 的延迟参数：一轨上两枚同款插件只有参数不同，谁搬去了哪儿一目了然。
    // unit 的对象身份单独看：同轨调序该一颗都不换（数组换序而已），跨轨和复制该是新实例。

    private var slotLines: [String] = []
    private func slotNote(_ line: String) {
        slotLines.append(line)
        writeDiag(slotLines.joined(separator: "\n") + "\n", suffix: ".slotorder")
    }
    private func slotFinish() { slotNote("—— 完 ——") }

    /// 松手那一喊在主线程压了多少毫秒。这一句就是「系统那张拖拽药丸为什么迟到」的实证：
    /// SlotCell.dropped 走的是同一条路，perform 不返回，AppKit 就没空把 preview 撕掉。
    private func slotTimed(_ label: String, _ body: () -> Void) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        slotNote("⏱ \(label)：主线程 \(String(format: "%.2f", ms)) ms")
    }

    /// 自己数拍子的等待。等不到也往下走，但「没等到」要记进这一份账
    /// （公用的 awaitForCheck 把超时写进 .au，那一份是采样探针的）。
    private func slotAwait(_ label: String, remaining: Int = 1_200,
                           _ done: @escaping () -> Bool, then next: @escaping () -> Void) {
        if done() { DispatchQueue.main.async { next() }; return }
        guard remaining > 0 else {
            slotNote("⏱ \(label)：60 秒没等到位 · 现场=\(slotSummary(vm)) "
                     + "· 轨迹=\(AudioEngine.shared.debugSlotTrace)")
            DispatchQueue.main.async { next() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.slotAwait(label, remaining: remaining - 1, done, then: next)
        }
    }

    private static func slotDelay(_ side: TrackSide, _ index: Int) -> Double? {
        guard let param = Self.projDelayParam(AudioEngine.shared.unit(side, at: index)) else { return nil }
        return Double(param.value)
    }

    /// 某一格现在是不是这个延迟值（±20 ms 当同一档）。
    private static func delayNear(_ side: TrackSide, _ index: Int, _ want: Double) -> Bool {
        guard let d = slotDelay(side, index), d.isFinite else { return false }
        return abs(d - want) < 0.02
    }

    @discardableResult
    private static func slotSetDelay(_ side: TrackSide, _ index: Int, to seconds: Double) -> Bool {
        guard let unit = AudioEngine.shared.unit(side, at: index) else { return false }
        projSetDelay(unit, to: seconds)
        return true
    }

    private static func slotDelayText(_ side: TrackSide, _ index: Int) -> String {
        guard let d = slotDelay(side, index) else { return "无参数" }
        return String(format: "%.2fs", d)
    }

    /// 一格的样子：空 / 装… / 有·0.25s·旁。
    private static func slotMark(_ side: TrackSide, _ index: Int, _ vm: PlayerViewModel?) -> String {
        guard let vm else { return "?" }
        let s = vm.slots(side)[index]
        if s.loading { return "装…" }
        guard s.plugin != nil else { return "空" }
        return "有·\(slotDelayText(side, index))\(s.bypass ? "·旁" : "")"
    }

    private func slotSummary(_ vm: PlayerViewModel?) -> String {
        func lane(_ side: TrackSide) -> String {
            (0..<AudioEngine.slotCount).map { Self.slotMark(side, $0, vm) }.joined(separator: "|")
        }
        return "A[\(lane(.a))] B[\(lane(.b))]"
    }

    /// 对象身份写成短地址。这个 SDK 的 ObjectIdentifier 没有数值出口（intValue / uintValue
    /// 都还不存在），只能从它那句 「ObjectIdentifier(0x…)」 里把地址抠出来。
    private static func objTag(_ obj: AnyObject?) -> String {
        guard let obj else { return "—" }
        let text = String(describing: ObjectIdentifier(obj))
        guard let at = text.firstIndex(of: "0") else { return text }
        return String(text[at...]).replacingOccurrences(of: ")", with: "")
    }

    private static func slotTag(_ unit: AVAudioUnitEffect?) -> String { objTag(unit) }

    /// 撤销栈的笔数：一次拖拽只该添一笔，落在自己那格上一笔都不该添。
    private func slotDepth(_ vm: PlayerViewModel) -> Int { vm.history.undoStack.count }

    private func slotCheck(_ step: String, _ ok: Bool, _ detail: String) {
        slotNote("   \(ok ? "✓" : "✗") \(step)：\(detail)")
    }

    private func exerciseSlotOrderForCheck() {
        guard let vm = vm else { slotNote("没有 vm，跳过"); slotFinish(); return }
        slotAwait("音轨就绪", remaining: 2_400) { vm.loadPending == 0 } then: {
            guard let delay = PluginCatalog.effects().first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                                    && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
                self.slotNote("本机 plist 里没有 Apple AUDelay，跳过"); self.slotFinish(); return
            }
            vm.stopPlayback()
            vm.setEditMode(true)
            // 上一支探针或恢复的工程可能留着东西：先清干净，格子序号才有意义。
            for side in [TrackSide.a, .b] {
                for i in 0..<AudioEngine.slotCount where vm.slots(side)[i].plugin != nil {
                    vm.unloadSlot(i, for: side)
                }
            }
            self.slotNote("清场: \(self.slotSummary(vm)) · 历史 \(self.slotDepth(vm)) 笔")
            vm.loadPlugin(delay, at: 0, for: .a)
            self.slotAwait("槽1 装上甲", { vm.slots(.a)[0].plugin != nil }) {
                guard let u0 = AudioEngine.shared.unit(.a, at: 0) else {
                    self.slotNote("拿不到槽1 的 unit，跳过"); self.slotFinish(); return
                }
                Self.slotSetDelay(.a, 0, to: 0.25)
                vm.loadPlugin(delay, at: 1, for: .a)
                self.slotAwait("槽2 装上乙", { vm.slots(.a)[1].plugin != nil }) {
                    guard let u1 = AudioEngine.shared.unit(.a, at: 1) else {
                        self.slotNote("拿不到槽2 的 unit，跳过"); self.slotFinish(); return
                    }
                    Self.slotSetDelay(.a, 1, to: 0.60)
                    vm.toggleSlotBypass(1, for: .a)   // 乙带着「已旁通」上路，调序该把它一起搬走
                    self.slotNote("摆好: \(self.slotSummary(vm)) · 甲=\(Self.slotTag(u0)) 0.25s "
                                  + "乙=\(Self.slotTag(u1)) 0.60s（旁通中）· 历史 \(self.slotDepth(vm)) 笔")
                    self.slotStep1Move(vm, u0: u0, depth0: self.slotDepth(vm))
                }
            }
        }
    }

    /// ① 同轨·拖到空格 = 移动：原格留空洞，实例一颗都不换。
    private func slotStep1Move(_ vm: PlayerViewModel, u0: AVAudioUnitEffect, depth0: Int) {
        // 计时包在 applySlotDrag 外面：这一句在主线程压了多少毫秒，就是松手后系统那张
        // 拖拽药丸还要在原地挂多久（perform 不返回，AppKit 没空撕 preview）。
        slotTimed("① 同轨移动") {
            vm.applySlotDrag(from: SlotTarget(side: .a, index: 0), to: SlotTarget(side: .a, index: 3), copy: false)
        }
        slotAwait("① 槽1→槽4") { vm.slots(.a)[0].plugin == nil && vm.slots(.a)[3].plugin != nil } then: {
            let same = AudioEngine.shared.unit(.a, at: 3) === u0
            self.slotCheck("拖到空格＝移动", same && vm.slots(.a)[0].plugin == nil
                                    && Self.delayNear(.a, 3, 0.25) && !vm.slots(.a)[3].bypass,
                           "槽4=\(Self.slotMark(.a, 3, vm)) 槽1=\(Self.slotMark(.a, 0, vm)) · \(self.slotSummary(vm))")
            self.slotCheck("同轨不换实例", same,
                           "槽4 unit=\(Self.slotTag(AudioEngine.shared.unit(.a, at: 3))) 甲=\(Self.slotTag(u0))")
            self.slotCheck("一笔历史", self.slotDepth(vm) == depth0 + 1, "\(depth0) → \(self.slotDepth(vm)) 笔")
            self.slotStep2Windows(vm, depth1: self.slotDepth(vm))
        }
    }

    /// ② 浮窗跟着格子走：窗口认的是实例，格子号换了标题就得跟着换，原点那格不该还剩窗。
    private func slotStep2Windows(_ vm: PlayerViewModel, depth1: Int) {
        let ed = PluginEditorController.shared
        let w甲 = ed.window(for: .a, 3)
        let w乙 = ed.window(for: .a, 1)
        self.slotCheck("甲的窗挪到了槽4", (w甲?.title.contains("A · 4") ?? false) && ed.isShowing(.a, index: 3),
                       "title=「\(w甲?.title ?? "无")」")
        self.slotCheck("乙的窗还在槽2", (w乙?.title.contains("A · 2") ?? false) && ed.isShowing(.a, index: 1),
                       "title=「\(w乙?.title ?? "无")」")
        self.slotCheck("原点不留窗", ed.window(for: .a, 0) == nil,
                       "槽1 的窗=\(ed.window(for: .a, 0) != nil ? "还在" : "没有")")
        self.slotStep3Exchange(vm, w甲: w甲, w乙: w乙, depth1: depth1)
    }

    /// ③ 同轨·拖到已用格 = 调换：两格连 bypass 一起对调，实例还是那两颗。
    private func slotStep3Exchange(_ vm: PlayerViewModel, w甲: NSWindow?, w乙: NSWindow?, depth1: Int) {
        slotTimed("③ 同轨调换（同步重接整条链）") {
            vm.applySlotDrag(from: SlotTarget(side: .a, index: 1), to: SlotTarget(side: .a, index: 3), copy: false)
        }
        slotAwait("③ 槽2⇄槽4") { Self.delayNear(.a, 1, 0.25) && Self.delayNear(.a, 3, 0.60) } then: {
            self.slotCheck("拖到已用格＝调换", !vm.slots(.a)[1].bypass && vm.slots(.a)[3].bypass,
                           "槽2=\(Self.slotMark(.a, 1, vm))（该 0.25s 不旁）· 槽4=\(Self.slotMark(.a, 3, vm))（该 0.60s 旁通）· \(self.slotSummary(vm))")
            let w2 = PluginEditorController.shared.window(for: .a, 1)
            let w4 = PluginEditorController.shared.window(for: .a, 3)
            self.slotCheck("两扇窗跟着对调", w2 === w甲 && w4 === w乙
                                    && (w2?.title.contains("A · 2") ?? false)
                                    && (w4?.title.contains("A · 4") ?? false),
                           "槽2 的窗=\(Self.objTag(w2))「\(w2?.title ?? "无")」· 槽4 的窗=\(Self.objTag(w4))「\(w4?.title ?? "无")」")
            self.slotCheck("调换也是一笔历史", self.slotDepth(vm) == depth1 + 1, "\(depth1) → \(self.slotDepth(vm)) 笔")
            self.slotStep4Copy(vm, depth2: self.slotDepth(vm))
        }
    }

    /// ④ ⌥ 拖到空格 = 复制：源格原样留着，落点是另一颗实例，各调各的旋钮。
    private func slotStep4Copy(_ vm: PlayerViewModel, depth2: Int) {
        slotTimed("④ ⌥ 复制到空格（装载是异步的）") {
            vm.applySlotDrag(from: SlotTarget(side: .a, index: 1), to: SlotTarget(side: .a, index: 0), copy: true)
        }
        slotAwait("④ ⌥ 槽2→槽1") { vm.slots(.a)[0].plugin != nil && !vm.slots(.a)[0].loading } then: {
            let u0 = AudioEngine.shared.unit(.a, at: 0)
            let u1 = AudioEngine.shared.unit(.a, at: 1)
            let distinct = u0 != nil && u1 != nil && u0 !== u1
            self.slotCheck("⌥ 复制＝两边都在", distinct && Self.delayNear(.a, 0, 0.25) && Self.delayNear(.a, 1, 0.25),
                           "槽1=\(Self.slotMark(.a, 0, vm)) 槽2=\(Self.slotMark(.a, 1, vm)) · \(self.slotSummary(vm))")
            self.slotCheck("复制出来的是新实例", distinct, "槽1=\(Self.slotTag(u0)) 槽2=\(Self.slotTag(u1))")
            Self.slotSetDelay(.a, 0, to: 0.35)
            self.slotCheck("两颗各自可调", Self.delayNear(.a, 0, 0.35) && Self.delayNear(.a, 1, 0.25),
                           "把槽1 改成 0.35s 之后：槽1=\(Self.slotDelayText(.a, 0)) 槽2=\(Self.slotDelayText(.a, 1))")
            self.slotCheck("复制也是一笔历史", self.slotDepth(vm) == depth2 + 1, "\(depth2) → \(self.slotDepth(vm)) 笔")
            self.slotStep5CopyHistory(vm)
        }
    }

    /// ⑤ 撤销/重做这一笔复制。一轨两格同款插件是这条路子里最容易塌的一环 ——
    /// restoreSlots 原先按 id 复用 unit，同名两格会抢同一颗节点，接线时一个输出喂两个下游。
    private func slotStep5CopyHistory(_ vm: PlayerViewModel) {
        let depth = self.slotDepth(vm)
        vm.undoEdit()
        slotAwait("⑤ 撤销 ⌥ 复制") { vm.slots(.a)[0].plugin == nil && vm.slots(.a)[1].plugin != nil } then: {
            self.slotCheck("撤销回到复制前", vm.slots(.a)[0].plugin == nil && Self.delayNear(.a, 1, 0.25),
                           "槽1=\(Self.slotMark(.a, 0, vm)) 槽2=\(Self.slotMark(.a, 1, vm)) · \(self.slotSummary(vm))")
            vm.redoEdit()
            self.slotAwait("⑤ 重做 ⌥ 复制") { vm.slots(.a)[0].plugin != nil && !vm.slots(.a)[0].loading } then: {
                let u0 = AudioEngine.shared.unit(.a, at: 0)
                let u1 = AudioEngine.shared.unit(.a, at: 1)
                self.slotCheck("重做后两格都有、不是同一颗", u0 != nil && u1 != nil && u0 !== u1,
                               "槽1=\(Self.slotTag(u0)) 槽2=\(Self.slotTag(u1)) · \(self.slotSummary(vm))")
                self.slotCheck("参数各归各位", Self.delayNear(.a, 0, 0.35) && Self.delayNear(.a, 1, 0.25),
                               "槽1=\(Self.slotDelayText(.a, 0))（该 0.35）· 槽2=\(Self.slotDelayText(.a, 1))（该 0.25）")
                self.slotCheck("撤销/重做不另计笔", self.slotDepth(vm) == depth, "还是 \(self.slotDepth(vm)) 笔")
                self.slotStep6Overwrite(vm, depth: self.slotDepth(vm))
            }
        }
    }

    /// ⑥ ⌥ 拖到已用格 = 覆盖：落点换成源格那一颗的副本，源格不动。
    private func slotStep6Overwrite(_ vm: PlayerViewModel, depth: Int) {
        let 覆盖前 = AudioEngine.shared.unit(.a, at: 0)
        slotTimed("⑥ ⌥ 盖在已用格上") {
            vm.applySlotDrag(from: SlotTarget(side: .a, index: 1), to: SlotTarget(side: .a, index: 0), copy: true)
        }
        slotAwait("⑥ ⌥ 盖在已用格上") { Self.delayNear(.a, 0, 0.25) && !vm.slots(.a)[0].loading } then: {
            let 换人 = AudioEngine.shared.unit(.a, at: 0) !== 覆盖前
            self.slotCheck("⌥ 复制到已占用＝覆盖", 换人 && Self.delayNear(.a, 1, 0.25),
                           "槽1=\(Self.slotMark(.a, 0, vm))（该被 0.25s 那份盖掉）· 槽2=\(Self.slotMark(.a, 1, vm))（源格不动）· \(self.slotSummary(vm))")
            self.slotCheck("盖上去的是新实例", 换人,
                           "槽1 unit \(Self.slotTag(覆盖前)) → \(Self.slotTag(AudioEngine.shared.unit(.a, at: 0)))")
            self.slotCheck("覆盖算一笔", self.slotDepth(vm) == depth + 1, "\(depth) → \(self.slotDepth(vm)) 笔")
            self.slotStep7CrossLane(vm)
        }
    }

    /// ⑦ 跨轨·拖到空格 = 搬走：源格空出来，对面那一格是新实例，参数跟着 fullState 走。
    private func slotStep7CrossLane(_ vm: PlayerViewModel) {
        Self.slotSetDelay(.a, 1, to: 0.45)
        slotTimed("⑦ 跨轨搬（装载是异步的）") {
            vm.applySlotDrag(from: SlotTarget(side: .a, index: 1), to: SlotTarget(side: .b, index: 0), copy: false)
        }
        slotAwait("⑦ A槽2→B槽1") { vm.slots(.a)[1].plugin == nil && vm.slots(.b)[0].plugin != nil } then: {
            let uB = AudioEngine.shared.unit(.b, at: 0)
            self.slotCheck("跨轨搬运", AudioEngine.shared.unit(.a, at: 1) == nil
                                    && uB != nil && Self.delayNear(.b, 0, 0.45),
                           "A槽2=\(Self.slotMark(.a, 1, vm)) · B槽1=\(Self.slotMark(.b, 0, vm))（参数该是 0.45s）· \(self.slotSummary(vm))")
            self.slotCheck("对面那一格是新实例", uB !== AudioEngine.shared.unit(.a, at: 0),
                           "B槽1=\(Self.slotTag(uB)) · A槽1=\(Self.slotTag(AudioEngine.shared.unit(.a, at: 0)))")
            self.slotStep8CrossExchange(vm)
        }
    }

    /// ⑧ 跨轨·落点已占用 = 两趟装载对调：先把对面盖好，再回头填自己那格。
    private func slotStep8CrossExchange(_ vm: PlayerViewModel) {
        Self.slotSetDelay(.a, 0, to: 0.15)
        slotTimed("⑧ 跨轨调换（两趟装载）") {
            vm.applySlotDrag(from: SlotTarget(side: .a, index: 0), to: SlotTarget(side: .b, index: 0), copy: false)
        }
        slotAwait("⑧ A槽1⇄B槽1") { Self.delayNear(.a, 0, 0.45) && Self.delayNear(.b, 0, 0.15) } then: {
            let uA = AudioEngine.shared.unit(.a, at: 0)
            let uB = AudioEngine.shared.unit(.b, at: 0)
            self.slotCheck("跨轨调换", Self.delayNear(.a, 0, 0.45) && Self.delayNear(.b, 0, 0.15),
                           "A槽1=\(Self.slotMark(.a, 0, vm))（该换上 0.45s）· B槽1=\(Self.slotMark(.b, 0, vm))（该换上 0.15s）· \(self.slotSummary(vm))")
            self.slotCheck("两边都有、不是同一颗", uA != nil && uB != nil && uA !== uB,
                           "A槽1=\(Self.slotTag(uA)) B槽1=\(Self.slotTag(uB))")
            self.slotStep9Noop(vm)
        }
    }

    /// ⑨ 落在自己那一格：链子不动，历史也不该多一笔。顺手再拖一次到最后一格。
    private func slotStep9Noop(_ vm: PlayerViewModel) {
        let before = self.slotSummary(vm)
        let depth = self.slotDepth(vm)
        vm.applySlotDrag(from: SlotTarget(side: .a, index: 0), to: SlotTarget(side: .a, index: 0), copy: false)
        self.slotCheck("拖回本格＝什么也不做", self.slotSummary(vm) == before && self.slotDepth(vm) == depth,
                       "现场没变=\(self.slotSummary(vm) == before) · 历史 \(depth) → \(self.slotDepth(vm)) 笔")
        vm.applySlotDrag(from: SlotTarget(side: .a, index: 0), to: SlotTarget(side: .a, index: 5), copy: false)
        slotAwait("⑨ 槽1→槽6") { vm.slots(.a)[5].plugin != nil } then: {
            self.slotCheck("拖到最后一格也认", Self.delayNear(.a, 5, 0.45), "槽6=\(Self.slotMark(.a, 5, vm))")
            self.slotStep10GesturePlumbing(vm)
        }
    }

    /// ⑩ 拖拽那一段的记账：粘贴板写的是什么、⌥ 怎么认、半途取消谁清账。
    private func slotStep10GesturePlumbing(_ vm: PlayerViewModel) {
        let ref = SlotTarget(side: .a, index: 2)
        self.slotNote("   粘贴板凭据：SlotDrag.payload(A槽3) = \"\(SlotDrag.payload(ref))\"")
        let 不按 = SlotDrag.isCopy([])
        let 按option = SlotDrag.isCopy([.option])
        SlotDrag.debugForceCopy = true
        let 探针强制 = SlotDrag.isCopy([])
        SlotDrag.debugForceCopy = false
        self.slotCheck("⌥ 判定", !不按 && 按option && 探针强制,
                       "不按=\(不按) 按⌥=\(按option) 探针强制=\(探针强制)"
                       + "（探针那枚只在这台机器的 Debug 里有，Release 连开关都不带）")
        let drag = SlotDrag.shared
        drag.begin(ref)
        drag.hovering = SlotTarget(side: .b, index: 4)
        let 起来了 = drag.source == ref && drag.hovering == SlotTarget(side: .b, index: 4)
        let 记着的 = drag.source?.id ?? "nil"
        drag.expireIfIdle()          // 此刻没按左键 → 判为半途取消，账要清掉
        let 清了 = drag.source == nil && drag.hovering == nil
        drag.begin(ref)
        drag.end()
        self.slotCheck("起飞与清账", 起来了 && 清了,
                       "begin 之后 source=\(记着的)（起飞记账=\(起来了 ? "成" : "没成")）"
                       + "· 没按左键时 expireIfIdle 之后=\(清了 ? "清干净" : "还挂着")"
                       + "· end 之后=\(drag.source == nil ? "清干净" : "还挂着")")
        self.slotStep11OutputCheck(vm)
    }

    /// ⑪ 链子内伤没有：此刻 A 轨上串着两颗同款 AUDelay（⌥ 复制留下的那副样子），
    /// 正是 restoreSlots 按 id 复用最容易塌的一环 —— 一个输出喂两个下游。
    /// 参数值对不对前面已逐格读过，这一节只看输出连不连续、有没有声。
    private func slotStep11OutputCheck(_ vm: PlayerViewModel) {
        if vm.slots(.a)[3].bypass { vm.toggleSlotBypass(3, for: .a) }
        let cap = auCapture("A 轨串着两枚同款")
        let rate = Int(AudioEngine.shared.debugConnectionRate)
        let 中段 = cap.frameCount / 4
        let 长度 = min(cap.frameCount / 2, 20_000)
        let 电平 = 长度 > 0 ? statsForCheck(cap, start: 中段, count: 长度) : (-99.0, -99.0)
        slotCheck("链子连续有声", cap.gaps == 0 && cap.frameCount > 0 && 电平.0 > -60,
                  "frames=\(cap.frameCount) cb=\(cap.callbacks) gaps=\(cap.gaps) · 链路 \(rate) Hz · "
                  + "峰值 \(String(format: "%.1f", 电平.0)) dB · RMS \(String(format: "%.1f", 电平.1)) dB")
        vm.pause()
        slotStep12Report(vm)
    }

    /// ⑫ 收尾：链子的先后就是数组的先后，报一遍此刻谁在哪一格。
    private func slotStep12Report(_ vm: PlayerViewModel) {
        func filled(_ side: TrackSide) -> String {
            (0..<AudioEngine.slotCount).compactMap { i in
                AudioEngine.shared.unit(side, at: i) != nil ? String(i + 1) : nil
            }.joined(separator: ",")
        }
        let 还在装 = vm.slots(.a).contains { $0.loading } || vm.slots(.b).contains { $0.loading }
        self.slotNote("⑫ 现场: \(self.slotSummary(vm)) · 还在装的格子=\(还在装 ? "有" : "没有") · 历史 \(self.slotDepth(vm)) 笔")
        self.slotNote("   链上有插件的格号：A=\(filled(.a)) B=\(filled(.b)) · 浮窗开着 \(PluginEditorController.shared.openCount) 扇")
        self.slotNote("⑬ 手势那一层要真人验：混音器里按住一格拖到别格（描圈那格是落点）＝调换或移动；"
                      + "按住 ⌥ 松手＝复制，落点已占用就盖掉它。这两条探针走不了（拖不进去、⌥ 注不进来）。")
        slotFinish()
    }

    // MARK: 推子 ⌃+滚轮探针（AB_FADER_CHECK）
    //
    // 滚轮事件在这台机器上注入不了（CGEventPost 发 mouseMoved/scrollWheel 实测被静默丢掉），
    // 但三枚推子的微调只看「哪种指针」和 modifierFlags，所以直接在视图上喊一次
    // scrollWheel(with:) 就能把账量出来：没按 ⌃ 该放行、按 ⌃ 走 0.5 dB、顶到底不再涨。
    // 之后这条要跑两遍：鼠标和触控板各自的「往上」都得让增益加，
    // 差别只在事件怎么造 —— 鼠标是 +1 格（.line），触控板是手指上推 = 负的像素增量（.pixel）。
    private func exerciseFaderScrollForCheck() {
        var lines: [String] = []
        // AppKit 没有造滚轮事件的工厂（`NSEvent.scrollWheelEvent` 在这个 SDK 里不存在），
        // 所以走 CoreGraphics 那一层：先造一条 CG 滚轮事件，再翻成 NSEvent。
        func ev(_ mods: NSEvent.ModifierFlags, _ dy: Int32, _ units: CGScrollEventUnit) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units,
                                   wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
            cg.flags = CGEventFlags(rawValue: UInt64(mods.rawValue))
            return NSEvent(cgEvent: cg)
        }
        let 输入方式: [(tag: String, units: CGScrollEventUnit, 上: Int32, 下: Int32, 认成: PointerInput)] = [
            ("鼠标", .line, 1, -1, .mouse),
            ("触控板", .pixel, -1, 1, .trackpad),
        ]
        for kind in 输入方式 {
            guard let 未按 = ev([], kind.上, kind.units),
                  let 上滚 = ev([.control], kind.上, kind.units),
                  let 下滚 = ev([.control], kind.下, kind.units) else {
                writeDiag("FADER: 合成不出滚轮事件\n", suffix: ".fader"); return
            }
            // 先验尺子：这台机器造出来的事件到底被 AppKit 认成哪种指针。认错了下面全不算。
            let 认出 = PointerInput.detect(上滚)
            lines.append("\(kind.tag)：事件认成 \(认出 == kind.认成 ? kind.tag : "✗ \(认出)")")
            // 三枚推子各跑一遍：全局增益、声道推子、混音器 pre-gain。
            func check(_ tag: String, _ make: () -> NSView,
                       _ arm: (NSView, @escaping (Double) -> Void) -> Void,
                       _ set: (NSView, Double) -> Void,
                       _ scroll: (NSView, NSEvent) -> Void, 顶: Double) {
                var got: [Double] = []
                let v = make()
                arm(v) { got.append($0) }
                set(v, -3)
                scroll(v, 未按)
                let 放行 = got.isEmpty
                scroll(v, 上滚)
                scroll(v, 下滚)
                set(v, 顶)
                scroll(v, 上滚)
                let 读数 = got.map { String(format: "%.1f", $0) }.joined(separator: ",")
                // 期望：没按 ⌃ 一颗都不报；往上 -2.5、往下 -3.5；顶到头再往上仍是顶。
                let 对 = 放行 && got == [-2.5, -3.5, 顶]
                lines.append("   \(tag) · 未按⌃放行=\(放行) · 回报=\(读数) · 判定=\(对 ? "对" : "错")")
            }
            check("全局推子", { GainFaderNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 20)) },
                  { ($0 as? GainFaderNSView)?.onDrag = $1 },
                  { ($0 as? GainFaderNSView)?.db = $1 },
                  { ($0 as? GainFaderNSView)?.scrollWheel(with: $1) }, 顶: GainFaderScale.maxDB)
            check("声道推子", { VerticalFaderNSView(frame: NSRect(x: 0, y: 0, width: 20, height: 120)) },
                  { ($0 as? VerticalFaderNSView)?.onDrag = $1 },
                  { ($0 as? VerticalFaderNSView)?.db = $1 },
                  { ($0 as? VerticalFaderNSView)?.scrollWheel(with: $1) }, 顶: GainFaderScale.maxDB)
            check("pre-gain", { PreGainNSView(frame: NSRect(x: 0, y: 0, width: 48, height: 16)) },
                  { ($0 as? PreGainNSView)?.onSet = $1 },
                  { ($0 as? PreGainNSView)?.db = $1 },
                  { ($0 as? PreGainNSView)?.scrollWheel(with: $1) }, 顶: 0)
        }
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".fader")
        FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    // MARK: 波形图指针探针（AB_POINTER_CHECK）
    //
    // 那几条里能拿数字说话的都在 `WaveformNSView.scrollWheel`：触控板双指
    // 左右要跟着手指走、触控板的竖向滚动不许再翻页面（那一条留给鼠标）、⌥⌘ 与 ⌘ 那两档
    // 在两种指针下都得「往上 = 加」。捏合那一档不在这里 —— 它走识别器，只能真人两根手指。
    // 事件仍从 CG 那层造：`.pixel` = 精确增量 = 触控板，`.line` = 一格 = 鼠标滚轮。
    private func exercisePointerWaveformForCheck() {
        var lines: [String] = []
        func ev(_ mods: NSEvent.ModifierFlags, _ dy: Int32, _ dx: Int32,
                _ units: CGScrollEventUnit) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units,
                                   wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
            cg.flags = CGEventFlags(rawValue: UInt64(mods.rawValue))
            return NSEvent(cgEvent: cg)
        }
        // 每条都从同一副视野起量：4× 缩放、宽 400 px，起点 start=0.375（一像素 = 1/(4×400)）。
        var view = WaveformNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        var reportedFloor = Double.nan
        func resetStage() {
            view = WaveformNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
            view.floorDB = -30
            reportedFloor = .nan
            view.onFloorChange = { reportedFloor = $0 }
            view.setZoom(target: 4, anchor: nil)
            view.debugSnapToTarget()
        }
        func note(_ tag: String, _ delta: Double, _ want: (Double) -> Bool) {
            lines.append("\(tag)：Δ=\(String(format: "%+.4f", delta)) · 判定=\(want(delta) ? "对" : "错")")
        }

        // 1 双指右移 40 px：画面跟着手指往右，视野就该往前（start 变小 0.025）。
        resetStage()
        view.scrollWheel(with: ev([], 0, 40, .pixel)!)
        note("触控板 双指右移40px", Double(view.debugStartRatio) - 0.375) { $0 < -0.02 }
        // 2 双指左移 40 px：反着来。
        resetStage()
        view.scrollWheel(with: ev([], 0, -40, .pixel)!)
        note("触控板 双指左移40px", Double(view.debugStartRatio) - 0.375) { $0 > 0.02 }
        // 3 双指竖着推 20 px：这一条必须「不动」。以前鼠标滚轮那档翻页要认得出是鼠标，
        // 不然触控板竖向一推就把画面弹走（规格要禁的就是这个）。
        resetStage()
        view.scrollWheel(with: ev([], -20, 0, .pixel)!)
        note("触控板 竖推20px(该禁)", Double(view.debugStartRatio) - 0.375) { abs($0) < 0.0001 }
        // 4 鼠标滚轮往上 1 格：翻页照旧，一格 = 1/(4×4) = 0.0625。
        resetStage()
        view.scrollWheel(with: ev([], 1, 0, .line)!)
        note("鼠标 滚轮上1格(翻页)", Double(view.debugTargetStartRatio) - 0.375) { $0 > 0.05 }
        // 5 / 6 ⌥⌘：两种指针各自的「往上」都该把缩放加大 0.2（log2 轴）。
        func zoomDelta(_ units: CGScrollEventUnit, _ dy: Int32) -> Double {
            resetStage()
            let before = view.debugTargetZoomLog
            view.scrollWheel(with: ev([.option, .command], dy, 0, units)!)
            return view.debugTargetZoomLog - before
        }
        let 缩放鼠标 = zoomDelta(.line, 1), 缩放触控 = zoomDelta(.pixel, -20)
        lines.append("⌥⌘ 缩放：鼠标上1格 Δlog=\(String(format: "%+.2f", 缩放鼠标))"
            + " 触控板上推20px Δlog=\(String(format: "%+.2f", 缩放触控))"
            + " · 判定=\(缩放鼠标 > 0.1 && 缩放触控 > 0.1 ? "对" : "错")")
        // 7 ⌘：动态深度同一把尺，两种指针的「往上」都该往更深走（-30 → -34.5）。
        func floorDelta(_ units: CGScrollEventUnit, _ dy: Int32) -> Double {
            resetStage()
            view.scrollWheel(with: ev([.command], dy, 0, units)!)
            return reportedFloor
        }
        let 深度鼠标 = floorDelta(.line, 1), 深度触控 = floorDelta(.pixel, -20)
        lines.append("⌘ 深度：鼠标上1格 → \(String(format: "%.1f", 深度鼠标))dB"
            + " 触控板上推 → \(String(format: "%.1f", 深度触控))dB"
            + " · 判定=\(深度鼠标 < -30 && 深度触控 < -30 ? "对" : "错")")

        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".pointer")
        FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    // MARK: 橡皮擦指针探针（AB_ERASER_CHECK）
    //
    // 「⌘+点能擦，指针却不出现」这句话里能拿数字说话的只有三段：格子在不在册、它的矩形
    // 有没有面积、矩形盖不盖得住鼠标，外加 AppKit 到底重算过几次矩形表。指针本身拍不进
    // 窗口截图，只有 `screencapture -x -C` 那张全屏图里有，所以这支探针把鼠标挪到 A 格 1
    // 正中（CGWarp 不算合成事件，本机没辅助功能权限也能挪），再把目标坐标和主屏缩放一起
    // 抄出来，外面照着裁一小块就能对上眼。
    // 前半段仍用「强制上膛」绕开 ⌘ 检测，验的是这颗自定义光标摆不摆得上屏；判定区建起来
    // 之后，后半段改用注入的事件自带 ⌘（判位置也看事件自己那份），四条相位把用户报的两条
    // 毛病正对着打 —— ⌘ 认不认得出这一环不再只能靠真人按一下。
    private func exerciseEraserCursorForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                eraserNote("ERASER: 音轨未在 60s 内就绪，跳过"); eraserFlush(); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseEraserCursorForCheck(remaining: remaining - 1)
            }
            return
        }
        eraserLines = []
        SlotCursors.debugForceEraser = true
        // 带 AB_ERASER_STOCK 时把橡皮擦换成系统十字：屏幕上出现了十字，就说明矩形和
        // set() 这条路是通的，问题在自定义光标那张图本身；还是箭头，问题在传递路径。
        SlotCursors.debugStockCursor =
            ProcessInfo.processInfo.environment["AB_ERASER_STOCK"] != nil
        vm.setEditMode(true)
        MixerPanelController.shared.open(vm: vm)
        let catalog = PluginCatalog.effects()
        guard let delay = catalog.first(where: { $0.subtype == PluginCatalog.fourCC("dely")
                                                && $0.manufacturer == PluginCatalog.fourCC("appl") }) else {
            eraserNote("ERASER: 本机 plist 里没有 Apple AUDelay，跳过"); eraserFlush(); return
        }
        // 从上一次运行留下来的槽位里带着插件是常事（状态是持久化的），而 loadPlugin
        // 对「已经有插件的格子」直接不干活 —— 那一等就是 60s 空转到超时。已经装好就作罢。
        let begin: (Bool) -> Void = { loaded in
            self.eraserNote("ERASER: 装上 A格1=\(loaded) · \(EraserCursor.debugValueImageInfo())")
            self.eraserNote("开局 · " + self.eraserFlat(SlotCursors.debugSample()))
            // 矩形表要等 AppKit 下一次更新才重算，先自己点一次名，半秒后再抄表。
            SlotCursors.refreshAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.eraserWarpForCheck() }
        }
        if vm.slots(.a)[0].plugin != nil {
            eraserNote("ERASER: A格1 本来就有 \(vm.slots(.a)[0].plugin?.name ?? "?")，直接复用")
            begin(true)
            return
        }
        vm.loadPlugin(delay, at: 0, for: .a)
        awaitForCheck("A格1 装上", remaining: 600, { vm.slots(.a)[0].plugin != nil }) { begin($0) }
    }

    /// CGWarp 吃的坐标和 AppKit 相反：它按主屏**左上**为原点，AppKit 处处是左下。
    /// 第一版直接把 AppKit 的 812 递过去，指针落成了 `NSEvent.mouseLocation` 的 268
    /// （1080−812），每一格都报「盖住鼠标=false」，看着像矩形没登记，其实是鼠标挪错了地方。
    private func cgWarpPointForCheck(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? point.y) - point.y)
    }

    /// 停在原地的鼠标不会产生任何事件，矩形表也就一直是开窗口那一刻算的旧账；
    /// 挪过去才有真正的 mouseMoved，那才是用户「把鼠标移到格子上」那一刻走的路。
    private func eraserWarpForCheck() {
        guard let center = SlotCursors.debugAimedCenter() else {
            eraserNote("挪鼠标: 没有一格拿得出中心（矩形压根没面积，这就是答案）")
            eraserFlush(); return
        }
        let before = NSEvent.mouseLocation
        let screen = NSScreen.main
        let warp = cgWarpPointForCheck(center)
        eraserNote("挪鼠标: 目标(左下)=\(Int(center.x)),\(Int(center.y)) → CG(左上)=\(Int(warp.x)),\(Int(warp.y)) · "
            + "起点=\(Int(before.x)),\(Int(before.y)) · "
            + "主屏=\(screen.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) 缩放\($0.backingScaleFactor)" } ?? "-")")
        CGWarpMouseCursorPosition(warp)
        CGAssociateMouseAndMouseCursorPosition(1)   // 别把物理鼠标钉在落点上

        // 相位按表推进。上一版是七层 asyncAfter 套出来的，改一步要数半天括号。
        eraserDeadline = DispatchTime.now() + 3     // 头一相之前停三秒，给外面截带指针的屏
        eraserPhase(after: 0) {
            self.eraserNote("挪好之后（非 key） · " + self.eraserFlat(SlotCursors.debugSample()))
        }
        eraserPhase(after: 4) { self.eraserMakeKeyAndRestack(center: center) }
        eraserPhase(after: 2) {
            self.eraserNote("设成 key 之后 · " + self.eraserFlat(SlotCursors.debugSample()))
        }
        // 强制上膛的三相验的是「这颗光标摆不摆得上屏」：⌘ 检测被绕开，链路其余部分照走。
        eraserPhase(after: 3) {
            SlotCursors.refreshAll()
            self.eraserNote("手动 set 之后 · " + self.eraserFlat(SlotCursors.debugSample()))
        }
        eraserPhase(after: 1.2) {
            // 上一相里「收尾」时 current 已经不是橡皮擦了，也就是说有人在我们 set() 之后
            // 把指针摆了回去。这一拍就是来抓现行的。
            self.eraserNote("set 之后 1.2 秒 · " + self.eraserFlat(SlotCursors.debugSample()))
        }
        eraserPhase(after: 0.5) {
            // 摘掉强制上膛：后面四相全走真链路 —— 注入的事件自带 ⌘，判定区读的就是那一份。
            SlotCursors.debugForceEraser = false
            SlotCursors.refreshAll()
            self.eraserNote("摘掉强制后（不注入） · " + self.eraserFlat(SlotCursors.debugSample()))
        }
        // 用户报的两条毛病，各有一相正对着打。每一相里先挪指针、0.6 秒后再按 ⌘（用户的
        // 手序），再等 1.4 秒抄一次表并让外面截那张带指针的屏（`@屏`）：实测 AppKit 会在
        // 我们 set() 之后约 1.2 秒按它自己那张矩形表把指针摆回去，立刻截只能看到刚摆下去的
        // 那一颗，看不出守不守得住。
        // 这四相里 ⌘ 由注入的事件自带（判定读那一份），矩形表却只认全局修饰键 —— 本机
        // 伪造不了，所以另开 debugForceRects 替用户把这一环补上，两件事各管各的。
        eraserPhase(after: 1.5) {
            SlotCursors.debugForceRects = true
            SlotCursors.refreshAll()
            self.eraserInjectForCheck(commandDown: true, occupied: true, marker: "ERASER_ARMED")
        }
        // ① 在有插件的格上按 ⌘ 并移过去 → 该上膛（旧 bug：先前在空槽按的 ⌘，这一相永远不来）
        eraserPhase(after: 2.0) { self.eraserNote("ERASER_ARMED@屏 · " + self.eraserFlat(SlotCursors.debugSample())) }
        eraserPhase(after: 0.05) { self.eraserInjectForCheck(commandDown: true, occupied: false, marker: "ERASER_EMPTY") }
        // ② ⌘ 不松、挪进空槽 → 该收回箭头（旧 bug：橡皮擦粘在空槽上不走）
        eraserPhase(after: 2.0) { self.eraserNote("ERASER_EMPTY@屏 · " + self.eraserFlat(SlotCursors.debugSample())) }
        eraserPhase(after: 0.05) { self.eraserInjectForCheck(commandDown: true, occupied: true, marker: "ERASER_REARMED") }
        // ③ ⌘ 仍不松、挪回有插件的格 → 该再上膛（判定区不记状态，来回都算得对）
        eraserPhase(after: 2.0) { self.eraserNote("ERASER_REARMED@屏 · " + self.eraserFlat(SlotCursors.debugSample())) }
        eraserPhase(after: 0.05) {
            // ④ ⌘ 松开、同一点 → 对照组，该是箭头：证明橡皮擦真是 ⌘ 换来的。
            // 真人松 ⌘ 时 flagsChanged 会连带把矩形表重算成没有橡皮擦，所以这一相先摘强制。
            SlotCursors.debugForceRects = false
            SlotCursors.refreshAll()
            self.eraserInjectForCheck(commandDown: false, occupied: true, marker: "ERASER_RELEASED")
        }
        eraserPhase(after: 2.0) { self.eraserNote("ERASER_RELEASED@屏 · " + self.eraserFlat(SlotCursors.debugSample())) }
        // 最后一相：把指针钉在有插件的格子上、强制上膛，连着四秒不动，让外面连拍十张。
        // 「这颗橡皮擦到底摆不摆得上屏」在本机只有这一种测法（没有真鼠标、也没有真 ⌘），
        // 而前几轮的截图时好时坏 —— 一次一张说不清是 AppKit 摆回去了还是抓取漏了那一帧。
        eraserPhase(after: 0.5) {
            SlotCursors.debugForceEraser = true
            SlotCursors.debugForceRects = true
            CGWarpMouseCursorPosition(self.cgWarpPointForCheck(center))
            CGAssociateMouseAndMouseCursorPosition(1)
            SlotCursors.refreshAll()
            self.eraserNote("ERASER_HOLD 起点 · " + self.eraserFlat(SlotCursors.debugSample()))
        }
        eraserPhase(after: 4.0) { self.eraserNote("ERASER_HOLD@屏 · " + self.eraserFlat(SlotCursors.debugSample())) }
        eraserPhase(after: 0.6) {
            self.eraserNote("注入相位判读: ①③ 该是 判定=橡皮擦 + 登进表>0 + 屏幕上此刻=橡皮擦（@屏 那张图里该是橡皮擦，"
                + "顶点正落在鼠标那一点）；② 该是 判定=无（刚从橡皮擦收回）+ 箭头；④ 该是 判定=无 + 登进表不再涨 + 箭头。"
                + "这四相走的是判定区那条路（⌘ 看事件自带的那份、位置看事件的 locationInWindow），"
                + "所以「⌘ 认得出」这一环在进程内也测得到 —— 真人按一下仍是加验，不再是非如此不可。")
            self.eraserKeyLogCheck()
            self.eraserNote("收尾 · " + self.eraserFlat(SlotCursors.debugSample()))
            CGWarpMouseCursorPosition(self.cgWarpPointForCheck(before))
            SlotCursors.debugForceEraser = false
            SlotCursors.debugForceRects = false
            self.eraserFlush()
        }
    }

    /// AB_KEYLOG 的自检：这台机器注不进真按键，所以这条只能验「写盘这条路走不走得通」——
    /// 用 NSApp.sendEvent 投一枚没有绑定的 F5（keyCode 96）走监听闭包，日志里该多出一行。
    /// 真按键那四个字段记不记原样，仍由用户按一遍、回来看 `<base>.keylog` 定案。
    private func eraserKeyLogCheck() {
        let when = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: [], timestamp: when,
                                          windowNumber: MixerPanelController.shared.panel?.windowNumber ?? 0,
                                          context: nil, characters: "\u{F500}",
                                          charactersIgnoringModifiers: "\u{F704}",
                                          isARepeat: false, keyCode: 96) else {
            eraserNote("KEYLOG: 造不出 F5 事件，自检跳过"); return
        }
        NSApp.sendEvent(down)
        let path = (ProcessInfo.processInfo.environment["AB_KEYLOG"] ?? "") + ".keylog"
        let size = (try? Data(contentsOf: URL(fileURLWithPath: path)))?.count ?? -1
        eraserNote("KEYLOG: 投了一枚 F5 → \(path) 现有 \(size) B（−1 = 文件没建起来，开关没开或写盘失败）")
    }

    /// 下一相排在「上一相的时刻 + 这么久」：写成链，读起来就是走完一遍的时间线。
    private var eraserDeadline = DispatchTime.now()
    private func eraserPhase(after seconds: TimeInterval, action: @escaping () -> Void) {
        eraserDeadline = eraserDeadline + seconds
        DispatchQueue.main.asyncAfter(deadline: eraserDeadline, execute: action)
    }

    /// 关掉会抢键盘的浮窗，再把混音器抬成 key 窗口，并把指针抖一下（原地不动不会产生
    /// mouseMoved，矩形表也就不会重算）。
    private func eraserMakeKeyAndRestack(center: NSPoint) {
        guard let vm = vm else { return }
        if PluginEditorController.shared.isShowing(.a, index: 0) { vm.toggleSlotEditor(0, for: .a) }
        MixerPanelController.shared.panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let jiggle = cgWarpPointForCheck(NSPoint(x: center.x + 3, y: center.y))
        CGWarpMouseCursorPosition(jiggle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CGWarpMouseCursorPosition(self.cgWarpPointForCheck(center))
        }
        self.eraserNote("抬 key 之后目标=\(Int(center.x)),\(Int(center.y)) · "
            + "混音器 key=\(MixerPanelController.shared.panel?.isKeyWindow == true)")
    }

    /// 在本机派发的路径上投一条真 ⌘（keyCode 59 = 左 ⌘）和一条 mouseMoved。
    ///
    /// 为什么不走 `CGEventPost`：没有辅助功能权限时它被系统静默丢掉 —— 实测指针不动、
    /// 视图一颗也收不到，白折腾一轮。`NSApp.sendEvent` 是进程内派发，不需要任何权限，
    /// 而 ⌘ 的本地监听、矩形重算、判定区、指针上屏全在这条路上，正好是用户那一步。
    ///
    /// 判定区改完之后这一相的份量重了：⌘ 看的是事件自带的那份修饰键（进程内投得进去），
    /// 位置看的是事件的 locationInWindow（也投得进去），所以「⌘ 认得出 + 鼠标落在哪一格」
    /// 这条判断整条都测得到。唯一还得到外面验的是屏幕上真摆出了那颗指针 —— 靠 marker
    /// 让 watch3.sh 在那一刻截一张带光标的屏。
    private func eraserInjectForCheck(commandDown: Bool, occupied: Bool, marker: String) {
        guard let target = SlotCursors.debugCellTarget(occupied: occupied) else {
            eraserNote("\(marker): 找不到\(occupied ? "有插件的" : "空着的")格子，跳过这一相")
            return
        }
        // 真鼠标先挪过去，等 0.6 秒再按 ⌘ —— 用户的手序就是「指针先停在格子上，再按下 ⌘」。
        // 同一拍里既挪鼠标又发事件反而不是任何人的用法：warp 之后 AppKit 会异步按它那张
        // 矩形表重摆一次指针，落笔在我们 set() 之后（实测屏幕上仍是箭头，白测一轮）。
        CGWarpMouseCursorPosition(cgWarpPointForCheck(target.center))
        CGAssociateMouseAndMouseCursorPosition(1)
        eraserNote("\(marker) 挪鼠标 → 窗口\(target.window.windowNumber) "
            + "\(occupied ? "有插件的格" : "空槽") 屏幕(左下)=\(Int(target.center.x)),\(Int(target.center.y))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let mods: NSEvent.ModifierFlags = commandDown ? .command : []
            let when = ProcessInfo.processInfo.systemUptime
            var sent: [String] = []
            if let flags = NSEvent.keyEvent(with: .flagsChanged, location: target.point,
                                            modifierFlags: mods, timestamp: when,
                                            windowNumber: target.window.windowNumber, context: nil,
                                            characters: "", charactersIgnoringModifiers: "",
                                            isARepeat: false, keyCode: 59) {
                NSApp.sendEvent(flags)
                sent.append(commandDown ? "⌘按下" : "⌘松开")
            }
            if let move = NSEvent.mouseEvent(with: .mouseMoved, location: target.point,
                                             modifierFlags: mods, timestamp: when,
                                             windowNumber: target.window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.sendEvent(move)
                sent.append("mouseMoved")
            }
            // 鼠标真的挪过才有下一版矩形表，所以注入完立刻抄一次。
            self.eraserNote("\(marker) 注入 \(sent.joined(separator: "+")) · "
                + "窗口内=\(Int(target.point.x)),\(Int(target.point.y)) · "
                + self.eraserFlat(SlotCursors.debugSample()))
        }
    }

    /// 多行采样压成一行，日志里每一步都对得齐。
    private func eraserFlat(_ sample: String) -> String {
        sample.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    private var eraserLines: [String] = []
    /// 每一行都顺手落一次盘：这支探针要在指针停到位的那几秒里 externally 截屏，
    /// 只有边跑边写才看得出「现在到哪儿了」，不然只能等终点那一下，截早截晚全靠猜。
    private func eraserNote(_ line: String) {
        eraserLines.append(line)
        writeDiag(eraserLines.joined(separator: "\n") + "\n", suffix: ".eraser")
    }
    private func eraserFlush() { eraserNote("—— 完 ——") }

    // MARK: 探针（AB_EXPORT_CHECK）
    //
    // 渲染导出对不对，只有样本说了算：A 轨那一段渲染出来，读回文件做自相关，相关峰
    // 该落在「延迟秒数 × 采样率」那一格；把那一格旁通掉再渲染一次，峰该塌回去。
    // 裁切那条路不动样本，所以它比的是文件名和字节数。

    /// 渲染用的那一段和那颗插件：A 格 1 装 Apple AUDelay，延迟 0.25 s。
    private static let expDelaySeconds = 0.25
    private static let expRangeStart: TimeInterval = 1
    private static let expRangeEnd: TimeInterval = 5

    private func exerciseExportForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 || AudioEngine.shared.durationA <= 0 {
            guard remaining > 0 else {
                expNote("EXPORT: 音轨未在 60s 内就绪，跳过")
                expFinish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseExportForCheck(remaining: remaining - 1)
            }
            return
        }
        expNote("=== 批次⑤ 渲染导出 ===")
        // Debug 构建里放音时主线程几乎全在重画波形（实测卡在 WaveformView.swift:242
        // 那条按列扫峰的内层循环），探针的定时器被挤得走不动。这一段不需要听，先停下。
        vm.pause()
        // 1) ⌘E：热键表里 .setTrackB 是裸 e，⌘E 不该被监视器认领，得留给菜单。
        let eaten = drive(keyCode: 14, modifiers: [.command],
                          charactersIgnoringModifiers: "e", vm: vm)
        expNote("⌘E: 热键表吃掉=\(eaten)（该是 false · 交给菜单的「导出…」）")
        // 2) 菜单形状：分隔线把三组隔开。
        dumpMenusForCheck()
        expMenuState(vm: vm, label: "刚就绪")
        self.expEnterEdit(vm: vm)
    }

    /// 「导出…」这一项的实况：可不可用、键位对不对、当下有几条轨能导。
    private func expMenuState(vm: PlayerViewModel, label: String) {
        guard let item = expExportMenuItem() else {
            expNote("\(label)：主菜单里找不到 ⌘E 那一项"); return
        }
        item.menu?.update()   // 同 expMenuFire：不补这一句，读到的一直是没灌值的空壳
        expNote("\(label)：「\(item.title)」enabled=\(item.isEnabled) · 键=\(item.keyEquivalent)"
               + " 修饰=\(item.keyEquivalentModifierMask.rawValue) · 能导的轨="
               + "\(vm.exportLanes(for: .current).count) · trackA=\(vm.trackA != nil)")
    }

    private func expExportMenuItem() -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent.lowercased() == "e",
                   item.keyEquivalentModifierMask.contains(.command) { return item }
                if let sub = item.submenu, let found = search(sub) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap { search($0) }
    }

    private func expEnterEdit(vm: PlayerViewModel) {
        vm.setEditMode(true)
        awaitForCheck("进编辑模式", { vm.editMode }) { settled in
            guard settled else {
                self.expNote("没进得了编辑模式，跳过")
                self.expFinish()
                return
            }
            self.expLoadDelay(vm: vm)
        }
    }

    /// 3) 装 AUDelay 并把延迟写成 0.25 s，然后框出要渲染的那一段。
    private func expLoadDelay(vm: PlayerViewModel) {
        let delay = PluginCatalog.effects().first { $0.subtype == PluginCatalog.fourCC("dely")
                                                    && $0.manufacturer == PluginCatalog.fourCC("appl") }
        guard let delay else {
            expNote("本机没有 Apple AUDelay，跳过")
            expFinish()
            return
        }
        vm.loadPlugin(delay, at: 0, for: .a)
        awaitForCheck("装载 AUDelay", { vm.slots(.a)[0].plugin != nil }) { loaded in
            guard loaded else {
                self.expNote("插件没装上，跳过（轨迹=\(AudioEngine.shared.debugSlotTrace)）")
                self.expFinish()
                return
            }
            if let unit = AudioEngine.shared.unit(.a, at: 0),
               let time = unit.auAudioUnit.parameterTree?.allParameters.first(where: {
                    $0.displayName.contains("延迟") || $0.displayName.lowercased().contains("delay") }) {
                time.value = Float(Self.expDelaySeconds)
                self.expNote("A 格 1 AUDelay · 「\(time.displayName)」写成 "
                             + "\(Self.expDelaySeconds) → 读回 \(time.value)")
            } else {
                self.expNote("找不到延迟参数，渲染出来的峰无从比对")
            }
            vm.rangeA = ABRange(start: Self.expRangeStart, end: Self.expRangeEnd)
            // B 轨也框一段：不框的话「全部」那一路就是整首 246 s，渲染和读回都白等几分钟。
            vm.rangeB = ABRange(start: Self.expRangeStart, end: Self.expRangeEnd)
            self.expResetDirectory()
            self.expRenderWithFX(vm: vm)
        }
    }

    private func expResetDirectory() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.expDirectory.path) {
            try? fm.removeItem(at: Self.expDirectory)
        }
        try? fm.createDirectory(at: Self.expDirectory, withIntermediateDirectories: true)
    }

    private static var expDirectory: URL {
        URL(fileURLWithPath: "/tmp/abexport", isDirectory: true)
    }

    /// 4) 带插件渲染一次（24 bit），读回文件做自相关。
    private func expRenderWithFX(vm: PlayerViewModel) {
        let requests = vm.renderRequests(for: .current, typedName: "probe",
                                        bitDepth: .s24, directory: Self.expDirectory)
        expNote("渲染任务: \(requests.count) 个 · 名字=\(requests.first?.outputURL.lastPathComponent ?? "-")")
        guard let first = requests.first else { expNote("任务表是空的"); expFinish(); return }
        expNote("定格: 范围=\(String(format: "%.2f", first.start))–\(String(format: "%.2f", first.end))s "
               + "pre=\(String(format: "%.1f", first.preGainDB))dB 推子=\(String(format: "%.1f", first.faderDB))dB "
               + "声像=\(first.panTicks) 链=\(first.slots.compactMap { $0 }.count) 格 旁通=\(first.laneBypass)")
        expRun(requests, label: "渲染 24bit（插件通）") {
            // 5) 同一格旁通掉再渲染：32 bit float，峰该塌回干信号那一档。
            vm.toggleSlotBypass(0, for: .a)
            let bypassed = vm.renderRequests(for: .current, typedName: "probe_off",
                                             bitDepth: .f32, directory: Self.expDirectory)
            self.expRun(bypassed, label: "渲染 32float（单格旁通）") {
                vm.toggleSlotBypass(0, for: .a)
                self.expRenderMusicEffect(vm: vm)
            }
        }
    }

    /// 4.5) aumf 那条路单独渲一次：离线引擎里 `AVAudioUnitEffect(audioComponentDescription:)`
    /// 到底能不能装起来、能不能过声音，实时那一路验过不代表渲染这一路也成。
    private func expRenderMusicEffect(vm: PlayerViewModel) {
        let catalog = PluginCatalog.effects()
        let fab = PluginCatalog.fourCC("FabF")
        // 挑 FabFilter 而不是「清单里第一个 aumf」：第一个是 Synthesizer V 的 ARA 挂接，
        // 它当效果器渲染出来是一片 0，量不出这一路到底通没通。
        guard let mfx = catalog.first(where: { $0.kind == .musicEffect && $0.manufacturer == fab })
                ?? catalog.first(where: { $0.kind == .musicEffect }) else {
            expNote("渲染 aumf: 清单里没有音乐效果器，跳过")
            expRenderBothLanes(vm: vm)
            return
        }
        vm.loadPlugin(mfx, at: 1, for: .a)
        awaitForCheck("装载 \(mfx.name)", { vm.slots(.a)[1].plugin != nil }) { loaded in
            guard loaded else {
                self.expNote("渲染 aumf: 「\(mfx.name)」没装上，跳过")
                self.expRenderBothLanes(vm: vm)
                return
            }
            let requests = vm.renderRequests(for: .current, typedName: "aumf",
                                             bitDepth: .f32, directory: Self.expDirectory)
            self.expRun(requests, label: "渲染 \(mfx.name)(aumf)") {
                vm.unloadSlot(1, for: .a)
                self.expRenderBothLanes(vm: vm)
            }
        }
    }

    /// 6) 两条轨道一起渲染，用的还是同一个输入名 —— 撞名规则该给两边各挂一个字母。
    private func expRenderBothLanes(vm: PlayerViewModel) {
        let requests = vm.renderRequests(for: .all, typedName: "mix",
                                        bitDepth: .s16, directory: Self.expDirectory)
        expNote("两轨一起渲: \(requests.count) 个 · "
               + requests.map { $0.outputURL.lastPathComponent }.joined(separator: " / "))
        guard requests.count > 1 else {
            expNote("只有一条轨道有内容，跳过多轨这一步")
            expTrim(vm: vm)
            return
        }
        expRun(requests, label: "渲染 16bit（当前+全部）") {
            self.expTrim(vm: vm)
        }
    }

    /// 7) 裁切那条路：ffmpeg 搬样本，名字用区间戳，输入的文件名该被忽略。
    private func expTrim(vm: PlayerViewModel) {
        let typed = "probe"
        vm.runTrimExport(for: .current, directory: Self.expDirectory) { allSucceeded in
            self.expNote("裁切导出: \(allSucceeded ? "完成" : "没成（成败的窗口已弹）")"
                       + " · 输入名「\(typed)」该被忽略")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.expDirectory.path)) ?? []
            self.expNote("目录里: \(names.sorted().joined(separator: " / "))")
            self.expNamingChecks(vm: vm)
        }
    }

    /// 8) 命名与容器：这些是纯函数，不用等磁盘。
    private func expNamingChecks(vm: PlayerViewModel) {
        guard let lane = vm.exportLanes(for: .current).first else {
            expNote("没有轨道可查命名"); expFinish(); return
        }
        let wav = lane.url
        let fakeMP3 = URL(fileURLWithPath: "/x/歌.mp3")
        let fakeAiff = URL(fileURLWithPath: "/x/歌.aiff")
        expNote("默认名(wav·24)=\(RenderExportService.defaultRenderName(sourceURL: wav, bitDepth: .s24))")
        expNote("默认名(aiff·16)=\(RenderExportService.defaultRenderName(sourceURL: fakeAiff, bitDepth: .s16)) · "
               + "默认名(aiff·32float)=\(RenderExportService.defaultRenderName(sourceURL: fakeAiff, bitDepth: .f32))")
        expNote("容器: mp3·24→\(RenderExportService.containerExtension(for: fakeMP3, bitDepth: .s24)) · "
               + "aiff·24→\(RenderExportService.containerExtension(for: fakeAiff, bitDepth: .s24)) · "
               + "aiff·32float→\(RenderExportService.containerExtension(for: fakeAiff, bitDepth: .f32)) · "
               + "wav·32float→\(RenderExportService.containerExtension(for: wav, bitDepth: .f32))")
        let tagged = RenderExportService.outputURL(typedName: "  ../../偷偷改名.wav  ",
                                                  sourceURL: wav, bitDepth: .s24,
                                                  directory: Self.expDirectory, laneTag: "B")
        expNote("脏输入(带路径)→\(tagged.lastPathComponent)（目录仍=\(tagged.deletingLastPathComponent().path)）")
        expDialogModelChecks(vm: vm)
    }

    /// 9) 对话框状态机：默认名跟着范围/位深走，用户打过的名字不跟着走。
    private func expDialogModelChecks(vm: PlayerViewModel) {
        let model = ExportDialogModel(vm: vm, scope: .current, mode: .render)
        let url = vm.exportLanes(for: .current).first?.url
        expNote("对话框: 名=\(model.fileName) · 范围行=\"\(model.laneSummary)\"")
        let expects = { (depth: ExportBitDepth) in
            url.map { RenderExportService.defaultRenderName(sourceURL: $0, bitDepth: depth) } ?? "?"
        }
        expNote("  开栏就等于纯函数的默认名=\(model.fileName == expects(.s24))")
        model.bitDepth = .f32
        expNote("  换位深跟着走=\(model.fileName == expects(.f32))（\(model.fileName)）")
        let typed = "我自己打的名字"
        model.fileName = typed
        model.nameEdited(typed)
        model.bitDepth = .s16
        model.scope = .all
        expNote("  打过名字之后换位深、换范围=\(model.fileName)（该是不动的那一个）")
        expNote("  切到全部·提示=\"\(model.modeHint)\"")
        model.mode = .trim
        expNote("  裁切·提示=\"\(model.modeHint)\" · 工作中的进度=\(String(describing: model.progress))")
        expMenuFire(vm: vm)
    }

    /// 10) 这一项真按下去。SwiftUI 的 CommandMenu 是开菜单那一刻才把 enabled/target/action
    /// 灌进 NSMenuItem 的，所以读之前先 update() 补一次，不然量到的永远是没接上的空壳。
    private func expMenuFire(vm: PlayerViewModel) {
        guard let item = expExportMenuItem() else {
            expNote("⌘E：主菜单里找不到那一项"); expFinish(); return
        }
        item.menu?.update()
        expNote("⌘E 那一项：enabled=\(item.isEnabled) · 有动作=\(item.action != nil) · "
               + "能导的轨=\(vm.exportLanes(for: .current).count)")
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "e", charactersIgnoringModifiers: "e",
                                         isARepeat: false, keyCode: 14) else {
            expNote("⌘E：造不出按键事件"); expFinish(); return
        }
        let took = NSApp.mainMenu?.performKeyEquivalent(with: key) ?? false
        awaitForCheck("performKeyEquivalent 之后", remaining: 60, { vm.exportRequest != nil }) { opened in
            if opened {
                self.expNote("  按键等价 ⌘E=\(took) → 对话框开=true · "
                           + (vm.exportRequest.map { "范围=\($0.scope.label) 模式=\($0.mode.label)" } ?? ""))
                vm.exportRequest = nil
                self.expControlCheck(vm: vm)
                return
            }
            // 没开就再走一遍完整事件管线（最接近真按键），再看是不是动作本身没接上。
            NSApp.sendEvent(key)
            self.awaitForCheck("sendEvent 之后", remaining: 60, { vm.exportRequest != nil }) { opened2 in
                self.expNote("  按键等价=\(took) 没开 · sendEvent ⌘E 之后开=\(opened2) · "
                           + (vm.exportRequest.map { "范围=\($0.scope.label) 模式=\($0.mode.label)" }
                              ?? (item.action.map { "sendAction=\(NSApp.sendAction($0, to: item.target, from: item))" }
                                  ?? "项子没有动作")))
                vm.exportRequest = nil
                self.expControlCheck(vm: vm)
            }
        }
    }

    /// 对照实验：拿一个 1.x 就在用、真机上确认过的菜单快捷键 ⌘1（版本对比）走同一条合成
    /// 路径。它要是不开火，就说明这条路测不了 SwiftUI 的菜单快捷键，⌘E 的量不到不是 BUG。
    private func expControlCheck(vm: PlayerViewModel) {
        vm.setCompareMode(.reference)
        guard let one = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "1", charactersIgnoringModifiers: "1",
                                         isARepeat: false, keyCode: 18) else {
            expNote("对照：造不出 ⌘1 事件"); expFinish(); return
        }
        let took = NSApp.mainMenu?.performKeyEquivalent(with: one) ?? false
        awaitForCheck("对照 ⌘1 换模式", remaining: 60, { vm.compareMode == .versionCompare }) { changed in
            self.expNote("对照 ⌘1（版本对比·1.x 就有）：按键等价=\(took) → 模式换了=\(changed)"
                       + " · 现在=\(vm.compareMode)")
            vm.setCompareMode(.reference)
            // 动作本体这一路必须通：菜单项里就是这一句。
            vm.openExportDialog(scope: .current, mode: .trim)
            self.expNote("openExportDialog(当前, 裁切)：对话框开=\(vm.exportRequest != nil) · "
                       + (vm.exportRequest.map { "范围=\($0.scope.label) 模式=\($0.mode.label)" } ?? "没有请求"))
            vm.exportRequest = nil
            self.expFinish()
        }
    }

    /// 一轮渲染：进度报峰值、回来的文件逐个查。
    private func expRun(_ requests: [RenderExportService.Request], label: String,
                        then: @escaping () -> Void) {
        guard !requests.isEmpty else { expNote("\(label): 没有任务"); then(); return }
        var maxProgress = 0.0
        let started = Date()
        RenderExportService.run(requests, progress: { fraction in
            maxProgress = max(maxProgress, fraction)
        }, completion: { [weak self] result in
            guard let self = self else { return }
            let seconds = Date().timeIntervalSince(started)
            switch result {
            case .failure(let error):
                self.expNote("\(label): 失败 \(error.localizedDescription)")
            case .success(let urls):
                self.expNote("\(label): 成 · 耗时 \(String(format: "%.2f", seconds))s · "
                            + "进度峰值=\(String(format: "%.2f", maxProgress))")
                // 读回和自相关搬到后台：这一格在主队列上跑到一半，界面就跟着冻住。
                DispatchQueue.global(qos: .userInitiated).async {
                    for url in urls { self.expInspect(url) }
                    DispatchQueue.main.async { then() }
                }
                return
            }
            DispatchQueue.main.async { then() }
        })
    }

    /// 读回渲染出来的文件：帧数、位深、峰值，和「延迟 × 采样率」那一格的自相关。
    private func expInspect(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else {
            expNote("  读不回来: \(url.lastPathComponent)"); return
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else {
            expNote("  读不出样本: \(url.lastPathComponent)"); return
        }
        let frames = Int(buffer.frameLength)
        let channel = UnsafeBufferPointer(start: data[0], count: frames)
        var samples = [Float](repeating: 0, count: frames)
        var peak = 0.0
        for index in 0..<frames {
            samples[index] = channel[index]
            let value = Double(abs(channel[index]))
            if value > peak { peak = value }
        }
        let expect = Int(Self.expDelaySeconds * format.sampleRate)
        let start = 4_000, window = 20_000
        let atExpect = autocorrForCheck(samples, lag: expect, start: start, window: window)
        let near = bestAutocorrForCheck(samples, from: max(1, expect - 2_000), to: expect + 2_000,
                                        start: start, window: window)
        // 全局峰只在有界的短程里找（滞后 ≤2 s、窗口缩到 4000）：整首 246 s 的轨若按
        // 全部滞后扫就是 6 M × 2 万次乘加，主线程会在这儿挂到天黑。
        let lagCap = max(2_001, min(frames - window - start, Int(2 * format.sampleRate)))
        let global = bestAutocorrForCheck(samples, from: 2_000, to: lagCap,
                                         start: start, window: 4_000)
        expNote("  \(url.lastPathComponent): \(frames) 帧 = \(String(format: "%.3f", Double(frames) / format.sampleRate))s"
               + " · \(format)")
        expNote("    峰值=\(String(format: "%.4f", peak)) · 期望 \(expect) 帧处 r=\(String(format: "%.3f", atExpect))"
               + " · 期望±2000 内峰=\(String(format: "%.3f", near.r))@\(near.lag)帧 · 2s 内全局峰=\(String(format: "%.3f", global.r))@\(global.lag)帧")
    }

    private var expLines: [String] = []
    private func expNote(_ line: String) { expLines.append(line) }
    private func expFinish() {
        writeDiag(expLines.joined(separator: "\n") + "\n", suffix: ".export")
    }

    private var edLines: [String] = []
    private var edPlugin: AUPlugin?
    private var edDry = AudioEngine.DebugCapture(ch0: [], ch1: [], gaps: 0, callbacks: 0)
    private var edDelayAddress: AUParameterAddress?
    private var edDelaySeconds = 0.0
    /// 写参数之前读到的那一档，撤销要对着它比（AUDelay 的默认是 1 s，不是量程上界）。
    private var edOriginal: Double?
    /// AUDelay 的延迟默认是 1 s，量程上限就是它；写 0.25 s 才看得出峰真的搬了家。
    private static let edWantedDelay: Double = 0.25

    /// 采一段输出（同步：填缓冲的是音频线程，不需要主队列腾出手来）。
    private func auCapture(_ label: String) -> AudioEngine.DebugCapture {
        guard let vm = vm else { return Self.auEmptyCapture() }
        let e = AudioEngine.shared
        var result = Self.auEmptyCapture()
        for attempt in 1...3 {
            vm.seekSide(.a, to: 0)
            vm.play()
            let settle = Date().addingTimeInterval(4)
            while vm.position(of: .a) < 1.0, Date() < settle {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            e.debugStartCapture()
            let timedOut = !e.debugWaitForCapture(frames: Self.auCaptureFrames)
            let c = e.debugFinishCapture()
            vm.pause()
            result = c
            auNote("\(label) #\(attempt): \(timedOut ? "TIMEOUT " : "")frames=\(c.frameCount) "
                   + "cb=\(c.callbacks) gaps=\(c.gaps) err=\"\(e.debugStartError)\"")
            if c.gaps == 0, !timedOut { break }
        }
        return result
    }

    /// 等一个异步动作落地再往下走（50 ms 回头看一次，最多 60 s）。等不到也要往下走，
    /// 但要把「没等到」这件事告诉调用方，不然报告里就只剩一个看起来像成功的空档。
    private func awaitForCheck(_ label: String, remaining: Int = 1_200,
                               _ done: @escaping () -> Bool, then: @escaping (_ settled: Bool) -> Void) {
        if done() { DispatchQueue.main.async { then(true) }; return }
        guard remaining > 0 else {
            auNote("等待超时: \(label) · 轨迹=\(AudioEngine.shared.debugSlotTrace)")
            DispatchQueue.main.async { then(false) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.awaitForCheck(label, remaining: remaining - 1, done, then: then)
        }
    }

    private func auNote(_ line: String) { auLines.append(line) }
    private func auFinish() {
        writeDiag(auLines.joined(separator: "\n") + "\n", suffix: ".au")
    }
    private static func auEmptyCapture() -> AudioEngine.DebugCapture {
        AudioEngine.DebugCapture(ch0: [], ch1: [], gaps: 0, callbacks: 0)
    }

    /// 探针状态：装载是异步的，采回来的信号和计时都得存在属性里，传不下去。
    private var auLines: [String] = []
    private var auPlugin: AUPlugin?
    private var auDry = AudioEngine.DebugCapture(ch0: [], ch1: [], gaps: 0, callbacks: 0)
    private var auLoadedAt = Date()
    private var auDelaySeconds = 0.5
    private var auExpect = 0
    /// AUDelay 的延迟档：0.5 秒，采到的相关峰就该落在 0.5 s × 链路采样率 那一帧。
    private static let auWantedDelay: Float = 0.5
    private static let auCaptureFrames = 96_000


    /// 验收。声道与电平表共用同一个抽头，所以要分开问两件事：
    /// 1) 抽头有没有在跑（看电平读数是否非零）；
    /// 2) 抽头里就地改写的样本会不会走到输出（硬左时末级采样的右声道是否静音）。
    /// 只跑编辑拓扑的三小段，不用重跑那六轮采样。
    private func exerciseLaneTapForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("LANE: 音轨未就绪，跳过\n", suffix: ".lane")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseLaneTapForCheck(remaining: remaining - 1)
            }
            return
        }
        let e = AudioEngine.shared
        var lines: [String] = []
        vm.setOutputGain(0)
        vm.setActiveTrack(.a)
        vm.stopPlayback()
        vm.setEditMode(true)
        vm.setPreGain(0, for: .a)

        /// 一轮采样：给定 pan，把播放头锁到 60 秒之后，等它真走到开窗点再抓 1.5 秒。
        /// 上一版从 0 秒起采，各轮开窗其实落在曲子的不同位置（暂停后 position 读数还
        /// 是上一轮的尾巴，等待循环就直接放行了），于是每一轮量的都不是同一段信号。
        /// 末段单独再看一次峰值，用来分开设「这一档还没生效」和「淡变吃进了窗口」。
        func probe(_ label: String, pan: Int, frames: Int) -> AudioEngine.DebugCapture {
            vm.setPan(pan, for: .a)
            vm.pause()
            vm.seekSide(.a, to: 60)
            vm.play()
            let settle = Date().addingTimeInterval(6)
            while vm.position(of: .a) < 61.0, Date() < settle {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            let started = vm.position(of: .a)
            _ = vm.lanePeakDB(.a)          // 清空上一段攒下的峰值
            e.debugStartCapture()
            let timedOut = !e.debugWaitForCapture(frames: frames)
            let c = e.debugFinishCapture()
            let tap = vm.lanePeakDB(.a)
            vm.pause()
            let half = c.ch1.count / 2
            let tailR = chanPeakForCheck(c, Array(c.ch1[half...]))
            lines.append("\(label) pan=\(pan): 开窗@\(String(format: "%5.1f", started)) "
                         + "frames=\(c.frameCount) cb=\(c.callbacks) "
                         + "gaps=\(c.gaps) 抽头 L=\(String(format: "%6.2f", tap.left)) "
                         + "R=\(String(format: "%6.2f", tap.right)) | 输出 L=\(String(format: "%6.2f", chanPeakForCheck(c, c.ch0))) "
                         + "R=\(String(format: "%6.2f", chanPeakForCheck(c, c.ch1))) "
                         + "(末半 R=\(String(format: "%6.2f", tailR)))"
                         + (timedOut ? " TIMEOUT" : ""))
            lines.append("    节点状态 " + e.debugLaneState)
            return c
        }

        // 同一个值连测两轮，再加一次 0：如果输出跟着 pan 反着走或慢一轮，这里就会露出来。
        let neutral = probe("中置a", pan: 0, frames: 72_000)
        probe("中置b", pan: 0, frames: 72_000)
        let hard = probe("硬左a", pan: -64, frames: 72_000)
        probe("硬左b", pan: -64, frames: 72_000)
        let half = probe("左1/4", pan: -32, frames: 72_000)
        probe("复位", pan: 0, frames: 72_000)
        vm.setPan(0, for: .a)
        vm.setPreGain(Double(AudioEngine.preGainDefaultDB), for: .a)
        lines.append(String(format: "近侧 ΔL(硬左)=%.2f 期望 0.00；远侧 硬左=%.2f 左1/4=%.2f 期望 −inf / −6.02（实测本机法则是线性的，半偏 −6.03，见 /tmp/pantest/tapplace）",
                            chanPeakForCheck(hard, hard.ch0) - chanPeakForCheck(neutral, neutral.ch0),
                            chanPeakForCheck(hard, hard.ch1) - chanPeakForCheck(neutral, neutral.ch1),
                            chanPeakForCheck(half, half.ch1) - chanPeakForCheck(neutral, neutral.ch1)))
        writeDiag(lines.joined(separator: "\n") + "\n", suffix: ".lane")
    }

    /// 电平表的验收（AB_METER_CHECK）。探针不去抽引擎的峰值（那要和表抢数据），
    /// 只按 100 Hz 抄表自己的读数，数三件事：
    /// 1) 表的 lastFresh 动了多少回 —— 这就是表真正换新读数的频率。旧版整包压成一个峰值，
    ///    这一项只有约 10.9/s（一包 4410 帧 = 91.9 ms）；改成 5 ms 子窗 + 60 Hz 取窗之后
    ///    该贴住表自己的 60/s；
    /// 2) current 从有声掉到 −90 以下多少回 —— 掉一次就是一道看得见的闪烁，该是 0；
    /// 3) 引擎那一头的队列积压峰值和丢窗数 —— 表按流逝时间去取窗，积压该只有几个、丢窗该是 0。
    /// 注意 Debug 构建里波形重画很贵（实测每帧几百 ms），这一相量的是「取数节奏」，
    /// 观感上的延迟要以 Release 为准。
    private func exerciseMeterForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                writeDiag("METER: 音轨未就绪，跳过\n", suffix: ".meter")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseMeterForCheck(remaining: remaining - 1)
            }
            return
        }
        let meters = MixerPanelController.shared.meters
        vm.setOutputGain(0)
        vm.setActiveTrack(.a)
        vm.stopPlayback()
        vm.setEditMode(true)
        if !MixerPanelController.shared.isVisible { vm.toggleMixer() }
        vm.setPreGain(0, for: .a)
        vm.setLaneFader(0, for: .a)
        vm.setPan(0, for: .a)

        final class Watch {
            var polls = 0
            var freshEdges = 0
            var dips = 0
            var lows: [Double] = []
            var gaps: [Double] = []
            /// 引擎那一头：队列最多积到几个窗、总共丢过几个。积得多 = 表取窗取慢了；
            /// 丢窗 > 0 = 界面根本没在问（子窗封顶 60 个 = 0.3 秒）。
            var pendingPeak = 0
            var dropped = 0
            var at = Date()
            var last = -96.0
            var lastFresh = Date.distantPast
            func reset() {
                polls = 0; freshEdges = 0; dips = 0; lows = []; gaps = []
                pendingPeak = 0; dropped = 0
                at = Date(); last = -96; lastFresh = .distantPast
            }
            func report(_ label: String) -> String {
                let sorted = lows.sorted()
                let g = gaps.sorted()
                return String(format: "%@: 抄表 %d 回（期望 200）· 表拿到新样本 %d 回 · 间隔 中位 %.0f ms 最长 %.0f ms\n",
                              label, polls, freshEdges,
                              g.isEmpty ? -1 : g[g.count / 2] * 1000,
                              g.isEmpty ? -1 : (g.last ?? 0) * 1000)
                    + String(format: "    读数: 中位 %6.2f dBFS · 最低 %6.2f · 最高 %6.2f · 有声→塌底 %d 次（修好后该是 0）\n",
                             sorted.isEmpty ? -96 : sorted[sorted.count / 2],
                             sorted.first ?? -96, sorted.last ?? -96, dips)
                    + String(format: "    抽头队列: 积压峰值 %d 窗 · 丢窗 %d\n", pendingPeak, dropped)
            }
        }
        let w = Watch()
        let engine = AudioEngine.shared
        // 抄表只用表自己的读数：全程不抽引擎的峰值，抽了就是和表抢数据。
        // 两相都从 60 秒往后放：曲子的头几秒近乎无声，抽头照样交付峰值 ≈0 的数据，
        // 那种相里表本来就该贴底，量的就不是闪烁行为。
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let lane = meters.snapshot.a
            let now = Date()
            w.gaps.append(now.timeIntervalSince(w.at))
            w.at = now
            w.polls += 1
            if lane.lastFresh != w.lastFresh { w.freshEdges += 1; w.lastFresh = lane.lastFresh }
            if lane.current < -90, w.last >= -90 { w.dips += 1 }
            w.lows.append(lane.current)
            w.last = lane.current
            w.pendingPeak = max(w.pendingPeak, engine.debugLanePendingWindows(.a))
            w.dropped = engine.debugLaneDroppedWindows(.a)
        }
        var out = ""
        // 第 1 相：停在 60 秒，一句都不放。定时器本身跑不跑得到 100 Hz，这一相看出来了。
        vm.seekSide(.a, to: 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            out += w.report("静止")
            w.reset()
            vm.play()                       // 就在 60 秒接着放，不进淡入
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                vm.pause()
                out += w.report("播放")
                timer.invalidate()
                self.writeDiag(out, suffix: ".meter")
            }
        }
    }

    /// 电平表那 2 秒延迟的来路（AB_METERLAG_CHECK）。用户实测：编辑模式换轨后旧轨的表
    /// 还接着画 2.06 秒才清空，新轨要 1.91 秒才开始画，而音频没有这个延迟。2 秒正好等于
    /// 抽头队列的封顶（从前是 400 窗 × 5 ms），所以量两本账就能分开两种可能：
    /// 1) 抽头交得比表取的多（子窗时长报准了没 —— `realRate` 对 `rate`）；
    /// 2) 表被主线程压住，一拍最多按 `dueCap` 取 10 个窗，取不满就一直欠着（`dtMax`、`clamped`）。
    /// 三相：放 50 秒（头一相要长过「旧算法约 40 秒攒满 400 个窗」那一段，才看得出还漏不漏）
    /// → 换轨 → 再放 12 秒 → 暂停 4 秒，每 0.5 / 0.25 秒各抄一行。
    private func exerciseMeterLagForCheck(remaining: Int = 300) {
        guard let vm = vm else { return }
        if vm.loadPending > 0 {
            guard remaining > 0 else {
                meterLagNote("起始: 音轨未就绪，跳过")
                meterLagFinish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.exerciseMeterLagForCheck(remaining: remaining - 1)
            }
            return
        }
        guard vm.tracks.count > 1 else {
            meterLagNote("起始: 播放列表只有一首，换不了轨")
            meterLagFinish()
            return
        }
        let meters = MixerPanelController.shared.meters
        let engine = AudioEngine.shared
        // 全局增益拉到 −60：抽头在 A/B 选择器和它上游，所以表照常有数，喇叭不响，
        // 这一支要放 30 多秒，别把整间屋子跟着一起放。
        vm.setOutputGain(-60)
        vm.setActiveTrack(.a)
        vm.setEditMode(true)
        if !MixerPanelController.shared.isVisible { vm.toggleMixer() }
        vm.setPreGain(0, for: .a)
        vm.setLaneFader(0, for: .a)
        vm.setPan(0, for: .a)
        vm.seekSide(.a, to: 60)
        // 表那两本账从这一刻清零；引擎的账是从抽头装上起就一直在记的，
        // 所以看差值，不看绝对数。
        meters.dbgResetLedger()
        let started = Date()
        var lastTickAt = started
        var lastProduced = 0
        var lastTaken = 0
        meterLagNote("起始: \(vm.trackA?.url.lastPathComponent ?? "?") → "
                     + "\(vm.tracks[1].url.lastPathComponent) · 表已开=\(MixerPanelController.shared.isVisible)")

        func sample(_ phase: String) {
            let g = engine.debugLaneWindowLedger(.a)
            let taken = g.produced - g.dropped - g.pending
            let now = Date()
            let dtWall = now.timeIntervalSince(lastTickAt)
            let producedRate = dtWall > 0 ? Double(g.produced - lastProduced) / dtWall : 0
            let takenRate = dtWall > 0 ? Double(taken - lastTaken) / dtWall : 0
            lastTickAt = now
            lastProduced = g.produced
            lastTaken = taken
            meterLagNote(String(
                format: "%@ t=%.2f 积=%d 交=%d 丢=%d 取=%d | 交=%.1f窗/s 取=%.1f窗/s | 窗长=%.6fs 包=%d帧 自称=%.0fHz 实测=%.0fHz | 拍=%d 均dt=%.2fms 最dt=%.2fms 削=%d | 读数=%.1f 在放=%d 在装=%d",
                phase, now.timeIntervalSince(started), g.pending, g.produced, g.dropped, taken,
                producedRate, takenRate, g.windowSeconds, g.lastPacketFrames, g.declaredRate,
                g.spanSeconds > 0.1 ? Double(g.totalFrames) / g.spanSeconds : -1,
                meters.dbgTicks,
                meters.dbgTicks > 0 ? meters.dbgDtSum / Double(meters.dbgTicks) * 1000 : -1,
                meters.dbgDtMax * 1000, meters.dbgClampedTicks,
                meters.snapshot.a.current, engine.isPlaying ? 1 : 0, vm.loadPending))
        }

        vm.play()
        let playing = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in sample("放") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) {
            playing.invalidate()
            sample("换轨前")
            vm.setTrackA(index: 1)          // 就是用户那一下：把列表里另一首装进 A 轨
            // 解码是异步的；装完之后接着放，和手点之后照常按播放一样。
            self.awaitForCheck("换轨装载", remaining: 400, { vm.loadPending == 0 }) { _ in
                vm.play()
                let after = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    sample("换轨后")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    after.invalidate()
                    vm.pause()
                    sample("暂停始")
                    let idle = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                        sample("暂停")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        idle.invalidate()
                        sample("暂停末")
                        self.meterLagFinish()
                    }
                }
            }
        }
    }

    private var meterLagLines: [String] = []
    private func meterLagNote(_ line: String) { meterLagLines.append(line) }
    private func meterLagFinish() {
        writeDiag(meterLagLines.joined(separator: "\n") + "\n", suffix: ".meterlag")
    }
#endif

    /// Look the press up in the shortcut table and run it. True means consumed.
    @discardableResult
    func dispatch(_ event: NSEvent, vm: PlayerViewModel) -> Bool {
        drive(keyCode: event.keyCode, modifiers: event.modifierFlags,
              charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", vm: vm)
    }

    /// The same call with the key data spelled out. A diagnostic needs this because
    /// every synthetic keystroke on this machine is dropped for want of Accessibility
    /// permission, so a press can only be driven from inside the app.
    @discardableResult
    func drive(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
               charactersIgnoringModifiers: String, vm: PlayerViewModel) -> Bool {
        // One key can carry two bindings (⇧↩ and ↩ share a key code, and users may
        // bind two actions to the same press). The table hands back the first match
        // in declaration order, so a press that match declines — ABX with no live
        // round — is looked up again with it excluded.
        var declined: Set<ShortcutAction> = []
        while let action = ShortcutStore.shared.action(forPressWithKeyCode: keyCode,
                                                        modifiers: modifiers,
                                                        charactersIgnoringModifiers: charactersIgnoringModifiers,
                                                        excluding: declined) {
            if perform(action, vm: vm, modifiers: modifiers) { return true }
            declined.insert(action)
        }
        return false
    }

    /// Runs one bound action. Returns false when the key press must fall through
    /// to the rest of the app: the ⌘ combos have their own branch, and the ABX
    /// keys only mean something while a round is live.
    private func perform(_ action: ShortcutAction, vm: PlayerViewModel,
                         modifiers: NSEvent.ModifierFlags) -> Bool {
        let abxLive = vm.abxIsActive && !vm.abxShowResult && !vm.abxShowSetup && !vm.abxShowConfirm
        // In 参考曲 the transport keys take both lanes unless ⌃ narrows them to the
        // current one; 版本对比 ignores ⌃ because its lanes are always locked.
        let currentOnly = modifiers.contains(.control)
        switch action {
        case .copyToBackupList, .clearRanges: return false
        case .abxSwitchA:         guard abxLive else { return false }; vm.abxSelectA(); return true
        case .abxSwitchB:         guard abxLive else { return false }; vm.abxSelectB(); return true
        case .abxSwitchX:         guard abxLive else { return false }; vm.abxSelectX(); return true
        case .abxConfirmContinue: guard abxLive else { return false }; vm.abxContinue(); return true
        case .playPause:          vm.syncTogglePlayPause(currentTrackOnly: false); return true
        // 空格改成和 K 同一件事（两轨一起起停）。走带那颗播放按钮照旧只
        // 管状态指示那一轨（它读的是 sideIsPlaying(activeTrack)，口径不能跟着变），
        // 所以动的是这里的分支而不是 togglePlayPause 本身。
        case .stopAll:            vm.stopPlayback(); return true
        case .stopCurrentLane:    vm.stopSide(vm.activeTrack); return true
        case .setTrackA:          guard let i = vm.selectedTrackIndex else { return true }; vm.setTrackA(index: i); return true
        case .setTrackB:          guard let i = vm.selectedTrackIndex else { return true }; vm.setTrackB(index: i); return true
        case .switchTrack:        vm.switchTrack(); return true
        case .rangeCompare:       vm.toggleRangeCompare(); return true
        case .prevMarker:         vm.jumpToPrevMarker(); return true
        case .nextMarker:         vm.jumpToNextMarker(); return true
        case .prevMarkerBothLanes: vm.jumpToMarkerBothLanes(earlier: true); return true
        case .nextMarkerBothLanes: vm.jumpToMarkerBothLanes(earlier: false); return true
        case .prevTrack:          vm.selectPrevTrack(); return true
        case .nextTrack:          vm.selectNextTrack(); return true
        case .deleteMarker:       vm.deleteNearestMarker(); return true
        case .clearMarkers:       vm.clearAllMarkers(); return true
        case .markSide:           vm.addSideMarkerAtCurrentPosition(); return true
        case .rewind:             vm.nudge(by: -3, currentTrackOnly: currentOnly); return true
        case .forward:            vm.nudge(by: 3, currentTrackOnly: currentOnly); return true
        case .rewindFine:         vm.nudge(by: -0.1, currentTrackOnly: currentOnly); return true
        case .forwardFine:        vm.nudge(by: 0.1, currentTrackOnly: currentOnly); return true
        case .skipBack:           vm.nudge(by: -10, currentTrackOnly: currentOnly); return true
        case .skipForward:        vm.nudge(by: 10, currentTrackOnly: currentOnly); return true
        case .syncPlayPause:      vm.syncTogglePlayPause(currentTrackOnly: currentOnly); return true
        case .rewindToStart:      vm.rewindToStart(); return true
        case .rewindAllToStart:   vm.rewindAllToStart(); return true
        case .removeTrack:        vm.removeSelectedTrack(); return true
        case .moveToBackupList:   vm.moveSelectedToBackup(); return true
        case .copyToMainList:     vm.copySelectedBackupToMain(); return true
        case .prevBackup:         vm.selectPrevBackup(); return true
        case .nextBackup:         vm.selectNextBackup(); return true
        case .setAFromBackup:     vm.setTrackAFromBackupSelected(); return true
        case .setBFromBackup:     vm.setTrackBFromBackupSelected(); return true
        case .rangeSelectMode:    vm.toggleRangeSelection(); return true
        case .toggleInfo:         InfoPanelController.shared.toggle(vm: vm); return true
        case .togglePlaylist:     vm.showPlaylistSidebar.toggle(); return true
        case .toggleFollowPlayhead: SettingsStore.shared.waveformFollowPlayhead.toggle(); return true
        case .toggleSplitStereo:  SettingsStore.shared.waveformSplitStereo.toggle(); return true
        case .setRangeStartHere:  vm.setRangeStartAtPlayhead(); return true
        case .setRangeEndHere:    vm.setRangeEndAtPlayhead(); return true
        case .enterTimecode:      vm.beginTimecodeEntry(syncBoth: true); return true
        case .enterTimecodeCurrent: vm.beginTimecodeEntry(syncBoth: false); return true
        case .undoEdit:           vm.undoEdit(); return true
        case .redoEdit:           vm.redoEdit(); return true
        // 盲听进行中不改拓扑：换链路会把 pre-gain 接进来，电平一跳这一轮就白听了。
        case .toggleEditMode:     guard !vm.abxIsActive else { return false }; vm.toggleEditMode(); return true
        // x 与 ABX 的 X 共用一把键，谁在轮上由查表顺序决定；不在编辑模式时这把键
        // 什么都不做，把按键交还给系统。
        case .toggleMixer:        guard vm.editMode else { return false }
                                    vm.toggleMixer(); return true
        // 视频窗口和编辑模式互斥（裁定）：模式一开，⌘6 这把键什么都不做，
        // 交还给系统。守卫也写在动作里，菜单那条走的是同一个入口。
        case .toggleVideo:        guard !vm.abxIsActive, !vm.editMode else { return false }
                                    vm.toggleVideo(); return true
        }
    }

    /// Dock 图标点回来（程序在跑、窗口藏着）：把主窗口叫回来。规格另一半 ——
    /// 关闭改成藏起来之后，SwiftUI 自己不再管重开（它以为那扇窗口还在），所以这一条
    /// 得我们接。返回 true 是不让系统再去做它那套「新建窗口」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

#if DEBUG
    private func setupDebugAutoplay() {
        let args = CommandLine.arguments
        guard args.contains("--autoplay") else { return }
        let paths = args.dropFirst().filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let vm = self?.vm else { return }
            vm.openFiles(urls: paths.map { URL(fileURLWithPath: $0) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                vm.playFromStart()
            }
        }
    }
#endif
}

// MARK: - Settings View

struct SettingsView: View {
    /// 三个分页。选中项以前由 TabView 自己记着，探针想拍哪一页都点不到（这台机器注入
    /// 不了鼠标），所以把它拿到自己手里，Debug 里用 AB_SETTINGS_TAB=data 直接指定。
    enum Panel: String, Identifiable {
        case shortcuts, display, data
        var id: String { rawValue }
    }

    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @State private var editingAction: ShortcutAction? = nil
    /// 设置→数据里「当前缓存大小」那一句。数据页出现时算一次，
    /// 装载计数变动时再算 —— ffmpeg 的转码就发生在装载里，一首新歌转完这一格就该跟着变。
    @State private var audioCacheText = AudioFormatCache.sizeText()
    /// 「优先使用AVFoundation「裁切」」那枚 ? 圆按钮的浮层。
    @State private var trimHelpShown = {
        #if DEBUG
        // 浮层要点那枚 ? 才出来，这台机器注不进鼠标，所以 Debug 里直接摊开拍照。
        if ProcessInfo.processInfo.environment["AB_TRIM_HELP"] != nil { return true }
        #endif
        return false
    }()
    /// 「将本页设置恢复默认」的二次确认（三页共用一份，记的是哪一页该弹）。
    @State private var resetPage: Panel? = initialResetPage()

    /// Debug 里拍照用的起始页：可选类型套在闭包字面量里编译不过（实测），所以摆到静态函数里。
    private static func initialResetPage() -> Panel? {
        #if DEBUG
        if let want = ProcessInfo.processInfo.environment["AB_RESET_PAGE"],
           let picked = Panel(rawValue: want) { return picked }
        #endif
        return nil
    }
    @State private var panel: Panel = {
        #if DEBUG
        if let want = ProcessInfo.processInfo.environment["AB_SETTINGS_TAB"],
           let picked = Panel(rawValue: want) { return picked }
        #endif
        return .shortcuts
    }()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            TabView(selection: $panel) {
                shortcutTab.tag(Panel.shortcuts).tabItem { Label("快捷键", systemImage: "keyboard") }
                displayTab.tag(Panel.display).tabItem { Label("显示", systemImage: "waveform.path.ecg") }
                dataTab.tag(Panel.data).tabItem { Label("数据", systemImage: "internaldrive") }
            }
            .frame(width: 460, height: 400)

            // 「将本页设置恢复默认」原先摆在各页的 ScrollView 末尾，实测三页
            // 都被 400 pt 的折行切在视线之外；提到 TabView 下面和「关闭」同一行，三页共用
            // 一枚，按下时按当前页清理。
            Divider()
            HStack {
                Button("将本页设置恢复默认") { resetPage = panel }
                Spacer()
                Button("关闭") { vm.showSettings = false }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
        .padding()
        .alert("将本页设置恢复默认",
               isPresented: Binding(get: { resetPage != nil },
                                    set: { if !$0 { resetPage = nil } })) {
            Button("恢复", role: .destructive) { runPageReset() }
            Button("取消", role: .cancel) { }
        } message: { Text(resetConfirmText) }
    }

    /// 二次确认那一句：三页各说各清什么。
    private var resetConfirmText: String {
        switch resetPage {
        case .shortcuts: return "所有快捷键回到出厂键位。"
        case .display:   return "滚轮、波形、界面这几格回到默认（毛玻璃和无缝切轨恢复为开）。"
        case .data:      return "会话恢复、列表字号、裁切方式回到默认。缓存和标记不动。"
        case nil:        return ""
        }
    }

    private func runPageReset() {
        switch resetPage {
        case .shortcuts: ShortcutStore.shared.resetToDefaults()
        case .display:   SettingsStore.shared.resetDisplaySettings()
        case .data:      SettingsStore.shared.resetDataSettings()
        case nil:        break
        }
        resetPage = nil
    }

    private var shortcutTab: some View {
        VStack(spacing: 0) {
            if let editing = editingAction {
                VStack(spacing: 12) {
                    Text("按下新快捷键").font(.headline)
                    Text("ESC取消").foregroundColor(.secondary)
                    KeyCaptureView { key in
                        if key == "\u{1b}" { editingAction = nil }
                        else {
                            ShortcutStore.shared.bindings[editing] = key
                            ShortcutStore.shared.save()
                            editingAction = nil
                        }
                    }.frame(width: 200, height: 60).background(Color(white: 0.2)).cornerRadius(8)
                    Button("取消") { editingAction = nil }
                }.padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ShortcutAction.settingsSections, id: \.title) { section in
                            Text(section.title)
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                            ForEach(section.actions, id: \.self) { shortcutRow($0) }
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
    }

    /// One row of 快捷键设置: the name on the left, the bound key as a button. Layout
    /// is unchanged by the grouping — only the order the rows arrive in.
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.rawValue).frame(width: 140, alignment: .leading)
            Spacer()
            Button(displayKey(ShortcutStore.shared.key(for: action), for: action)) {
                editingAction = action
            }.frame(width: 80).buttonStyle(.bordered)
        }.padding(.horizontal, 12).padding(.vertical, 2)
    }

    private var displayTab: some View {
        // 这一页以前刚好塞满 TabView 那 400 pt，所以没套滚动条；「界面」两枚开关加进来
        // 之后溢出了，溢出是把顶部的分页标签一起顶没的（实测），所以照「快捷键」页的
        // 老办法套一层 ScrollView。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("反转滚轮方向（缩放/移动）", isOn: $settings.invertWheel)
                    .toggleStyle(.switch)

                Divider()

                Text("波形").font(.headline)

                VStack(alignment: .leading, spacing: 3) {
                    Text("动态深度 −\(Int(settings.waveformDepthDB)) dBFS")
                    Slider(value: Binding(get: { log2(settings.waveformDepthDB) },
                                          set: { settings.waveformDepthDB = exp2($0) }),
                           in: log2(12.0)...log2(96.0))
                    Text("控制波形显示。也可用⌘+滚轮调节，⌥点按波形右侧蓝色滑块恢复 −30。")
                        .font(.caption).foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("滚轮每格平移约 1/\(Int(settings.waveformPanDivisor)) 屏")
                    Slider(value: $settings.waveformPanDivisor, in: 1...20, step: 1)
                }

                Toggle("分声道显示（L / R 各一条）", isOn: $settings.waveformSplitStereo)
                    .toggleStyle(.switch)
                Toggle("水平缩放时画面跟随播放头", isOn: $settings.waveformFollowPlayhead)
                    .toggleStyle(.switch)

                Divider()

                Text("界面").font(.headline)
                Toggle("走带栏毛玻璃", isOn: $settings.transportGlass)
                    .toggleStyle(.switch)
                Toggle("列表栏毛玻璃（播放列表 / 备用列表）", isOn: $settings.listGlass)
                    .toggleStyle(.switch)
                Toggle("启用无缝切换视频轨", isOn: $settings.seamlessVideoSwitch)
                    .toggleStyle(.switch)
                // 毛玻璃那格的灰字按要求删掉；这句换成给定的措辞。
                // 按圈定的 C 版（影响性能）；数字与「条」之间不留空格。
                Text("使切换轨道时，视频不中断。但可能会影响性能（同时解码2条视频流）。")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 退出编辑模式前那一句「请先降低监听设备音量」改成可控的，默认开。
                Toggle("退出编辑模式时弹窗提示", isOn: $settings.editModeExitPrompt)
                    .toggleStyle(.switch)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dataTab: some View {
        // 这一页从上到下比 TabView 那 400 pt 高出十几像素，而 SwiftUI 在
        // 高度不够时压的是唯一「可以只给一行」的那一格 —— 会话恢复那句说明，于是它被截成
        // 一行带「…」。套一层 ScrollView（「显示」那一页溢出时也是这么办的）：内容拿到该给
        // 的高度，长说明自己折行。
        ScrollView {
            VStack(spacing: 20) {
                // 会话恢复从「一直这么做」变成设置里的一条，默认不恢复。
                // 底下那句灰字按要求删掉，这一格不再需要包一层 VStack。
                Toggle("打开程序后自动恢复上次会话", isOn: $settings.autoRestoreSession)
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider().padding(.horizontal, 20)

                // 裁切走哪一路由这一格说了算，说明藏在那枚 ? 后面。
                HStack(spacing: 6) {
                    Toggle("优先使用AVFoundation「裁切」", isOn: $settings.preferAVFoundationTrim)
                        .toggleStyle(.switch)
                    // ? 紧跟开关：规格要的是「在其右侧有一个 ? 圆形按钮」，铺到行尾就成了
                    // 另一头的东西。
                    Button { trimHelpShown.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $trimHelpShown, arrowEdge: .leading) {
                        Text("只影响「裁切」导出。启用后，入点更加精确，但对于某些播放器或编辑软件，打开裁切后的文件时，可能在入点前仍保留一定片段。\n关闭后，则一律使用ffmpeg -c copy裁切，兼容性更好，但如果范围未包含关键帧窗口，则视频中可能部分/全部无画面，且音频会引入至多约93ms延迟。\n无论该功能是否启用，「裁切」均不会使视频或音频有任何品质损失。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(width: 330)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().padding(.horizontal, 20)
                Text("播放列表字号：\(Int(settings.playlistFontSize)) pt")
                HStack {
                    Button("−") { settings.bumpPlaylistFont(by: -1) }
                    Button("＋") { settings.bumpPlaylistFont(by: 1) }
                    Button("重置") { settings.resetPlaylistFont() }
                }
                Divider().padding(.horizontal, 20)
                Text("数据管理").font(.headline)
                // 混音器「预设」那格的文件夹，直接开在访达里。
                Button("前往通道条预设文件夹") { ProjectStore.revealPresetDirectory() }
                    .buttonStyle(.bordered)
                // 系统解码器读不了的容器（ogg / opus / wma / ape /
                // wv / dsf）由 ffmpeg 转成 24 bit wav 落在缓存里，跨会话保留 —— 所以给一格
                // 大小、一个去处、一个清空。清空之后同一首歌下次打开会重转一遍。
                HStack(spacing: 8) {
                    Button("前往音频缓存文件夹") { AudioFormatCache.revealDirectory() }
                        .buttonStyle(.bordered)
                    Button("清除缓存") {
                        AudioFormatCache.clear()
                        audioCacheText = AudioFormatCache.sizeText()
                    }
                    .buttonStyle(.bordered)
                }
                Text("音频缓存: \(audioCacheText)")
                    .font(.caption).foregroundColor(.secondary)
                Button("清除所有标记数据") { vm.clearAllMarkers() }
                    .buttonStyle(.bordered).tint(.red)
            }
            .padding()
        }
        .task(id: vm.loadPending) { audioCacheText = AudioFormatCache.sizeText() }
    }

    /// Renders a stored signature (⌃⌥⇧ then the key, as the recorder writes it).
    private func displayKey(_ key: String, for action: ShortcutAction) -> String {
        guard !key.isEmpty else { return "未指定" }
        var prefix = ""
        var rest = Substring(key)
        for symbol in ["\u{2318}", "\u{2303}", "\u{2325}", "\u{21E7}"] where rest.hasPrefix(symbol) {
            prefix += symbol
            rest = rest.dropFirst(symbol.count)
        }
        let base: String
        switch rest {
        case " ":     base = "Space"
        case "\u{8}": base = "退格"
        case "\u{7f}": base = "删除"
        case "\u{F700}": base = "↑"
        case "\u{F701}": base = "↓"
        case "\u{F702}": base = "←"
        case "\u{F703}": base = "→"
        default:      base = rest.uppercased()
        }
        // These two only ever fire with ⌘ held; the recorder never sees the ⌘.
        return ShortcutStore.commandOnly.contains(action) ? "⌘" + prefix + base
                                                         : prefix + base
    }
}

// MARK: - Key Capture

struct KeyCaptureView: NSViewRepresentable {
    var onKey: (String) -> Void
    func makeNSView(context: Context) -> KCView { let v = KCView(); v.onKey = onKey; return v }
    func updateNSView(_ v: KCView, context: Context) { v.onKey = onKey }
}

class KCView: NSView {
    var onKey: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        let sig = ShortcutStore.signature(for: event)
        if !sig.isEmpty { onKey?(sig) }   // a bare ⌥/⇧ press is not a shortcut
    }
}

// MARK: - Help View

struct HelpView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("AB-Player 使用帮助").font(.title2.bold())
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(.top, 16)
            Divider().padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("快速开始", """
                    将音频/视频拖入播放列表 → 按空格播放/暂停、按F切换轨道
                    • 主窗口左下角绿色A/蓝色B指示器，也可被点击以切换
                    """)
                    section("视图与模式（菜单→模式，⌘1 … ⌘6）", """
                    • 单轨视图：A/B 同步播放、同步拖动进度，范围对比同时写入两轨。
                    • 双轨视图：上下两组波形/进度条独立控制各自的 A、B 轨道。
                    • ABX：进入设置轮数（0 为无限），确认后开始盲听测试。
                    • 编辑模式：切换音频链路以提供效果器挂载。上述视图中均可使用。
                    • 混音器：仅在编辑模式中可使用。
                    • 视频窗口：编辑模式与 ABX 期间不可用。
                    """)
                    section("轨道与播放列表", """
                    • Q / E：把播放列表中选中的文件设为 A / B 轨道。
                    • F：切换监听轨道（A ⇄ B）。仅切换监听，不改变播放头位置；时钟读数跟随选定轨道。
                    • W / S：在播放列表中选择；⌃M：移除选中文件。
                    • T：移动选中文件至备用列表；⌘T：复制选中文件至备用列表。
                    • ↑ / ↓：在备用列表中选择；G：复制选中文件至播放列表。
                    • ← / →：在备用列表中将选中文件设为 A / B 轨道。
                    • 右键菜单：设为 A/B 轨道、移动、复制、移除；多选时会作用于全部选中文件。
                    • Shift+单击 或 鼠标拉框：多选（两个列表各自独立）。
                    • 按住 ⌘ 拖动文件名可调序。备用列表顺序全局通用，播放列表顺序可跟随工程文件保存（.abpl）。
                    • P：打开/关闭播放列表栏。
                    • 备用列表在退出后自动保存，下次启动恢复；播放列表不保存。若恢复的文件已被删除，将其设为 A/B 轨道时该条目会标灰。若保存为工程文件，则播放列表状态跟随工程文件（见"工程文件与轨道预设"）。
                    • I：打开/关闭「信息」窗口，切换轨道时内容自动更新。
                    • ⌘+ / ⌘− / ⌘=：调整列表字号，⌘0 恢复默认（数值记录在设置中）。
                    """)
                    section("音频格式与缓存", """
                    • 除系统可直接读取的（wav / aiff / mp3 / m4a / flac / caf 等）以外，支持 ogg / oga / opus / wma / ape / wv / dsf 7 种。
                    •  7 种系统无法直接解码的，将通过 ffmpeg 转为 24 bit  wav 在缓存。可在设置→数据中查看。不会对原文件产生任何影响。找不到 ffmpeg 时会加载失败并说明原因，其余格式不受影响。
                    • dsf（DSD）统一折到 176.4 kHz 的 PCM（带宽 88 kHz，DSD 的全部内容都在其中）。
                    • .dff 不支持：ffmpeg 里没有该解容器。
                    • 缓存落在「~/Library/Application Support/AB-Player/音频缓存」，跨会话保留。可通过「设置 → 数据」：「前往音频缓存文件夹」、查看当前缓存大小和「清除缓存」；清除后，如果再次打开同个原文件，将会重新转换。
                    """)
                    section("标记", """
                    • 反引号 `：为 A、B 两轨同时打标记（橙色▼，位于进度条上方）。
                    • M：仅为状态指示显示的轨道打标记（亮青色▲，位于进度条下方）。
                    • , / .：跳到上一个 / 下一个标记；退格：删除距离最近的 1 个标记；删除键：清空本文件标记。
                    • ⇧, / ⇧.：A、B 两轨同时跳到上一个 / 下一个橙色▼标记；跳转至同一全局时刻，没有可跳转的标记时无操作。
                    • 若音频文件含有可识别的章节信息，则自动将其转为当前轨的 M 标记（亮青▲）：章节落在文件所被载入轨道，两轨独立。
                    • 章节支持 m4a / mp4（AVFoundation 直读）、mp3（ID3v2 CHAP）与 flac（Vorbis comment，由本程序自解析）容器。
                    """)
                    section("时间与范围", """
                    • 空格：两轨同时播放/暂停（等效 K）；J / L：后退/前进 3 秒；⇧J / ⇧L：微调 0.1 秒；⌘J / ⌘L：快转 10 秒；K：两轨同时播放/暂停。
                    • H：停止 —— 两轨停止并回到开头；⌃H：仅作用选定轨道。
                    • 双轨视图下 J / K / L（含 ⇧ 与 ⌘ ）同时作用于两轨，按住 ⌃ 只作用于当前轨（⌃J、⌃⇧J、⌃⌘J 同理）；单轨视图两轨始终同步，⌃ 无效。
                    • Enter：回到开头。"单轨视图"两轨同时归零；"双轨视图"先归零当前轨，若已在开头（<0.05 秒）时再次按下，则另一轨也归零。
                    • 双击走带栏时钟（或按 /）输入时间码跳转；
                    按住⌘双击（或按⌘/） A、B 两轨同步跳转。
                    以空格分段，「时 分 秒」：`4`＝4分0秒，`4 33`＝4分33秒，`1 2 3`＝1小时2分3秒；位数不足自动补 0，超出时长则操作无效、不提示。
                    • 进度条上按住 ⌘ 拖动可临时改用「选择」工具框选范围。按住 ⇧ 点按或拖动进度条，两轨同步跳转至同一时间点。
                    按住 ⇧⌘ 框选，对 A、B 两轨同时框选同一段范围。
                    • R 或「选择」按钮：进入范围框选模式，在进度条上按住拖动框出范围。
                    • [ / ]：以当前播放头为范围起点 / 终点。另一端沿用现有值；若尚无范围，起点补至曲首、终点补至曲末。新值越过另一端时自动交换。
                    • C 或「范围播放」按钮：开启后在所选范围内循环；播放头在范围外时会自动跳回范围起点。
                    • ⌘R 或「取消选择」按钮：清除所有已选范围。
                    • 时间偏移（time trim）：双轨视图中，波形图右侧最下方按钮。按住上下拖动，一格 1 秒，⇧ 0.1 秒，⌃ 10 毫秒，⇧⌃ 一个样本；向上 = 延后，向下 = 提前。⌥ 点按归零；双击下方毫秒读数，可按「秒 / 毫秒 / 样本」三格填数（三格加算，留空计为 0）。偏移仅改变该轨监听和时间刻度，不对标记、范围、导出产生影响。
                    """)
                    section("撤销与重做（默认 ⌘Z / ⌘⇧Z）", """
                    • 可撤销：主窗口中，播放列表与备用列表的修改、任意标记的修改、范围、各轨时间偏移、监听增益。历史共 30 步。
                    • 编辑模式中，pre-gain、声像、插件、推子，以及 [A→B] / [A←B] 按钮操作，会被记录在历史中。
                    • 不记录历史：A / B 轨道的赋值、播放头位置、列表选中行、缩放与动态深度、当前模式、编辑模式的启用状态。
                    • 换曲（为 A 或 B 轨道载入新文件）会清空历史。
                    • 推子连续拖动只在释放时记录一条。
                    • 「编辑」菜单的标题打印的是当前绑定的键，改绑后菜单更新。
                    """)
                    section("响度检测（菜单 文件 → 检测响度）", """
                    • 同时对 A、B 两轨测量，完成后按 A→B 的顺序给出：响度 LUFS、真峰值 dBTP、响度范围 LRA。
                    • 真峰值 ≥ 0 dBTP 的行末标 ⚠️，其余标 🟢。
                    • 「保存」把结果写成纯文本，落在第一个文件同目录下，文件名形如 响度分析_YYYYMMDD_HHMMSS.txt。
                    • 需要 ffmpeg。找不到 ffmpeg 时提示。
                    """)
                    section("窗口与视图", """
                    • 菜单「显示 → 保存当前窗口大小为默认」将当前尺寸记为默认值；「应用默认窗口大小」将窗口缩放至目标尺寸。
                    • Z：复位视图，水平缩放回到 1×、动态深度回到 −30 dBFS。ABX 中 z 仍用于确认答案，此时不复位。
                    • 毛玻璃：「设置 → 显示 → 界面」，走带栏和列表栏可单独控制。
                    • ABX 界面字号 = 播放列表字号 × 1.25。
                    • 关闭窗口不会退出程序：进程、播放和工程保留。按⌘1/2/3，或从菜单→模式，或点击程序坞图标即可唤出。
                    """)
                    section("波形缩放与移动", """
                    • ⌥⌘+滚轮：水平缩放（时间密度，最高 200×），以鼠标位置为锚点；也可用右侧橙色滑块，⌥点按滑块恢复 1×（不缩放）。
                    • ⌘+滚轮：调节纵轴动态深度（−12 … −96 dBFS，对数刻度）；也可用蓝色滑块，⌥点按滑块恢复 −30。
                    • 鼠标 / 触控板自动识别：
                    触控板：垂直滚动整体反向，推子增益的增减与手指移动方向一致；波形图上双指伸张／并拢＝水平缩放，双指左右滑＝移动波形。
                    鼠标：维持原有的滚轮方向与翻页移动波形。
                    • 走带栏最右侧全局增益推子：−∞ … +12 dB，0 dB 位于行程约 72%，越靠近 0 单位行程内的 dB 变化越小（精度越高）。
                    ⌥点按推子任意位置归零；双击右侧的读数，可输入精确值；按住 ⌃ + 滚轮以 0.5 dB 微调。仅影响监听，导出的文件不带增益；启动时回到 00.00。
                    • 缩放后波形底部出现横向位置指示条，可拖动滑块，也可点击轨道空白处跳转；缩放关闭时自动淡出。
                    • 水平缩放后（鼠标模式），用鼠标滚轮可翻页移动波形：向上滚看向末尾，向下滚看向开头（不影响播放与播放头位置）。
                    每格移动的距离可在「设置 → 显示」中调节。
                    • 水平缩放后，波形上按住抓手拖动可平移。
                    • 走带栏时间右侧：>|< 按钮 = 画面跟随播放头（启用时图案着色为橙色，底色不变，默认 ⌃⇧F），○ 按钮 = 分声道显示开关（默认 ⇧S）。
                    • 方向、分声道、跟随、滚轮平移速度均可在「设置 → 显示」中调节。
                    """)
                    section("ABX 操作", """
                    • A / D / X：试听 A、B 或 X（随机轨）。
                    • 「X是？A / B」：记录本轮答案，可重复改选（高亮跟随最新答案）。
                    • Z：确认答案并进入下一轮；「结束」查看成绩汇总。
                    • 成绩汇总带置信度：按单侧二项检验算出「完全随机猜测也能达到这一成绩」的概率 p，并给出判定（p < 5% 记为可分辨）。未作答的轮次不计入。
                    • 界面隐藏波形图，避免颜色提示泄露当前轨道，保证测试公正（但，进度条仍存在：若两轨时长不同，或播放头所在位置不同步，则仍可通过视觉判断。推荐使两轨同步后进行）。
                    """)
                    section("编辑模式（菜单 模式 → 编辑模式，默认 ⌘4）", """
                    • 进入后 A、B 两轨各接一条独立链路：音频 → pre-gain → 声像 → 6格插件槽 → 推子 → 主混音；退出时原路接回，走原有直连链路。
                    • pre-gain 在链首（−60 … 0 dB，默认 −6）。
                    • 该模式下，播放/暂停按钮、时钟的颜色改变，以提示状态。
                    • ABX 进行中不能进入编辑模式。
                    """)
                    section("混音器窗口（编辑模式下按 ⌘5，菜单 模式 → 混音器）", """
                    • 双击轨道名称可重命名。
                    • [A→B] / [A←B] 将整条通道条设置拷贝至另一轨。
                    • 「预设」会保存该轨：pre-gain、声像、插件、推子、旁通状态。
                    • 「预设」菜单里：载入预设（列预设文件夹里的 .abpreset）。
                    • pre-gain、推子、声像也会烤进「渲染后导出」的文件；走带栏的全局推子，不参与导出。
                    """)
                    section("视频窗口（⌘6，菜单 模式 → 视频窗口）", """
                    • 单画面，窗口展示当前监听轨道画面，F 换轨时跟随切换。
                    • 「启用无缝切换视频轨」（设置 → 显示 → 界面，默认开）：F 换轨时画面无缝衔接。代价：两轨的解码器同时工作，占用更多性能。关闭则只解码当前轨，但切换时会有短暂黑帧。
                    • 编辑模式与 ABX 期间画面无效，窗口会自动收起，⌘6 在这两个状态下也不弹出；退出模式后不自动重开，按 ⌘6 唤回。
                    • 目前仅支持：容器：mp4 / mov / m4v，编码：H.264 / HEVC / ProRes。渲染导出时无画面；「裁切」导出包含画面。
                    """)
                    section("插件", """
                    • 「Bypass」：将该轨所有插件旁通。
                    • 按住 ⌘ 点击移除插件。
                    • 拖拽调序：长按插件可移动至其他插槽，支持跨轨。若目标轨道已加载插件，则对调位置。若按住⌥拖拽（释放左键时判定），则拷贝该插件至目标插槽。可用 ⌘Z 撤销。
                    • 1 … 6 打开 A 轨对应格的插件界面，⇧1 … ⇧6 打开 B 轨的；V 收起 / 展开全部插件页面；⌘F 弹出搜索框，Enter将插件载入首个空槽。
                    """)
                    section("导出", """
                    • 菜单「导出」分三组：「导出…」（默认 ⌘E，打开对话框）｜「裁切当前轨道范围…」「裁切全部轨道范围…」｜「渲染后导出当前轨道范围…」「渲染后导出全部轨道范围…」。
                    • 对话框中含两个互斥选项：
                    「裁切，旁通所有插件」：仅截取片段，以源编码导出。不可修改输出文件名，将以固定格式输出（包含范围时间码）。
                    「渲染，应用插件效果」：pre-gain、声像、插件、推子都烤进文件；文件名可输入，默认 reMix_原名.扩展名。未进入编辑模式时则无插件参与，导出原样音频（仅修改位深）。
                    • 位深三档：16 bit / 24 bit / 32 bit float。容器与源一致，仅可用：wav / aif / aifc / caf 。若选择32 bit float ，仅wav可用。mp3、m4a 等均会以 wav导出。
                    • 无插件导出的文件名仍是 clip_原名_[开始MM-SS_结束MM-SS].扩展名（如 clip_demo_[01-30_04-33].wav），只有范围完全相同才会覆盖。
                    • 两轨一起渲染且名称相同时自动挂上 [A] / [B]，不会互相覆盖；扩展名由源文件和位深重新决定。
                    • 无插件导出，部分场景需要 ffmpeg；渲染导出不需要。若AVFoundation不可用，则使用ffmpeg导出。导出完成后播放提示音（Blow）。
                    • 导出对话框中，保存目录会被记忆，变更目录后更新。
                    • 对于选择范围，若其中一轨的已选范围已超出另一轨结尾，则较短的一轨范围终点落在曲末。
                    """)
                    section("工程文件与轨道预设（菜单 文件）", """
                    • 存储工程（⌘S）｜存储为…（⇧⌘S）｜打开工程…（⇧⌘O）。
                    •  .abpl 保存会话参数，不复制音频文件。
                    • 可自动恢复上次会话：「设置 → 数据 → 打开程序后自动恢复上次会话」，默认为关（只保留备用列表）。
                    • 载入工程视为切换整个会话，撤销历史会被清空。ABX不会被自动拉起。
                    • 轨道预设只改变该轨通道条设置，不含曲目、标记与范围。更换曲目不影响通道条设置。
                    • 预设与工程按插件身份（类型 / 子类型 / 厂商 / 名字）认件。本机没有的插件会被跳过并在提示里点名，其余装载，不会整条链一起失败。
                    • 默认目录：预设落在「~/Library/Application Support/AB-Player/轨道预设」，「载入预设」列出 .abpreset（按名称排序，默认档不单列）；「保存预设」自定义名称写入该文件夹；「保存当前预设为默认」名为 默认-A.abpreset / 默认-B.abpreset。工程落在「文稿」。
                    • 「设置 → 数据 → 前往通道条预设文件夹」：在访达中打开该文件夹。
                    """)
                    Text("所有快捷键均可在「设置…（⌘,）→ 快捷键」中修改；录制支持修饰键 ⌘ ⌃ ⌥ ⇧（例如 ⇧S、⌃⇧F、⌘/），按 ESC 取消录入。\n例外：1 … 6 / ⇧1 … ⇧6 / V / ⌘F 按插槽位置对应，不进表；「导出…」（⌘E）、「存储工程」（⌘S）与「存储为…」（⇧⌘S）、「打开工程…」（⇧⌘O）和 ⌘1 / ⌘2 / ⌘3 是菜单自带的快捷键，不在表中。")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack { Spacer(); Button("关闭") { dismiss() }.padding(10) }
        }
        .frame(width: 560, height: 620)
        .background(Color(white: 0.12))
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.body).foregroundColor(.primary)
        }
    }
}
