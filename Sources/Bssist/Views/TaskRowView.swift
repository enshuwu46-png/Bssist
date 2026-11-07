import SwiftUI
import AppKit

struct TaskRowView: View {
    @ObservedObject var item: DownloadTaskItem
    let onTogglePause: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                statusIndicator

                thumbnailView

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        telemetryLabel

                        Text(item.quality.label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .liquidGlassPill(cornerRadius: 5)
                    }

                    progressTrack
                }

                Divider()
                    .frame(height: 22)
                    .opacity(0.35)

                actionButtons
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(isHovering ? 0.04 : 0.0))
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch item.status {
        case .downloading:
            Circle()
                .fill(Color.primary)
                .frame(width: 7, height: 7)
        case .paused:
            Circle()
                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                .frame(width: 7, height: 7)
        case .queued:
            Circle()
                .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.2)
                .frame(width: 7, height: 7)
        case .muxing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 7, height: 7)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 7, height: 7)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 7, height: 7)
        }
    }

    private var thumbnailView: some View {
        AsyncImage(url: item.coverURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .saturation(0.12)
            default:
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: item.quality.isAudioOnly ? "waveform" : "film")
                            .font(.system(size: 10, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 44, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private var telemetryLabel: some View {
        switch item.status {
        case .queued:
            Text("排队中")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        case .downloading(let progress, let speedBps):
            HStack(spacing: 6) {
                Text(formatSpeed(speedBps))
                Text("·")
                Text(String(format: "%.0f%%", progress * 100))
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
        case .paused(let progress):
            HStack(spacing: 4) {
                Text("已暂停")
                    .font(.system(size: 10.5))
                Text("·")
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        case .muxing:
            Text("合成中")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .completed:
            Text("已完成")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        case .failed(let msg):
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var progressTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary.opacity(item.status.isPaused ? 0.35 : 0.82))
                    .frame(width: max(0, geo.size.width * CGFloat(item.status.currentProgress)))
            }
        }
        .frame(height: 2)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 5) {
            if item.status.isRunning || item.status == .queued || item.status.isPaused {
                Button(action: onTogglePause) {
                    Image(systemName: item.status.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 24)
                        .liquidGlassPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .help(item.status.isPaused ? "继续下载" : "暂停下载")
            }

            if case .completed(let url) = item.status {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .liquidGlassPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }

            if case .failed = item.status {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .liquidGlassPill(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .help("重试下载")
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                    .liquidGlassPill(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .help("移除任务")
        }
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
