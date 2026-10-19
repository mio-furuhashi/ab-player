import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: 轨道预设与工程文件
//
// 两种磁盘形状，同一套编解码：
//   · 轨道预设 = 一条通道条：pre-gain、声道推子、声像、整轨旁通、六格插件链和它们的
//     旋钮位置。不含曲目、范围、标记 —— 它记的是「这条轨怎么处理」，换个曲子也该成立。
//   · 工程文件 = 整个会话：两条列表、A/B 指派、标记、两轨范围、监听增益、两条通道条、
//     对比模式、编辑模式、窗口尺寸。规格说播放列表平时不落盘，除非存过工程文件，
//     所以这份文件就是它唯一的存档入口。
//
// 都是 JSON。AU 状态那一段是 Data，JSONEncoder 自动转 base64，所以插件的参数跟着走，
// 文件本身也还肉眼可读（开一眼就知道哪几格装的是什么）。
//
// 目录：预设默认落在 ~/Library/Application Support/AB-Player/轨道预设，工程默认落在
// 文稿，两处都记住上一次真正用过的文件夹（和导出目录一个规矩）。

/// 一条通道条的存档形状。
struct ChannelPreset: Codable, Equatable {
    var preGainDB: Double
    var faderDB: Double
    var pan: Int
    var laneBypass: Bool
    var slots: [SlotSnapshot?]
}

/// 一个会话的存档形状。
struct ProjectFile: Codable {
    /// 格式号。现在只有 1，留着是为了以后改字段时还能认出旧文件并报一句话。
    var version = 1
    var tracks: [Track]
    var backupTracks: [Track]
    /// A / B 挂的是列表里的哪两条：预设和标记都跟着曲目走，靠 id 认领，不复制行。
    var trackAID: UUID?
    var trackBID: UUID?
    var markers: [String: [Marker]]
    var rangeA: ABRange?
    var rangeB: ABRange?
    /// 两轨的 time trim（秒）。存的是偏移本身，不是换算出来的刻度 —— 曲目换了，
    /// 偏移跟着曲目一起回来，刻度由 `文件时长 + 偏移` 现算。
    var trimA: Double = 0
    var trimB: Double = 0
    var outputGainDB: Double
    var compareMode: CompareMode
    var editMode: Bool
    var laneA: ChannelPreset
    var laneB: ChannelPreset
    var windowWidth: Double?
    var windowHeight: Double?
}

enum ProjectStore {
    static let presetExtension = "abpreset"
    static let projectExtension = "abpl"

    private static let presetDirKey = "presetDirectory"
    private static let projectDirKey = "projectDirectory"
    private static let lastProjectKey = "lastProjectPath"

    // MARK: 目录

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ensuring(base.appendingPathComponent("AB-Player", isDirectory: true))
    }

    /// 预设的默认文件夹：上一次存/载用过的地方，没有就是 Application Support 里那个。
    static var presetDirectory: URL {
        get { stored(presetDirKey) ?? ensuring(supportDirectory.appendingPathComponent("轨道预设",
                                                                                        isDirectory: true)) }
        set { UserDefaults.standard.set(newValue.path, forKey: presetDirKey) }
    }

    /// 「轨道预设」那一格的固定文件夹：Application Support 里那一份，不跟着面板上次
    /// 去过的地方跑。「默认预设」只落在这里 —— 默认档要是会搬家，恢复就成抽奖了。
    static var fixedPresetDirectory: URL {
        ensuring(supportDirectory.appendingPathComponent("轨道预设", isDirectory: true))
    }

    /// 每轨一份默认档：按钮本来就是每轨一颗，共用一份的话 B 存一下就把 A 的顶掉了。
    static func defaultPresetURL(for side: TrackSide) -> URL {
        fixedPresetDirectory.appendingPathComponent("默认-\(side.rawValue).\(presetExtension)")
    }

    static func hasDefaultPreset(for side: TrackSide) -> Bool {
        FileManager.default.fileExists(atPath: defaultPresetURL(for: side).path)
    }

    /// 预设文件夹里现成的 .abpreset，按名字排，给「载入预设」那一格二级菜单用。
    /// 默认档不列在这里：它已经有「恢复默认预设」这一条正门，菜单里再出现一次是噪声。
    static func channelPresets() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: presetDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == presetExtension && !$0.lastPathComponent.hasPrefix("默认-") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 工程文件的默认文件夹：上一次存/开用过的地方，没有就是「文稿」。
    static var projectDirectory: URL {
        get { stored(projectDirKey) ?? documentsDirectory }
        set { UserDefaults.standard.set(newValue.path, forKey: projectDirKey) }
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    /// 上一次 ⌘S 存过的那份工程。「下次打开直接恢复」认的就是这一条。
    static var lastProjectURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: lastProjectKey) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let path = newValue?.path { UserDefaults.standard.set(path, forKey: lastProjectKey) }
            else { UserDefaults.standard.removeObject(forKey: lastProjectKey) }
        }
    }

    private static func stored(_ key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func ensuring(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 面板按扩展名过滤。.abpl 已写进 Info.plist 的文档类型（工程图标靠它），所以拿到
    /// 的是声明过的 UTI；.abpreset 仍是动态 UTI —— 面板照旧按后缀匹配，代价是用户手动选别的
    /// 文件时拦不住，那就交给解码去报。
    static func contentTypes(_ ext: String) -> [UTType] {
        [UTType(filenameExtension: ext)].compactMap { $0 }
    }

    // MARK: 读写

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func write(preset: ChannelPreset, to url: URL) throws {
        try encoder.encode(preset).write(to: url, options: .atomic)
    }

    static func readPreset(from url: URL) throws -> ChannelPreset {
        try JSONDecoder().decode(ChannelPreset.self, from: Data(contentsOf: url))
    }

    static func write(project: ProjectFile, to url: URL) throws {
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    /// 工程文件在访达里的图标只能写进文件本身。
    ///
    /// 声明式那条路在这台机器（macOS 14.4.1）上实测不通：`CFBundleTypeIconFile` 从 11
    /// 起就不参与文档图标；换成现在给的 `UTTypeIcons`（徽章图进 Assets.car）之后，
    /// LaunchServices 确实把 icons 那节读进去了、AB-Player 也确实是 .abpl 的默认
    /// 处理程序，访达里仍然是通用白纸。`setIcon` 是把图元写进文件自己的资源叉，访达照单全收。
    static func applyIcon(to url: URL) {
        guard let icns = Bundle.main.url(forResource: "DocIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: icns) else { return }
        NSWorkspace.shared.setIcon(image, forFile: url.path)
    }

    static func readProject(from url: URL) throws -> ProjectFile {
        try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
    }

    // MARK: 插件认领

    /// 预设里那几格在本机找不找得回来。
    ///
    /// 先按 id 点一遍清单再交给引擎：`restoreSlots` 是顺序装的，第一格失败就把后面几格
    /// 一起放弃，用户只会看见「装到第几格没了」。在这里点名，缺的原话报出来，剩下的照装。
    static func resolve(_ slots: [SlotSnapshot?], catalog: [AUPlugin])
        -> (slots: [SlotSnapshot?], missing: [String]) {
        var missing: [String] = []
        let resolved = slots.map { snapshot -> SlotSnapshot? in
            guard var snapshot, let plugin = snapshot.plugin else { return nil }
            guard let match = catalog.first(where: { $0.id == plugin.id }) else {
                missing.append(plugin.name)
                return nil
            }
            snapshot.plugin = match
            return snapshot
        }
        return (resolved, missing)
    }

    /// 读不回来的文件、缺失的组件都走这一句：和响度检测一样的单按钮提示。
    static func notify(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "AB-Player"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: 通道条预设：手写名字那一条

    /// 「保存预设」的名字框：取消、或者名字空着，都算没这回事（交回 nil，调用方不动手）。
    /// 名字里的 / 换成 -：那是路径分隔符，留着等于让用户写出一条不存在的路径。
    static func askPresetName() -> String? {
        let alert = NSAlert()
        alert.messageText = "保存预设"
        alert.informativeText = "请输入预设名称…"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return name.isEmpty ? nil : name
    }

    /// 同名预设已经在那一格了 —— 问一句是覆盖还是收回。口径定的是：问，不自动挂编号。
    static func confirmPresetOverwrite(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "已有同名预设"
        alert.informativeText = "「\(name)」已经存在，覆盖它吗？"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 「前往通道条预设文件夹」：在访达里打开「载入预设」读的那一格（不是默认档那格固定
    /// 文件夹 —— 菜单里点到的、这份新存的，都是这一格）。
    static func revealPresetDirectory() {
        NSWorkspace.shared.open(presetDirectory)
    }
}
