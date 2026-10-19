import AVFoundation

/// 裁切导出的第二条路：AVAssetExportSession + Passthrough。
/// 好处是入点帧精确，而且不重编码 —— 代价是它并不真删：入点前那一段还躺在文件里，
/// 只是靠容器里的 edit list 藏起来，所以极少数播放器或编辑器打开时会看见那一段。
enum AVFoundationTrim {
    /// 能落回源扩展名的容器（实测）：这六种裁完还是原来那个容器名，导出名的
    /// `clip_原名_[MM-SS_MM-SS].<源扩展名>` 那条规则不用动。名单外的都交回 ffmpeg ——
    /// mp3 报「Cannot write output file」，flac 更阴：status 写着 completed，
    /// 产物却是 0 条轨的空壳。
    private static let writers: [String: AVFileType] = [
        "wav": .wav, "wave": .wav,
        "aif": .aiff, "aiff": .aiff, "aifc": .aiff,
        "caf": .caf,
        "m4a": .m4a,
        "mp4": .mp4, "m4v": .mp4,
        "mov": .mov,
    ]

    /// 「这一份 AV 裁不了」的记号。裁定：原来那 6 句中文措辞全不要了 ——
    /// 失败结果被路由器整个丢掉、没人看得见，回落 ffmpeg 由调用方另有一句弹窗点名。
    /// domain/code 留着，方便日志和以后真要分档时认得出来。
    private static let unavailable = NSError(domain: "AVFoundationTrimError", code: -1,
                                             userInfo: nil)

    /// 裁一段出去。回调一定在主线程。
    static func exportClip(inputURL: URL,
                           startTime: TimeInterval,
                           endTime: TimeInterval,
                           outputDirectory: URL,
                           completion: @escaping (Result<URL, Error>) -> Void) {
        let ext = inputURL.pathExtension.lowercased()
        guard let fileType = writers[ext] else { completion(.failure(unavailable)); return }
        let asset = AVURLAsset(url: inputURL)
        guard !asset.tracks.isEmpty else { completion(.failure(unavailable)); return }
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            completion(.failure(unavailable)); return
        }
        let outputURL = outputDirectory.appendingPathComponent(
            FFmpegService.clipFileName(inputURL: inputURL, startTime: startTime, endTime: endTime))
        // 导出通道不肯覆盖已有文件（实测：目标已存在时 status=4、报「Cannot Save」）。
        // 同一区间重写一遍就是覆盖，这一点和 ffmpeg 那边的 -y 对齐。
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = fileType
        // 时基给到 1e6：600 一格是 1.667 ms，实测 3.017 s 的入点会被折到 3.016667 s
        // （差 0.333 ms）；这一路的卖点是入点精确，不该被时基自己吃掉一格。
        session.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 1_000_000),
                                        end: CMTime(seconds: endTime, preferredTimescale: 1_000_000))
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status != .completed {
                    completion(.failure(unavailable))
                    return
                }
                // status 说完成不算完成：flac 那一档就是「完成」外加一个空壳。
                guard !AVURLAsset(url: outputURL).tracks.isEmpty else {
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(.failure(unavailable))
                    return
                }
                FFmpegService.playCue()
                completion(.success(outputURL))
            }
        }
    }
}
