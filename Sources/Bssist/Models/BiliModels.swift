import Foundation
import Darwin

struct BiliPage: Identifiable, Hashable, Codable {
    var id: Int { cid }
    let cid: Int
    let page: Int
    let part: String
    let duration: Int
}

struct BiliVideoInfo: Identifiable, Equatable {
    var id: String { bvid }
    let bvid: String
    let aid: Int
    let title: String
    let coverURL: URL?
    let ownerName: String
    let duration: Int
    let pages: [BiliPage]
    var defaultPageIndex: Int = 0
}

struct BiliDashStream: Equatable {
    let id: Int
    let baseURL: URL
    let backupURLs: [URL]
    let codecs: String
    let bandwidth: Int
    let codecid: Int
}

struct BiliQualityOption: Identifiable, Equatable, Hashable {
    let id: String
    let qn: Int
    let label: String
    let videoStream: BiliDashStream?
    let audioStream: BiliDashStream?
    let directMP4URL: URL?
    let isAudioOnly: Bool
    var requiresAuth: Bool = false

    static func == (lhs: BiliQualityOption, rhs: BiliQualityOption) -> Bool {
        lhs.id == rhs.id && lhs.requiresAuth == rhs.requiresAuth
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(requiresAuth)
    }
}

enum TaskStatus: Equatable {
    case queued
    case downloading(progress: Double, speedBps: Double)
    case paused(progress: Double)
    case muxing
    case completed(URL)
    case failed(String)

    var isRunning: Bool {
        if case .downloading = self { return true }
        if case .muxing = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var currentProgress: Double {
        switch self {
        case .downloading(let p, _): return p
        case .paused(let p): return p
        case .muxing, .completed: return 1.0
        default: return 0.0
        }
    }
}

final class SegmentCheckpointStore: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var completedSegmentsByFile: [String: Set<Int>] = [:]
    private var knownTotalBytesByFile: [String: Int64] = [:]

    func knownTotalBytes(for key: String) -> Int64? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return knownTotalBytesByFile[key]
    }

    func setKnownTotalBytes(_ bytes: Int64, for key: String) {
        os_unfair_lock_lock(&lock)
        knownTotalBytesByFile[key] = bytes
        os_unfair_lock_unlock(&lock)
    }

    func isSegmentCompleted(_ index: Int, for key: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return completedSegmentsByFile[key]?.contains(index) ?? false
    }

    func markSegmentCompleted(_ index: Int, for key: String) {
        os_unfair_lock_lock(&lock)
        completedSegmentsByFile[key, default: []].insert(index)
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        completedSegmentsByFile.removeAll()
        knownTotalBytesByFile.removeAll()
        os_unfair_lock_unlock(&lock)
    }
}

@MainActor
final class DownloadTaskItem: Identifiable, ObservableObject {
    let id = UUID()
    let bvid: String
    let cid: Int
    let title: String
    let pageTitle: String?
    let coverURL: URL?
    let quality: BiliQualityOption
    let destinationDirectory: URL
    let checkpointStore = SegmentCheckpointStore()

    @Published var status: TaskStatus = .queued
    var activeTask: Task<Void, Never>?

    var tempDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Bssist-\(id.uuidString)", isDirectory: true)
    }

    init(
        bvid: String,
        cid: Int,
        title: String,
        pageTitle: String?,
        coverURL: URL?,
        quality: BiliQualityOption,
        destinationDirectory: URL
    ) {
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.pageTitle = pageTitle
        self.coverURL = coverURL
        self.quality = quality
        self.destinationDirectory = destinationDirectory
    }

    var displayTitle: String {
        if let pageTitle, !pageTitle.isEmpty, pageTitle != title {
            return "\(title) · \(pageTitle)"
        }
        return title
    }
}
