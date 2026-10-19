import Foundation

class FFmpegService {
    /// Resolved lazily on first use and cached for the process lifetime:
    /// Intel Homebrew, Apple Silicon Homebrew, system, then every PATH dir.
    static let ffmpegPath: String? = resolve()

    /// 「没装 ffmpeg」这句话裁切导出、音频解码缓存、响度检测三处都要说（裁定
    /// 「抽成一个量，调用三次」），措辞从此只改这一处。
    static let missingFFmpegText = "未找到 ffmpeg，请先安装（brew install ffmpeg）"

    private static func resolve() -> String? {
        var candidates = ["/usr/local/bin/ffmpeg",
                          "/opt/homebrew/bin/ffmpeg",
                          "/usr/bin/ffmpeg"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/ffmpeg" }
#if DEBUG
        // 验收「未找到 ffmpeg」那一路的提示：这台机器装着 ffmpeg，只能让解析先空手
        // （AB_FFMPEG_MISSING=1）。Release 二进制里没有这一行。
        if ProcessInfo.processInfo.environment["AB_FFMPEG_MISSING"] != nil { return nil }
#endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 裁切导出的总入口。设置里那枚开关决定先试哪一路：开着时先走
    /// AVFoundation（入点帧精确、不重编码），它读不了或写不出的容器静默回落 ffmpeg -c copy。
    /// 回调第二个值 = 这一份是不是「AV 用不了、改由 ffmpeg 裁的」（裁定的口径：
    /// 这种成功要弹窗点名，纯 ffmpeg 那条路——包括开关关着——不算）。
    static func exportClip(inputURL: URL,
                            startTime: TimeInterval,
                            endTime: TimeInterval,
                            outputDirectory: URL,
                            completion: @escaping (Result<URL, Error>,
                                                   _ usedFFmpegFallback: Bool) -> Void) {
        guard SettingsStore.shared.preferAVFoundationTrim else {
            exportClipWithFFmpeg(inputURL: inputURL, startTime: startTime,
                                 endTime: endTime, outputDirectory: outputDirectory) {
                completion($0, false)
            }
            return
        }
        AVFoundationTrim.exportClip(inputURL: inputURL, startTime: startTime,
                                    endTime: endTime, outputDirectory: outputDirectory) { result in
            guard case .failure = result else { completion(result, false); return }
            exportClipWithFFmpeg(inputURL: inputURL, startTime: startTime,
                                 endTime: endTime, outputDirectory: outputDirectory) {
                completion($0, true)
            }
        }
    }

    static func exportClipWithFFmpeg(inputURL: URL,
                            startTime: TimeInterval,
                            endTime: TimeInterval,
                            outputDirectory: URL,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        guard let ffmpeg = ffmpegPath else {
            completion(.failure(NSError(domain: "FFmpegError", code: -1,
                userInfo: [NSLocalizedDescriptionKey: missingFFmpegText])))
            return
        }
        let outputURL = outputDirectory.appendingPathComponent(
            clipFileName(inputURL: inputURL, startTime: startTime, endTime: endTime))

        let startStr = formatTime(startTime)
        let endStr = formatTime(endTime)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y",
            "-i", inputURL.path,
            "-ss", startStr,
            "-to", endStr,
            "-c", "copy",
            outputURL.path
        ]

        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    playCue()
                    completion(.success(outputURL))
                } else {
                    let err = NSError(domain: "FFmpegError", code: Int(proc.terminationStatus),
                                     userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(proc.terminationStatus)"])
                    completion(.failure(err))
                }
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    /// `clip_原名_[开始MM-SS_结束MM-SS].ext`. The name typed in the save panel is
    /// ignored on purpose: the two timecodes tell the clips apart without scanning
    /// the directory for a free number, and only an identical range overwrites.
    static func clipFileName(inputURL: URL, startTime: TimeInterval, endTime: TimeInterval) -> String {
        let stem = inputURL.deletingPathExtension().lastPathComponent
        let ext = inputURL.pathExtension
        let stamp = "\(clipStamp(startTime))_\(clipStamp(endTime))"
        let name = "clip_\(stem)_[\(stamp)]"
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    private static func clipStamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d-%02d", seconds / 60, seconds % 60)
    }

    private static var playingCues: [Process] = []

    /// afplay is detached, and a Process that deallocates while its child is still
    /// running takes the child down with it — so the handle is kept until it exits.
    static func playCue() {
        let cue = Process()
        cue.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        cue.arguments = ["/System/Library/Sounds/Blow.aiff"]
        playingCues.append(cue)
        cue.terminationHandler = { finished in
            DispatchQueue.main.async { playingCues.removeAll { $0 === finished } }
        }
        try? cue.run()
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s)
    }
}
