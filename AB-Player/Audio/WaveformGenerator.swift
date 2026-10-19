import AVFoundation

/// Signed per-channel envelope. Polarity is preserved (min and max stored
/// separately) so clipping, DC offset and a silent channel remain visible once
/// the vertical axis becomes logarithmic — the dB transform belongs to the
/// renderer, not to the stored peaks.
struct PeakData {
    let channelCount: Int
    let binFrames: AVAudioFrameCount
    let totalFrames: AVAudioFrameCount
    let sampleRate: Double
    /// [channel][bin]
    let minEnv: [[Float]]
    let maxEnv: [[Float]]

    var binCount: Int { minEnv.first?.count ?? 0 }
    var isEmpty: Bool { binCount == 0 }
    var duration: TimeInterval { sampleRate > 0 ? Double(totalFrames) / sampleRate : 0 }

    static let empty = PeakData(channelCount: 0, binFrames: 1, totalFrames: 0,
                                sampleRate: 0, minEnv: [], maxEnv: [])
}

class WaveformGenerator {
    /// Bins per file, independent of length. Bin *density* therefore adapts to
    /// duration, which is what keeps roughly one bin per screen pixel at the
    /// deepest zoom for every file length.
    static let binBudget = 410_000
    private static let readFrames: AVAudioFrameCount = 32_768

    private static var cache: [URL: PeakData] = [:]

    static func generate(url: URL, budget: Int = binBudget) -> PeakData? {
        if let cached = cache[url] { return cached }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0, sampleRate > 0 else { return nil }

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return nil }

        let binFrames = max(AVAudioFrameCount(1), totalFrames / AVAudioFrameCount(max(1, budget)))
        let binSpan = Int(binFrames)
        let binCount = Int((totalFrames + binFrames - 1) / binFrames)

        var minEnv = [[Float]]()
        var maxEnv = [[Float]]()
        minEnv.reserveCapacity(channelCount)
        maxEnv.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            // +1 / -1 是「还没写进来」的哨兵：样本都在 [-1,1] 里，真数据不会把两头都撞到
            // min>max，收尾那一遍就靠这一条认没碰过的格子。
            minEnv.append([Float](repeating: 1, count: binCount))
            maxEnv.append([Float](repeating: -1, count: binCount))
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else { return nil }

        // 一次 read 一块，一块里一个 bin 一个 bin 地扫：区间内只有裸指针读数 + 标量比较，
        // 写完一个 bin 才碰一次数组。旧写法逐帧比较，每帧一次 floatChannelData、两次嵌套
        // 数组写，实测同一首 286 s 的 MP3 在 -Onone 下要 33 s（同一段解码本身 0.3 s），
        // 改成这样 2 s。开文件慢得飞起、CPU 顶满的就是这一处。
        var chunkStart = 0
        /// 上一块里没收口的 bin：它的样本跨了两次 read()，两半的极值得合到一起。
        var openBin = -1
        while chunkStart < Int(totalFrames) {
            buffer.frameLength = readFrames
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channelData = buffer.floatChannelData else { chunkStart += n; continue }
            let lastBin = min(binCount - 1, (chunkStart + n - 1) / binSpan)
            var bin = max(openBin, chunkStart / binSpan)
            while bin <= lastBin {
                let lo = max(0, bin * binSpan - chunkStart)
                // 这一格的尽头按 bin 自己的边界算，不能用 lo+binSpan：跨块那一格 lo 被夹到 0，
                // 加满一格长就把下一格的样本也吞进来了。
                let hi = min(n, bin * binSpan + binSpan - chunkStart)
                let carry = bin == openBin
                for ch in 0..<channelCount {
                    let p = channelData[ch]
                    var mn: Float = 1
                    var mx: Float = -1
                    var i = lo
                    while i < hi {
                        let v = p[i]
                        if v > mx { mx = v }
                        if v < mn { mn = v }
                        i += 1
                    }
                    if carry {
                        if mn < minEnv[ch][bin] { minEnv[ch][bin] = mn }
                        if mx > maxEnv[ch][bin] { maxEnv[ch][bin] = mx }
                    } else {
                        minEnv[ch][bin] = mn
                        maxEnv[ch][bin] = mx
                    }
                }
                bin += 1
            }
            openBin = bin - 1
            chunkStart += n
        }

        // 一个样本都没落进去的 bin 留的是哨兵，画出来会顶满格；认 min>max 这一条
        // （真数据不可能 min>max），一律写成 0。
        for ch in 0..<channelCount {
            for bin in 0..<binCount where minEnv[ch][bin] > maxEnv[ch][bin] {
                minEnv[ch][bin] = 0
                maxEnv[ch][bin] = 0
            }
        }

        let peaks = PeakData(channelCount: channelCount, binFrames: binFrames,
                             totalFrames: totalFrames, sampleRate: sampleRate,
                             minEnv: minEnv, maxEnv: maxEnv)
        cache[url] = peaks
        return peaks
    }

    static func clearCache() {
        cache.removeAll()
    }
}
