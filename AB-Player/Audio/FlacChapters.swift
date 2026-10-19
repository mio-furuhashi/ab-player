import Foundation

/// FLAC 自带的章节要自己读。
///
/// 实测本机（macOS 14.4.1）拿一份 4 格章节的 FLAC 对账：ffprobe 数得出 4 格，
/// 而 AVFoundation 连一条元数据都不交 —— `asset.metadata` 是 0 条，
/// `chapterMetadataGroups(withTitleLocale:)` 三种 locale 全 0 组，它对 FLAC 的
/// VORBIS_COMMENT 整块都不看（MP3 的 ID3v2 CHAP 反倒读得到，locale 认 `und`）。
/// 所以「FLAC 没有章节」这句话错在尺子上：数据在文件里，只是系统的读法看不见。
///
/// 这一份只补 FLAC 那一格：按 Xiph 的块格式读文件最前面的 METADATA_BLOCK，
/// 取 type 4（VORBIS_COMMENT）里保留键 `CHAPTERNN` / `CHAPTERNNNAME`，
/// 音频数据一个字节都不碰。
enum FlacChapters {

    /// 注释块一定在文件开头；1 MB 是留给「前面还挂着大块（封面图）」的余量。
    private static let headerCap = 1_048_576

    static func read(from url: URL) -> [Chapter] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4), head == Data("fLaC".utf8) else { return [] }
        guard let bytes = try? h.read(upToCount: headerCap), !bytes.isEmpty else { return [] }
        let data = [UInt8](bytes)          // 一次拷进字节数组，下面全是整数下标

        guard let comment = vorbisCommentBlock(in: data) else { return [] }
        return chapters(from: entries(in: comment))
    }

    /// 走 METADATA_BLOCK 链：每块 = 1 字节（最高位 = 最后一块，低 7 位 = 类型）
    /// + 3 字节大端长度 + 内容。返回第一个 type 4（VORBIS_COMMENT）的内容。
    private static func vorbisCommentBlock(in data: [UInt8]) -> [UInt8]? {
        var i = 0
        while i + 4 <= data.count {
            let last = data[i] & 0x80 != 0
            let type = data[i] & 0x7F
            let size = Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            i += 4
            if i + size > data.count { return nil }        // 声明的长度超出读到的范围
            if type == 4 { return Array(data[i..<(i + size)]) }
            i += size
            if last { return nil }
        }
        return nil
    }

    /// 注释块 = u32 小端 vendor 长 + vendor + u32 小端条数 + 每段 (u32 小端长 + "键=值")。
    private static func entries(in block: [UInt8]) -> [(String, String)] {
        var out: [(String, String)] = []
        guard block.count > 4 else { return out }
        var i = 4 + u32(block, 0)          // vendor 内容用不上，直接跳
        guard i + 4 <= block.count else { return out }
        let count = u32(block, i)
        i += 4
        for _ in 0..<count {
            guard i + 4 <= block.count else { break }
            let n = u32(block, i)
            i += 4
            guard n >= 0, i + n <= block.count else { break }
            let field = String(decoding: block[i..<(i + n)], as: UTF8.self)
            if let eq = field.firstIndex(of: "=") {
                out.append((String(field[..<eq]), String(field[field.index(after: eq)...])))
            }
            i += n
        }
        return out
    }

    private static func u32(_ data: [UInt8], _ at: Int) -> Int {
        guard at + 4 <= data.count else { return 0 }
        let b0 = Int(data[at]), b1 = Int(data[at + 1]), b2 = Int(data[at + 2]), b3 = Int(data[at + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Xiph 的保留键：`CHAPTERNN` 是时间、`CHAPTERNNNAME` 是标题（NN 从 1 起、通常补零到
    /// 两位）；也有工具把时间写成 `CHAPTERNNTIME`，两种都认。时间格式 `H:MM:SS.mmm…`，
    /// 名字缺就留空。
    private static func chapters(from fields: [(String, String)]) -> [Chapter] {
        var times: [Int: TimeInterval] = [:]
        var names: [Int: String] = [:]
        for (key, value) in fields {
            let k = key.uppercased()
            guard k.hasPrefix("CHAPTER") else { continue }
            var tail = k.dropFirst(7)
            let isName = tail.hasSuffix("NAME")
            if isName { tail = tail.dropLast(4) } else if tail.hasSuffix("TIME") { tail = tail.dropLast(4) }
            guard let n = Int(tail) else { continue }
            let text = value.trimmingCharacters(in: .whitespaces)
            if isName {
                if !text.isEmpty { names[n] = value }
            } else if let t = parseTime(text) {
                times[n] = t
            }
        }
        return times.keys.sorted().compactMap { n in
            guard let t = times[n] else { return nil }
            return Chapter(title: names[n] ?? "Chapter", startTime: t)
        }
    }

    private static func parseTime(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let hh = Double(parts[0]), let mm = Double(parts[1]), let ss = Double(parts[2]) else { return nil }
        guard hh >= 0, mm >= 0, mm < 60, ss >= 0, ss < 60 else { return nil }
        return hh * 3600 + mm * 60 + ss
    }
}
