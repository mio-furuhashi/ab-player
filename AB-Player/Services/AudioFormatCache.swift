import Foundation
import AppKit
import CryptoKit

// MARK: 系统解码器读不了的格式
//
// AVAudioFile 打不开 ogg / opus / wma / ape / wv / dsf 这一类容器（实测：那支 .opus
// 交给 AVURLAsset 只得到 0 条音轨，AVAudioFile 直接抛错）。这一格把它们请系统 ffmpeg
// 转成 24 位 PCM 的 wav 落在缓存里，之后引擎、波形、渲染导出拿到的都是一份普通 wav，
// 整条链不必为这些格式写第二套代码。
//
// 缓存只是「声音」：文件名、容器、编码、码率、章节、导出名仍旧跟着原文件走，轨道行
// 存的也是原文件（工程文件、备用列表都不变）。
//
// 键是「绝对路径 + mtime + 字节数」的 SHA256 前 16 位：原地改过的文件 mtime 变了就另起
// 一份，不会拿旧的糊弄；跨会话保留，所以设置→数据才有「当前缓存大小／清除缓存」这一组。
//
// .dff 不在名单里：ffmpeg 8.1 根本没有 DFF 解容器（`ffmpeg -formats` 里查不到），交给
// 加载失败那一句明说，不做半截支持。
enum AudioFormatCache {
    static let ffmpegExtensions: Set<String> = ["ogg", "oga", "opus", "wma", "ape", "wv", "dsf"]

    /// DSD 的「采样率」是 2.8224 MHz 起，照原样转 PCM 一首曲子就是几个 GB；统一折到
    /// 176.4 kHz（带宽 88 kHz，DSD 的全部内容都在里面，也够 A/B 比对用）。
    private static let dsdExtensions: Set<String> = ["dsf"]
    private static let dsdSampleRate = "176400"

    static var directory: URL {
        ProjectStore.supportDirectory.appendingPathComponent("音频缓存", isDirectory: true)
    }

    static func needsConversion(_ url: URL) -> Bool {
        ffmpegExtensions.contains(url.pathExtension.lowercased())
    }

    /// 这一份源文件对应的那个缓存 wav 的路径（在不在磁盘上都算得出这个名）。
    static func cacheURL(for url: URL) -> URL {
        directory.appendingPathComponent("\(stem(of: url))_\(key(of: url)).wav")
    }

    /// 拿给「只能同步问一句」的调用方：缓存里已经有就用它，没有就原样交回，绝不在这儿
    /// 起转码（主线程等 ffmpeg 就等于冻住界面）。
    static func audioURL(for url: URL) -> URL {
        guard needsConversion(url), isUsable(cacheURL(for: url)) else { return url }
        return cacheURL(for: url)
    }

    /// 要转就转，转完交回能直接 AVAudioFile 打开的那份。阻塞，只能在子线程调用。
    static func resolve(_ url: URL) throws -> URL {
        guard needsConversion(url) else { return url }
        let target = cacheURL(for: url)
        if isUsable(target) { return target }
        guard let ffmpeg = FFmpegService.ffmpegPath else { throw AudioFormatError.missingFFmpeg }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 先落到同目录的 .part：转一半被杀掉（进程被退出、清除缓存撞上）就不会留下一个
        // 看着完整、其实少了尾巴的 wav，下一次命中它就直接当好的用了。
        let partial = URL(fileURLWithPath: target.path + ".part-\(getpid())")
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                         "-i", url.path, "-map", "0:a:0",
                         "-c:a", "pcm_s24le"]
        if dsdExtensions.contains(url.pathExtension.lowercased()) {
            arguments += ["-ar", dsdSampleRate]
        }
        arguments += ["-f", "wav", partial.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        let pipe = Pipe()
        process.standardError = pipe
        // ffmpeg 的输出一旦涨过管道容量就把自己堵死，所以边跑边排空，只留末尾几十 KB
        // 用来报原因。
        var tail = Data()
        let tailLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            tailLock.lock()
            tail.append(chunk)
            if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
            tailLock.unlock()
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0, isUsable(partial) else {
            try? FileManager.default.removeItem(at: partial)
            tailLock.lock()
            let reason = String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            tailLock.unlock()
            throw AudioFormatError.decodeFailed(exit: process.terminationStatus, text: reason)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            // 同一份文件被两条轨同时点开时会撞车：谁先落盘算谁，另一个直接用现成的。
            try? FileManager.default.removeItem(at: partial)
            guard isUsable(target) else { throw error }
        }
        return target
    }

    /// 缓存占了多大（字节）。只数 .wav：.part 是半途，不算用户的账。
    static func totalSize() -> Int64 {
        guard let items = listing() else { return 0 }
        var total: Int64 = 0
        for item in items where item.pathExtension.lowercased() == "wav" {
            total += sizeAndMtime(of: item)?.size ?? 0
        }
        return total
    }

    static func clear() {
        guard let items = listing() else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
        // 峰值是按 wav 的路径存的：文件都不在了，那些包留着只是占内存，而且会让同一份
        // 文件在「清除后再开」时画出旧波形。
        WaveformGenerator.clearCache()
    }

    static func revealDirectory() {
        NSWorkspace.shared.open(directory)
    }

    /// 系统读不了的容器，编码名只能问 ffmpeg：`-i` 后面不接输出，它就把整份流表打到
    /// stderr 然后退出，我们要的是 `Audio: opus` 那一个词。阻塞，别在主线程调。
    static func codecName(of url: URL) -> String? {
        guard let ffmpeg = FFmpegService.ffmpegPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostdin", "-i", url.path]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 流表只有几 KB，先读到 EOF 再等退出就够了；真堵住的话 readDataToEndOfFile
        // 也只会一直读到 ffmpeg 自己结束（它写完表就退，不会等管道）。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let line = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").first(where: { $0.contains("Audio:") }),
              let at = line.range(of: "Audio: ") else { return nil }
        let token = line[at.upperBound...].prefix { !$0.isWhitespace && $0 != "," && $0 != "(" && $0 != "[" }
        return token.isEmpty ? nil : String(token)
    }

    /// 缓存大小那一句用人话讲：不到 1 GB 报 MB，再大报两位小数的 GB。
    static func sizeText() -> String {
        let bytes = totalSize()
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    // MARK: 自用

    private static func listing() -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
    }

    private static func isUsable(_ url: URL) -> Bool {
        // 45 字节是空的 wav 头（44）再多一格样本；比这大的就当是转成功的那份。
        return sizeAndMtime(of: url)?.size ?? -1 > 44
    }

    private static func stem(of url: URL) -> String {
        // 访达里一眼认得出是哪首歌；斜杠是路径分隔符，留着等于写出一条不存在的路径。
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        return name.count > 48 ? String(name.prefix(48)) : name
    }

    private static func key(of url: URL) -> String {
        let stamp = sizeAndMtime(of: url)
        let mtime = stamp?.mtime ?? 0
        let size = stamp?.size ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(mtime)|\(size)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 字节数和修改时间，直接问内核。不用 `url.resourceValues`：它把值记在 URL 实例上，
    /// 同一个 URL 问第二次会交回第一次那个数字（实测：原地追加一个字节之后仍旧报旧尺寸、
    /// 旧时间），而缓存键要的恰恰是「文件真的变了没有」这一件事。
    private static func sizeAndMtime(of url: URL) -> (size: Int64, mtime: Double)? {
        var s = stat()
        guard stat(url.path, &s) == 0 else { return nil }
        return (Int64(s.st_size),
                Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

enum AudioFormatError: LocalizedError {
    case missingFFmpeg
    case decodeFailed(exit: Int32, text: String)

    var errorDescription: String? {
        switch self {
        case .missingFFmpeg:
            return FFmpegService.missingFFmpegText
        case .decodeFailed(let exit, let text):
            // .dff 这类容器就是这么报出来的：ffmpeg 里没这个解容器，退出码非 0。
            let reason = text.split(separator: "\n").last.map(String.init) ?? ""
            return reason.isEmpty ? "ffmpeg 无法打开此文件（退出码 \(exit)）。"
                                  : "ffmpeg 无法打开此文件：\(reason)"
        }
    }
}
