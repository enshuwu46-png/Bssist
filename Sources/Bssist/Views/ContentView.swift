import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var urlInput: String = ""
    @State private var sessdata: String = UserDefaults.standard.string(forKey: "Bssist.sessdata") ?? ""
    @State private var accountInfo: BiliAccountInfo?

    @State private var isResolving = false
    @State private var errorMessage: String?

    @State private var currentVideo: BiliVideoInfo?
    @State private var selectedPageIDs: Set<Int> = []
    @State private var qualityOptions: [BiliQualityOption] = []
    @State private var selectedQuality: BiliQualityOption?
    @State private var isLoadingQualities = false

    @State private var showAuthPopover = false

    var body: some View {
        ZStack {
            WindowVisualEffectBackdrop()
                .ignoresSafeArea()

            LiquidGlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    statusHeaderCard
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    inputAndNodeGroupCard
                        .padding(.horizontal, 14)

                    taskGroupCard
                        .padding(.horizontal, 14)

                    bottomStatusBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear {
            verifyAccountStatus()
        }
        .onChange(of: sessdata) { _ in
            verifyAccountStatus()
            refreshCurrentVideoQualities()
        }
    }

    // MARK: - 1. 顶部状态与总控卡片 (Liquid Glass)

    private var statusHeaderCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.88))
                        .frame(width: 36, height: 36)

                    BiliTVIcon(size: 20)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Bssist")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Circle()
                            .fill(Color.primary.opacity(downloadManager.activeCount > 0 ? 0.9 : 0.25))
                            .frame(width: 5.5, height: 5.5)
                    }

                    HStack(spacing: 8) {
                        Text("↓ \(formatSpeed(downloadManager.totalSpeedBps))")
                        if downloadManager.activeCount > 0 || downloadManager.pausedCount > 0 {
                            Text("·")
                            Text("进行中 \(downloadManager.activeCount)/\(downloadManager.tasks.count)")
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !downloadManager.tasks.isEmpty {
                    let hasRunning = downloadManager.activeCount > 0
                    let hasPaused = downloadManager.pausedCount > 0
                    if hasRunning || hasPaused {
                        Button {
                            if hasRunning {
                                downloadManager.pauseAll()
                            } else {
                                downloadManager.resumeAll()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: hasRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: 10, weight: .medium))
                                Text(hasRunning ? "全部暂停" : "全部继续")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .liquidGlassPill(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    downloadManager.selectDownloadDirectory()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                        Text("目录")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .liquidGlassPill(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .help("保存位置：\(downloadManager.downloadDirectory.path)")

                Button {
                    showAuthPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sessdata.isEmpty ? "qrcode" : "person.fill")
                            .font(.system(size: 11, weight: .medium))

                        Text(accountInfo?.uname ?? "账号")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: 72)
                    }
                    .foregroundStyle(sessdata.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .liquidGlassPill(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAuthPopover, arrowEdge: .bottom) {
                    AuthPopoverView(sessdata: $sessdata, accountInfo: accountInfo)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // 未登录提示栏
            if sessdata.isEmpty {
                Divider().opacity(0.35)

                Button {
                    showAuthPopover = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 16)

                        Text("登录哔哩哔哩账号以解锁 1080P60 / 4K / 8K 高清画质")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("扫码登录")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .liquidGlassPill(cornerRadius: 6, isProminent: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .liquidGlassSection(cornerRadius: 14)
    }

    // MARK: - 2. 链接解析与节点选择栏目 (Liquid Glass)

    private var inputAndNodeGroupCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                TextField("输入或粘贴视频链接 / BV号", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit {
                        resolveInput()
                    }

                if !urlInput.isEmpty {
                    Button {
                        urlInput = ""
                        withAnimation(.easeOut(duration: 0.15)) {
                            currentVideo = nil
                            errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空输入")
                }

                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        urlInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        resolveInput()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10, weight: .medium))
                        Text("粘贴")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .liquidGlassPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .help("粘贴剪贴板链接并立即解析")

                Button {
                    resolveInput()
                } label: {
                    Group {
                        if isResolving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("解析")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .liquidGlassPill(cornerRadius: 6, isProminent: !isResolving)
                }
                .buttonStyle(.plain)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            if let error = errorMessage {
                Divider().opacity(0.35)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let video = currentVideo {
                Divider().opacity(0.35)
                resolvedVideoSection(for: video)
            }
        }
        .liquidGlassSection(cornerRadius: 14)
    }

    private func resolvedVideoSection(for video: BiliVideoInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AsyncImage(url: video.coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .saturation(0.12)
                    default:
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if !video.ownerName.isEmpty {
                            Text(video.ownerName).lineLimit(1)
                            Text("·")
                        }
                        Text("时长 \(formatDuration(video.duration))")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    triggerDownload(for: video)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text("下载")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .liquidGlassPill(cornerRadius: 8, isProminent: true)
                }
                .buttonStyle(.plain)
                .disabled(selectedQuality == nil || selectedPageIDs.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.35)

            // 画质选择行
            HStack(spacing: 8) {
                Text("画质")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .leading)

                if isLoadingQualities {
                    ProgressView().controlSize(.mini)
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(qualityOptions) { option in
                                let isSelected = selectedQuality == option
                                Button {
                                    if option.requiresAuth {
                                        showAuthPopover = true
                                    } else {
                                        selectedQuality = option
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if option.requiresAuth {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.tertiary)
                                        } else {
                                            Circle()
                                                .fill(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.3))
                                                .frame(width: 5, height: 5)
                                        }

                                        Text(option.label)
                                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                            .foregroundStyle(
                                                isSelected
                                                    ? Color(nsColor: .windowBackgroundColor)
                                                    : (option.requiresAuth ? .secondary : .primary)
                                            )
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .liquidGlassPill(cornerRadius: 6, isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .help(option.requiresAuth ? "点击扫码登录解锁该画质" : option.label)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 多分集选择行
            if video.pages.count > 1 {
                Divider().opacity(0.35)
                HStack(spacing: 8) {
                    Button {
                        if selectedPageIDs.count == video.pages.count {
                            if let first = video.pages.first {
                                selectedPageIDs = [first.cid]
                            }
                        } else {
                            selectedPageIDs = Set(video.pages.map(\.cid))
                        }
                    } label: {
                        Text(selectedPageIDs.count == video.pages.count ? "全选" : "分集")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("点击全选或取消全选")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(video.pages) { page in
                                let isSelected = selectedPageIDs.contains(page.cid)
                                Button {
                                    if isSelected && selectedPageIDs.count > 1 {
                                        selectedPageIDs.remove(page.cid)
                                    } else {
                                        selectedPageIDs.insert(page.cid)
                                    }
                                } label: {
                                    Text("第\(page.page)集")
                                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : .secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .liquidGlassPill(cornerRadius: 6, isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .help(page.part)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 3. 下载队列栏目 (Liquid Glass)

    private var taskGroupCard: some View {
        ZStack {
            if downloadManager.tasks.isEmpty {
                VStack(spacing: 8) {
                    BiliTVIcon(size: 28)
                        .foregroundStyle(.quaternary)
                    Text("暂无下载任务")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(downloadManager.tasks.enumerated()), id: \.element.id) { index, item in
                            TaskRowView(
                                item: item,
                                onTogglePause: { downloadManager.togglePauseResume(item) },
                                onRetry: { downloadManager.retry(item) },
                                onRemove: { downloadManager.remove(item) }
                            )
                            if index < downloadManager.tasks.count - 1 {
                                Divider()
                                    .padding(.leading, 30)
                                    .opacity(0.3)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassSection(cornerRadius: 14)
    }

    // MARK: - 4. 底部状态栏

    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.primary.opacity(sessdata.isEmpty ? 0.3 : 0.85))
                .frame(width: 5, height: 5)

            if let info = accountInfo {
                Text(info.isVIP ? "已登录：\(info.uname)（大会员）" : "已登录：\(info.uname)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showAuthPopover = true
                } label: {
                    Text("未登录（点击扫码）")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("·")
                .foregroundStyle(.quaternary)

            Text("保存至：\(downloadManager.downloadDirectory.lastPathComponent)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            if downloadManager.tasks.contains(where: {
                if case .completed = $0.status { return true }
                return false
            }) {
                Button {
                    downloadManager.clearCompleted()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 9.5))
                        Text("清理已完成")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .liquidGlassPill(cornerRadius: 5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func verifyAccountStatus() {
        let currentCookie = sessdata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentCookie.isEmpty else {
            accountInfo = nil
            return
        }

        Task {
            if let verified = await BiliAPIService.shared.fetchAccountInfo(sessdata: currentCookie) {
                await MainActor.run {
                    self.accountInfo = verified
                }
            } else {
                await MainActor.run {
                    self.accountInfo = nil
                    self.sessdata = ""
                    UserDefaults.standard.removeObject(forKey: "Bssist.sessdata")
                }
            }
        }
    }

    private func resolveInput() {
        let query = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isResolving = true
        errorMessage = nil

        Task {
            do {
                let info = try await BiliAPIService.shared.resolveVideoInfo(from: query, sessdata: sessdata)
                let defaultPage = info.pages[info.defaultPageIndex]
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.15)) {
                        self.currentVideo = info
                        self.selectedPageIDs = [defaultPage.cid]
                        self.isResolving = false
                        self.isLoadingQualities = true
                    }
                }

                let options = try await BiliAPIService.shared.fetchQualityOptions(
                    bvid: info.bvid,
                    cid: defaultPage.cid,
                    sessdata: sessdata
                )

                await MainActor.run {
                    self.qualityOptions = options
                    self.selectedQuality = options.first(where: { !$0.isAudioOnly && !$0.requiresAuth })
                        ?? options.first(where: { !$0.requiresAuth })
                    self.isLoadingQualities = false
                }
            } catch {
                await MainActor.run {
                    self.isResolving = false
                    self.isLoadingQualities = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshCurrentVideoQualities() {
        guard let info = currentVideo else { return }
        let defaultPage = info.pages[info.defaultPageIndex]
        isLoadingQualities = true
        Task {
            if let options = try? await BiliAPIService.shared.fetchQualityOptions(
                bvid: info.bvid,
                cid: defaultPage.cid,
                sessdata: sessdata
            ) {
                await MainActor.run {
                    self.qualityOptions = options
                    self.selectedQuality = options.first(where: { !$0.isAudioOnly && !$0.requiresAuth })
                        ?? options.first(where: { !$0.requiresAuth })
                    self.isLoadingQualities = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingQualities = false
                }
            }
        }
    }

    private func triggerDownload(for video: BiliVideoInfo) {
        guard let baseQuality = selectedQuality else { return }
        let pagesToDownload = video.pages.filter { selectedPageIDs.contains($0.cid) }
        guard !pagesToDownload.isEmpty else { return }

        let firstPageCid = video.pages[video.defaultPageIndex].cid

        Task {
            for page in pagesToDownload {
                if page.cid == firstPageCid {
                    await MainActor.run {
                        downloadManager.enqueue(info: video, page: page, quality: baseQuality)
                    }
                } else {
                    if let pageOptions = try? await BiliAPIService.shared.fetchQualityOptions(
                        bvid: video.bvid,
                        cid: page.cid,
                        sessdata: sessdata
                    ) {
                        let matched = pageOptions.first(where: { $0.id == baseQuality.id })
                            ?? pageOptions.first(where: { $0.isAudioOnly == baseQuality.isAudioOnly && !$0.requiresAuth })
                            ?? pageOptions.first(where: { !$0.requiresAuth })
                        if let matched {
                            await MainActor.run {
                                downloadManager.enqueue(info: video, page: page, quality: matched)
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.15)) {
                    self.currentVideo = nil
                    self.urlInput = ""
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        if mins >= 60 {
            return String(format: "%d:%02d:%02d", mins / 60, mins % 60, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatSpeed(_ bps: Double) -> String {
        guard bps > 0 else { return "0.0 MB/s" }
        let mb = bps / (1024 * 1024)
        if mb >= 1.0 {
            return String(format: "%.1f MB/s", mb)
        }
        return String(format: "%.0f KB/s", bps / 1024)
    }
}
