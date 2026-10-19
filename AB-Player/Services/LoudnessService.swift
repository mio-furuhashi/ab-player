import Foundation
import AppKit

/// 「文件」→「检测响度」: 响度检测.workflow ported into the app. The ffmpeg call,
/// the three numbers read out of its summary, the `LUFS | dBTP | LU | name` line
/// format and the ⚠️/🟢 rule are all the automation's, so the result reads exactly
/// like the dialog it used to pop.
enum LoudnessService {
    static let title = "响度检测结果"

    /// The automation's own normalisation targets. They only shape the measurement
    /// window; the numbers reported are of the file as it stands.
    static let filter = "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=summary"

    struct Reading {
        let integrated: String
        let truePeak: String
        let lra: String
        let fileName: String

        /// ffmpeg warns at 0 dBFS, and the automation marks any file whose true
        /// peak has reached it — `+0.0` counts.
        var isClipping: Bool { Double(truePeak).map { $0 >= 0 } ?? false }

        var line: String {
            let mark = isClipping ? "⚠️" : "🟢"
            return "\(integrated) LUFS | \(truePeak) dBTP | \(lra) LU | \(fileName)\(mark)"
        }
    }

    /// The workflow's three greps: `Input Integrated:     -6.7 LUFS` → "-6.7".
    /// Anything it cannot find becomes `N/A`, which is what the shell's `${x:-N/A}`
    /// did, and it keeps a failed run visible instead of printing a blank line.
    static func parse(_ output: String, fileName: String) -> Reading {
        Reading(integrated: value("Input Integrated", in: output),
                truePeak: value("Input True Peak", in: output),
                lra: value("Input LRA", in: output),
                fileName: fileName)
    }

    private static func value(_ label: String, in output: String) -> String {
        for line in output.split(separator: "\n") {
            guard line.contains(label), let split = line.split(separator: ": ", maxSplits: 1).last,
                  let number = split.split(separator: " ").first else { continue }
            return String(number)
        }
        return "N/A"
    }

    /// `响度分析_yyyyMMdd_HHmmss.txt`, written next to the first analysed file —
    /// the automation ran on a Finder selection and used `dirname "$1"`.
    static func reportURL(forFirstFile first: URL, date: Date = Date()) -> URL {
        let stamp = Self.stamp.string(from: date)
        return first.deletingLastPathComponent().appendingPathComponent("响度分析_\(stamp).txt")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    /// Analyse both lanes at once. loudnorm is single-threaded (measured: user time
    /// equals wall time), and the two files are read independently, so a pair
    /// finishes in the time of the longer one rather than the sum of both. Results
    /// come back in the order they were asked for, which is how the dialog lists them.
    static func analyze(urls: [URL], completion: @escaping (Result<[Reading], Error>) -> Void) {
        guard let ffmpeg = FFmpegService.ffmpegPath else {
            DispatchQueue.main.async { completion(.failure(missingFFmpeg)) }
            return
        }

        let lock = NSLock()
        var readings: [Reading?] = Array(repeating: nil, count: urls.count)
        var failure: Error?
        let group = DispatchGroup()

        // Hold the user-initiated assertion for the whole measurement: the result
        // is delivered on the main queue, and an app the user tabbed away from can
        // be napped for tens of seconds — the dialog would show up long after the
        // wait it belongs to. Releasing the token ends it.
        var activity: Any? = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "检测响度")

        for (index, url) in urls.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-hide_banner", "-nostats", "-i", url.path,
                                    "-af", filter, "-f", "null", "-"]
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = pipe
                do {
                    try process.run()
                    // Drain before waiting: ffmpeg prints its whole metadata block,
                    // which is far past the pipe's buffer on a chaptered file.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    lock.lock()
                    readings[index] = parse(text, fileName: url.lastPathComponent)
                    lock.unlock()
                } catch {
                    lock.lock()
                    failure = failure ?? error
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            activity = nil
            if let failure {
                completion(.failure(failure))
            } else {
                completion(.success(readings.compactMap { $0 }))
            }
        }
    }

    static var isFFmpegAvailable: Bool { FFmpegService.ffmpegPath != nil }

    static let missingFFmpeg = NSError(domain: "FFmpegError", code: -1,
        userInfo: [NSLocalizedDescriptionKey: FFmpegService.missingFFmpegText])

    // MARK: - 弹窗

    /// The report body: one line per file, in the order analysed. `echo` gave the
    /// saved file a trailing blank line; the dialog never showed it, because
    /// command substitution strips it, so the two differ by exactly that.
    static func summary(_ readings: [Reading]) -> String {
        readings.map { $0.line }.joined(separator: "\n")
    }

    /// The automation's `display dialog` as an NSAlert: same title, same note icon,
    /// and the same two buttons — AppleScript laid `{"关闭", "保存"}` out left to
    /// right with 保存 the default, so 保存 is added first to sit rightmost and bold.
    static func makeAlert(body: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "关闭")
        return alert
    }

    static func show(readings: [Reading], reportURL: URL) {
        let body = summary(readings)
        if makeAlert(body: body).runModal() == .alertFirstButtonReturn {
            saveReport(body: body, to: reportURL)
        }
    }

    /// `echo "$summary" > file`, including the blank line echo leaves at the end.
    @discardableResult
    static func saveReport(body: String, to url: URL) -> Bool {
        do {
            try (body + "\n\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Export fails silently because the save panel already told the user nothing
    /// went wrong; here a missing ffmpeg is the whole reason nothing happens, so it
    /// says so.
    static func show(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检测响度"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
