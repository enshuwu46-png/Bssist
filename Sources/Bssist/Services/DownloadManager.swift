import Foundation
import AVFoundation
import AppKit
import Darwin

// MARK: - Lock-Free Progress Tracker

private final class TransferProgressTracker: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var totalExpectedBytes: Int64
    private var completedBytes: Int64
    private var windowBytes: Int64 = 0
    private var lastReportTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var smoothedSpeedBps: Double = 0
    private let onUpdate: @Sendable (Double, Double) -> Void

    init(
        totalExpectedBytes: Int64,
        initialCompletedBytes: Int64 = 0,
        onUpdate: @escaping @Sendable (Double, Double) -> Void
    ) {
        self.totalExpectedBytes = max(1, totalExpectedBytes)
        self.completedBytes = max(0, initialCompletedBytes)
        self.onUpdate = onUpdate
    }

    func addCompletedBaseline(_ bytes: Int64) {
        var fraction: Double = 0
        var speed: Double = 0
        os_unfair_lock_lock(&lock)
        completedBytes += bytes
        fraction = min(1.0, Double(completedBytes) / Double(totalExpectedBytes))
        speed = smoothedSpeedBps
        os_unfair_lock_unlock(&lock)
        onUpdate(fraction, speed)
    }

    func recordChunk(_ count: Int64) {
        var shouldEmit = false
        var fraction: Double = 0
        var speed: Double = 0

        os_unfair_lock_lock(&lock)
        completedBytes += count
        windowBytes += count
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReportTime
        if elapsed >= 0.12 {
            let instantSpeed = Double(windowBytes) / elapsed
            smoothedSpeedBps = smoothedSpeedBps == 0 ? instantSpeed : (smoothedSpeedBps * 0.35 + instantSpeed * 0.65)
            lastReportTime = now
            windowBytes = 0
            fraction = min(1.0, Double(completedBytes) / Double(totalExpectedBytes))
            speed = smoothedSpeedBps
            shouldEmit = true
        }
        os_unfair_lock_unlock(&lock)

        if shouldEmit {
            onUpdate(fraction, speed)
        }
    }
}

// MARK: - High-Throughput URLSession Delegate for POSIX pwrite

private final class RangeSessionDispatcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct TaskHandler {
        let fd: Int32
        var currentOffset: off_t
        let onBytes: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var validStatus: Bool = false
    }

    private var lock = os_unfair_lock_s()
    private var handlers: [Int: TaskHandler] = [:]

    func register(
        task: URLSessionDataTask,
        fd: Int32,
        startOffset: off_t,
        onBytes: @escaping @Sendable (Int64) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        os_unfair_lock_lock(&lock)
        handlers[task.taskIdentifier] = TaskHandler(
            fd: fd,
            currentOffset: startOffset,
            onBytes: onBytes,
            continuation: continuation
        )
        os_unfair_lock_unlock(&lock)
    }

    func cancelAndFail(taskIdentifier: Int) {
        os_unfair_lock_lock(&lock)
        let removed = handlers.removeValue(forKey: taskIdentifier)
        os_unfair_lock_unlock(&lock)
        removed?.continuation.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let isValid = (200...299).contains(status)

        os_unfair_lock_lock(&lock)
        handlers[dataTask.taskIdentifier]?.validStatus = isValid
        os_unfair_lock_unlock(&lock)

        completionHandler(isValid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        os_unfair_lock_lock(&lock)
        guard var handler = handlers[id], handler.validStatus else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let writeOffset = handler.currentOffset
        handler.currentOffset += off_t(data.count)
        handlers[id] = handler
        let fd = handler.fd
        let onBytes = handler.onBytes
        os_unfair_lock_unlock(&lock)

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var writtenTotal = 0
            while remaining > 0 {
                let n = Darwin.pwrite(fd, base.advanced(by: writtenTotal), remaining, writeOffset + off_t(writtenTotal))
                if n <= 0 { break }
                writtenTotal += n
                remaining -= n
            }
        }

        onBytes(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        os_unfair_lock_lock(&lock)
        guard let handler = handlers.removeValue(forKey: id) else {
            os_unfair_lock_unlock(&lock)
            return
        }
        os_unfair_lock_unlock(&lock)

        if let error {
            handler.continuation.resume(throwing: error)
        } else if !handler.validStatus {
            handler.continuation.resume(throwing: URLError(.badServerResponse))
        } else {
            handler.continuation.resume(returning: ())
        }
    }
}

// MARK: - DownloadManager

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var tasks: [DownloadTaskItem] = []
    @Published var downloadDirectory: URL

    private nonisolated let dispatcher: RangeSessionDispatcher
    private nonisolated let highSpeedSession: URLSession

    private init() {
        let disp = RangeSessionDispatcher()
        self.dispatcher = disp

        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 32
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 3600
        self.highSpeedSession = URLSession(configuration: config, delegate: disp, delegateQueue: nil)

        if let savedPath = UserDefaults.standard.string(forKey: "Bssist.downloadDirectory"),
           FileManager.default.fileExists(atPath: savedPath) {
            self.downloadDirectory = URL(fileURLWithPath: savedPath)
        } else {
            self.downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    func selectDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloadDirectory
        if panel.runModal() == .OK, let url = panel.url {
            downloadDirectory = url
            UserDefaults.standard.set(url.path, forKey: "Bssist.downloadDirectory")
        }
    }

    func enqueue(info: BiliVideoInfo, page: BiliPage, quality: BiliQualityOption) {
        let pageTitle: String? = info.pages.count > 1 ? "P\(page.page) \(page.part)" : nil
        let item = DownloadTaskItem(
            bvid: info.bvid,
            cid: page.cid,
            title: info.title,
            pageTitle: pageTitle,
            coverURL: info.coverURL,
            quality: quality,
            destinationDirectory: downloadDirectory
        )
        tasks.insert(item, at: 0)
        startTask(item)
    }

    func pause(_ item: DownloadTaskItem) {
        guard item.status.isRunning || item.status == .queued else { return }
        let progress = item.status.currentProgress
        item.activeTask?.cancel()
        item.activeTask = nil
        item.status = .paused(progress: progress)
    }

    func resume(_ item: DownloadTaskItem) {
        guard case .paused(let progress) = item.status else { return }
        item.status = .downloading(progress: progress, speedBps: 0)
        startTask(item)
    }

    func togglePauseResume(_ item: DownloadTaskItem) {
        if item.status.isPaused {
            resume(item)
        } else if item.status.isRunning || item.status == .queued {
            pause(item)
        }
    }

    func pauseAll() {
        for item in tasks where item.status.isRunning || item.status == .queued {
            pause(item)
        }
    }

    func resumeAll() {
        for item in tasks where item.status.isPaused {
            resume(item)
        }
    }

    func retry(_ item: DownloadTaskItem) {
        item.activeTask?.cancel()
        item.checkpointStore.reset()
        try? FileManager.default.removeItem(at: item.tempDirectoryURL)
        item.status = .queued
        startTask(item)
    }

    func remove(_ item: DownloadTaskItem) {
        item.activeTask?.cancel()
        try? FileManager.default.removeItem(at: item.tempDirectoryURL)
        tasks.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        tasks.removeAll {
            if case .completed = $0.status { return true }
            return false
        }
    }

    private func startTask(_ item: DownloadTaskItem) {
        item.activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outputURL = try await self.performDownload(for: item)
                if !Task.isCancelled {
                    try? FileManager.default.removeItem(at: item.tempDirectoryURL)
                    item.status = .completed(outputURL)
                }
            } catch is CancellationError {
                // Keep temp directory intact when paused so resume continues from checkpoints
            } catch {
                if !Task.isCancelled {
                    item.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func performDownload(for item: DownloadTaskItem) async throws -> URL {
        let fm = FileManager.default
        let tempDir = item.tempDirectoryURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let safeBaseName = sanitizeFileName(item.displayTitle)
        let ext = item.quality.isAudioOnly ? "m4a" : "mp4"
        let finalURL = uniqueOutputURL(directory: item.destinationDirectory, baseName: safeBaseName, ext: ext)
        let bvid = item.bvid
        let checkpoints = item.checkpointStore

        // Case 1: Audio-only
        if item.quality.isAudioOnly, let audioStream = item.quality.audioStream {
            let tempAudio = tempDir.appendingPathComponent("audio.m4a")
            let urls = prioritizeCDNs([audioStream.baseURL] + audioStream.backupURLs)
            let totalSize = try await resolveStreamLength(key: "audio", urls: urls, bvid: bvid, checkpoints: checkpoints)
            let tracker = TransferProgressTracker(totalExpectedBytes: totalSize) { [weak self] progress, speed in
                Task { @MainActor in
                    guard !item.status.isPaused else { return }
                    item.status = .downloading(progress: progress, speedBps: speed)
                    self?.objectWillChange.send()
                }
            }
            try await downloadParallel(
                fileKey: "audio",
                urls: urls,
                bvid: bvid,
                totalBytes: totalSize,
                to: tempAudio,
                checkpoints: checkpoints,
                tracker: tracker
            )
            try fm.moveItem(at: tempAudio, to: finalURL)
            return finalURL
        }

        // Case 2: Direct MP4 (durl fallback)
        if let directURL = item.quality.directMP4URL {
            let tempVideo = tempDir.appendingPathComponent("direct.mp4")
            let urls = [directURL]
            let totalSize = try await resolveStreamLength(key: "direct", urls: urls, bvid: bvid, checkpoints: checkpoints)
            let tracker = TransferProgressTracker(totalExpectedBytes: totalSize) { [weak self] progress, speed in
                Task { @MainActor in
                    guard !item.status.isPaused else { return }
                    item.status = .downloading(progress: progress, speedBps: speed)
                    self?.objectWillChange.send()
                }
            }
            try await downloadParallel(
                fileKey: "direct",
                urls: urls,
                bvid: bvid,
                totalBytes: totalSize,
                to: tempVideo,
                checkpoints: checkpoints,
                tracker: tracker
            )
            try fm.moveItem(at: tempVideo, to: finalURL)
            return finalURL
        }

        // Case 3: DASH Video + Audio downloaded SIMULTANEOUSLY via multi-connection Range striping
        guard let videoStream = item.quality.videoStream else {
            throw BiliError.streamUnavailable("Missing video stream")
        }

        let tempVideo = tempDir.appendingPathComponent("video.mp4")
        let videoURLs = prioritizeCDNs([videoStream.baseURL] + videoStream.backupURLs)

        if let audioStream = item.quality.audioStream {
            let tempAudio = tempDir.appendingPathComponent("audio.m4a")
            let audioURLs = prioritizeCDNs([audioStream.baseURL] + audioStream.backupURLs)

            async let vLength = resolveStreamLength(key: "video", urls: videoURLs, bvid: bvid, checkpoints: checkpoints)
            async let aLength = resolveStreamLength(key: "audio", urls: audioURLs, bvid: bvid, checkpoints: checkpoints)
            let (videoBytes, audioBytes) = try await (vLength, aLength)

            let tracker = TransferProgressTracker(totalExpectedBytes: videoBytes + audioBytes) { [weak self] progress, speed in
                Task { @MainActor in
                    guard !item.status.isPaused else { return }
                    item.status = .downloading(progress: progress, speedBps: speed)
                    self?.objectWillChange.send()
                }
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.downloadParallel(
                        fileKey: "video",
                        urls: videoURLs,
                        bvid: bvid,
                        totalBytes: videoBytes,
                        to: tempVideo,
                        checkpoints: checkpoints,
                        tracker: tracker
                    )
                }
                group.addTask {
                    try await self.downloadParallel(
                        fileKey: "audio",
                        urls: audioURLs,
                        bvid: bvid,
                        totalBytes: audioBytes,
                        to: tempAudio,
                        checkpoints: checkpoints,
                        tracker: tracker
                    )
                }
                try await group.waitForAll()
            }

            item.status = .muxing
            try await muxVideoAndAudio(videoURL: tempVideo, audioURL: tempAudio, outputURL: finalURL)
            return finalURL
        } else {
            let videoBytes = try await resolveStreamLength(key: "video", urls: videoURLs, bvid: bvid, checkpoints: checkpoints)
            let tracker = TransferProgressTracker(totalExpectedBytes: videoBytes) { [weak self] progress, speed in
                Task { @MainActor in
                    guard !item.status.isPaused else { return }
                    item.status = .downloading(progress: progress, speedBps: speed)
                    self?.objectWillChange.send()
                }
            }
            try await downloadParallel(
                fileKey: "video",
                urls: videoURLs,
                bvid: bvid,
                totalBytes: videoBytes,
                to: tempVideo,
                checkpoints: checkpoints,
                tracker: tracker
            )
            try fm.moveItem(at: tempVideo, to: finalURL)
            return finalURL
        }
    }

    // MARK: - CDN Prioritization & Parallel Range Engine

    private nonisolated func prioritizeCDNs(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            cdnScore(for: lhs) < cdnScore(for: rhs)
        }
    }

    private nonisolated func cdnScore(for url: URL) -> Int {
        let host = (url.host ?? "").lowercased()
        if host.hasPrefix("upos-") { return 0 }
        if host.contains("mcdn.bilivideo") || host.contains("szbdyd.com") { return 2 }
        return 1
    }

    private nonisolated func resolveStreamLength(
        key: String,
        urls: [URL],
        bvid: String,
        checkpoints: SegmentCheckpointStore
    ) async throws -> Int64 {
        if let cached = checkpoints.knownTotalBytes(for: key), cached > 0 {
            return cached
        }
        let probed = try await probeStreamLength(urls: urls, bvid: bvid)
        checkpoints.setKnownTotalBytes(probed, for: key)
        return probed
    }

    private nonisolated func probeStreamLength(urls: [URL], bvid: String) async throws -> Int64 {
        var lastError: Error = URLError(.badServerResponse)
        for url in urls {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("https://www.bilibili.com/video/\(bvid)", forHTTPHeaderField: "Referer")
                request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
                request.setValue(BiliAPIService.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

                let (_, response) = try await highSpeedSession.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }

                if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let slashIdx = contentRange.lastIndex(of: "/"),
                   let total = Int64(contentRange[contentRange.index(after: slashIdx)...].trimmingCharacters(in: .whitespaces)),
                   total > 0 {
                    return total
                }

                if response.expectedContentLength > 1 {
                    return response.expectedContentLength
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated func downloadParallel(
        fileKey: String,
        urls: [URL],
        bvid: String,
        totalBytes: Int64,
        to destination: URL,
        checkpoints: SegmentCheckpointStore,
        tracker: TransferProgressTracker
    ) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        // Open without O_TRUNC so paused files retain already-written segments
        let fd = Darwin.open(destination.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(fd) }

        if totalBytes > 0 {
            var st = stat()
            if fstat(fd, &st) == 0, st.st_size != off_t(totalBytes) {
                _ = Darwin.ftruncate(fd, off_t(totalBytes))
            }
        }

        let segmentSize: Int64 = 2 * 1024 * 1024
        var pendingSegments: [(index: Int, start: Int64, end: Int64)] = []
        var alreadyCompletedBytes: Int64 = 0
        var offset: Int64 = 0
        var idx = 0

        while offset < totalBytes {
            let end = min(totalBytes - 1, offset + segmentSize - 1)
            let segLen = end - offset + 1
            if checkpoints.isSegmentCompleted(idx, for: fileKey) {
                alreadyCompletedBytes += segLen
            } else {
                pendingSegments.append((idx, offset, end))
            }
            offset = end + 1
            idx += 1
        }

        if alreadyCompletedBytes > 0 {
            tracker.addCompletedBaseline(alreadyCompletedBytes)
        }

        if pendingSegments.isEmpty {
            if totalBytes <= 0 {
                try await downloadSegment(
                    urls: urls,
                    preferredIndex: 0,
                    bvid: bvid,
                    fd: fd,
                    range: nil,
                    tracker: tracker
                )
            }
            return
        }

        let maxConcurrency = min(10, pendingSegments.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIdx = 0

            for _ in 0..<maxConcurrency {
                let seg = pendingSegments[nextIdx]
                nextIdx += 1
                group.addTask {
                    try await self.downloadSegment(
                        urls: urls,
                        preferredIndex: seg.index,
                        bvid: bvid,
                        fd: fd,
                        range: (seg.start, seg.end),
                        tracker: tracker
                    )
                    checkpoints.markSegmentCompleted(seg.index, for: fileKey)
                }
            }

            while try await group.next() != nil {
                if nextIdx < pendingSegments.count {
                    let seg = pendingSegments[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        try await self.downloadSegment(
                            urls: urls,
                            preferredIndex: seg.index,
                            bvid: bvid,
                            fd: fd,
                            range: (seg.start, seg.end),
                            tracker: tracker
                        )
                        checkpoints.markSegmentCompleted(seg.index, for: fileKey)
                    }
                }
            }
        }
    }

    private nonisolated func downloadSegment(
        urls: [URL],
        preferredIndex: Int,
        bvid: String,
        fd: Int32,
        range: (start: Int64, end: Int64)?,
        tracker: TransferProgressTracker
    ) async throws {
        var lastError: Error = URLError(.badServerResponse)
        let count = urls.count

        for attempt in 0..<(count * 2) {
            try Task.checkCancellation()
            let url = urls[(preferredIndex + attempt) % count]

            do {
                try await performRangeRequest(
                    url: url,
                    bvid: bvid,
                    fd: fd,
                    range: range
                ) { chunkBytes in
                    tracker.recordChunk(chunkBytes)
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated func performRangeRequest(
        url: URL,
        bvid: String,
        fd: Int32,
        range: (start: Int64, end: Int64)?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com/video/\(bvid)", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(BiliAPIService.userAgent, forHTTPHeaderField: "User-Agent")
        if let range {
            request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        }

        let startOffset = off_t(range?.start ?? 0)
        let task = highSpeedSession.dataTask(with: request)
        let taskID = task.taskIdentifier

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                dispatcher.register(
                    task: task,
                    fd: fd,
                    startOffset: startOffset,
                    onBytes: onBytes,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            task.cancel()
            dispatcher.cancelAndFail(taskIdentifier: taskID)
        }
    }

    // MARK: - Native AVFoundation Passthrough Muxer (with optional ffmpeg fallback)

    private nonisolated func muxVideoAndAudio(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        do {
            try await muxWithAVFoundation(videoURL: videoURL, audioURL: audioURL, outputURL: outputURL)
        } catch {
            if let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                try muxWithFFmpeg(ffmpegPath: ffmpegPath, videoURL: videoURL, audioURL: audioURL, outputURL: outputURL)
            } else {
                throw error
            }
        }
    }

    private nonisolated func muxWithAVFoundation(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        patchHEVCTagIfNeeded(at: videoURL)

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first,
              let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BiliError.streamUnavailable("Invalid video track")
        }

        let videoDuration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideoTrack, at: .zero)

        if let sourceAudioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = (try? await audioAsset.load(.duration)) ?? videoDuration
            let muxDuration = CMTimeMinimum(videoDuration, audioDuration)
            try? compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: muxDuration), of: sourceAudioTrack, at: .zero)
        }

        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw BiliError.streamUnavailable("Export session unavailable")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        await exportSession.export()

        if let error = exportSession.error {
            throw error
        }
        guard exportSession.status == .completed else {
            throw BiliError.streamUnavailable("Mux failed (\(exportSession.status.rawValue))")
        }
    }

    /// Patches `hev1` sample entry fourCC to `hvc1` in the fMP4 header (`moov/trak/mdia/minf/stbl/stsd`)
    /// so macOS `AVFoundation` natively muxes 8K / 4K / HDR / 1080P60 HEVC streams without re-encoding.
    private nonisolated func patchHEVCTagIfNeeded(at fileURL: URL) {
        let fd = Darwin.open(fileURL.path, O_RDWR)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        let headerLimit = 65536
        var buffer = [UInt8](repeating: 0, count: headerLimit)
        let bytesRead = Darwin.pread(fd, &buffer, headerLimit, 0)
        guard bytesRead > 16 else { return }

        let target: [UInt8] = [0x68, 0x65, 0x76, 0x31] // "hev1"
        let replacement: [UInt8] = [0x68, 0x76, 0x63, 0x31] // "hvc1"

        for i in 0..<(bytesRead - 4) {
            if buffer[i] == target[0] &&
               buffer[i + 1] == target[1] &&
               buffer[i + 2] == target[2] &&
               buffer[i + 3] == target[3] {
                _ = Darwin.pwrite(fd, replacement, 4, off_t(i))
            }
        }
    }

    private nonisolated func muxWithFFmpeg(ffmpegPath: String, videoURL: URL, audioURL: URL, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-i", videoURL.path,
            "-i", audioURL.path,
            "-c", "copy",
            "-movflags", "+faststart",
            outputURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw BiliError.streamUnavailable("FFmpeg mux exited with \(process.terminationStatus)")
        }
    }

    // MARK: - Aggregate Metrics

    var totalSpeedBps: Double {
        tasks.reduce(0.0) { acc, item in
            if case .downloading(_, let speed) = item.status {
                return acc + speed
            }
            return acc
        }
    }

    var activeCount: Int {
        tasks.filter { $0.status.isRunning || $0.status == .queued }.count
    }

    var pausedCount: Int {
        tasks.filter { $0.status.isPaused }.count
    }

    // MARK: - Helpers

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Bssist_Video" : String(cleaned.prefix(120))
    }

    private func uniqueOutputURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var index = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(index)).\(ext)")
            index += 1
        }
        return candidate
    }
}
