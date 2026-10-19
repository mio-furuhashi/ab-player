import Foundation
import AudioToolbox

// MARK: AU 清单
//
// 只读每个 .component 的 Info.plist，不碰注册表也不加载代码。实测本机：
// plist 路线 772 条 / 最快 28.5 ms；而 AudioComponentFindNext 全量遍历 aufx
// 在这台机器上跑四分多钟都没走完（首次调用 93.5 ms 就返回了，慢在往后逐个枚举时
// 系统去校验/唤醒组件）。所以列表来自 plist，实例化才交给 AVFoundation。
//
// 清单收 aufx（效果器）和 aumf（音乐效果器）：通道槽是音频插入位，实例化回来的东西
// 必须是 AVAudioUnitEffect（才有 bypass 开关，实测本机 Apple AUDelay 就是这一类）。
// aumf 也收是有实测的：本机 138 条 aumf 里装着 FabFilter 全线（Pro-Q 3／Pro-C 2／Pro-R…）、
// BIAS FX/Pedal、Guitar Rig 7 MFX、Scaler 3 Audio —— 它们照样吃音频，只是多一个 MIDI 入口。
// 拿 AVAudioUnitEffect 装 aumf 实测就是真效果器（Pro-Q 3：1 kHz 正弦 0.5 进、0.5000 出）。
// aumu（乐器）、auoo、编码器那些照旧不收：没有音频输入总线，插进通道只会静音。

/// 轨道预设和工程文件要把插件身份写进磁盘再读回来，所以 AUPlugin 自己就得 Codable。
/// 存的只有四字符码和名字，没有路径：组件被卸掉时按码找不到实例，装载会明确失败，
/// 而不是悄悄换成另一个同名的东西。
struct AUPlugin: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case effect = "aufx"
        case musicEffect = "aumf"

        /// plist 里的 type 字段绝大多数写四字符码，但实测本机 Cableguys PanCake2 写的
        /// 是全名 "kAudioUnitType_Effect"，按四字符码解就永远进不了清单。
        static func parse(_ value: String) -> Kind? {
            if let direct = Kind(rawValue: value) { return direct }
            switch value {
            case "kAudioUnitType_Effect": return .effect
            case "kAudioUnitType_MusicEffect": return .musicEffect
            default: return nil
            }
        }
    }
    let type: OSType
    let subtype: OSType
    let manufacturer: OSType
    let name: String
    let manufacturerName: String
    let kind: Kind
    /// 组件所在 bundle 的文件名，只用于「同一个 Shell 里的一堆插件」在界面上分得开。
    let bundleName: String

    /// 同一个 type/subtype/厂商 组合就是同一个组件：Waves 的 Shell 会重复报同一条，
    /// 用这个 id 去掉重。
    var id: String { "\(type)-\(subtype)-\(manufacturer)-\(name)" }

    var component: AudioComponentDescription {
        AudioComponentDescription(componentType: type,
                                  componentSubType: subtype,
                                  componentManufacturer: manufacturer,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    var subtitle: String { "\(manufacturerName) · \(bundleName)" }
}

enum PluginCatalog {
    /// 四字符码 ↔ 字符串。plist 里写的是 "aufx" 这样的四位串，注册表要的是 OSType。
    static func fourCC(_ value: String) -> OSType {
        let b = Array(value.utf8)
        guard b.count == 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    static func string(_ value: OSType) -> String {
        let b: [UInt8] = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                          UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? ""
    }

    private static let directories: [URL] = {
        let fm = FileManager.default
        return [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/Components"),
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Components", isDirectory: true),
        ]
    }()

    static func effects() -> [AUPlugin] {
        let fm = FileManager.default
        var result: [AUPlugin] = []
        var seen = Set<String>()

        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for url in items where ["component", "audiocomp"].contains(url.pathExtension.lowercased()) {
                guard let plist = NSDictionary(
                        contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      let entries = plist["AudioComponents"] as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let typeString = entry["type"] as? String,
                          let kind = AUPlugin.Kind.parse(typeString),
                          let subtypeString = entry["subtype"] as? String, subtypeString.utf8.count == 4,
                          let manufacturerString = entry["manufacturer"] as? String,
                          manufacturerString.utf8.count == 4 else { continue }
                    let manufacturer = manufacturerName(manufacturerString)
                    let rawName = (entry["name"] as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    // type 从 kind 反查而不是原样吃 typeString：全名那条四字符码转不出来。
                    let plugin = AUPlugin(type: fourCC(kind.rawValue),
                                          subtype: fourCC(subtypeString),
                                          manufacturer: fourCC(manufacturerString),
                                          name: cleanedName(rawName, manufacturer: manufacturer),
                                          manufacturerName: manufacturer,
                                          kind: kind,
                                          bundleName: url.deletingPathExtension().lastPathComponent)
                    guard seen.insert(plugin.id).inserted else { continue }
                    result.append(plugin)
                }
            }
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// 搜索框的排序：名字命中的排前面，其次才是厂商/bundle 命中的。敲 "delay" 时
    /// AUDelay 该顶在第一行，而不是被一串副标题里带 "delay" 的插件挤下去。
    static func matches(_ plugins: [AUPlugin], query: String) -> [AUPlugin] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return plugins }
        let named = plugins.filter { $0.name.lowercased().contains(needle) }
        let rest = plugins.filter { !$0.name.lowercased().contains(needle)
                                   && $0.subtitle.lowercased().contains(needle) }
        return named + rest
    }

    /// 厂商四字符码里认得出的换成全名，认不出的原样显示（Logic 也是这么干的）。
    static func manufacturerName(_ code: String) -> String {
        switch code {
        case "appl": return "Apple"
        case "FabF": return "FabFilter"
        case "wvgt": return "Waves"
        default: return code
        }
    }

    private static func cleanedName(_ raw: String, manufacturer: String) -> String {
        for prefix in ["\(manufacturer): ", "\(manufacturer):"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }
}
