import SwiftUI
import CoreImage.CIFilterBuiltins

struct AuthPopoverView: View {
    @Binding var sessdata: String
    var accountInfo: BiliAccountInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: NSImage?
    @State private var qrKey: String?
    @State private var qrStatusText: String = "请使用哔哩哔哩客户端扫码登录"
    @State private var isLoading = false
    @State private var pollTask: Task<Void, Never>?
    @State private var manualCookieInput = ""
    @State private var showManualInput = false

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        LiquidGlassGroup(spacing: 12) {
            VStack(spacing: 14) {
                if !sessdata.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            Text(accountInfo?.uname ?? "已登录")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if accountInfo?.isVIP == true {
                                Text("大会员")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }

                        Button {
                            sessdata = ""
                            UserDefaults.standard.removeObject(forKey: "Bssist.sessdata")
                            startQRFlow()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text("退出登录")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .liquidGlassPill(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 186, height: 156)
                } else if showManualInput {
                    VStack(spacing: 10) {
                        Text("粘贴凭据 (SESSDATA)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("在此粘贴 SESSDATA", text: $manualCookieInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                            .liquidGlassSection(cornerRadius: 8)

                        HStack(spacing: 8) {
                            Button {
                                showManualInput = false
                                startQRFlow()
                            } label: {
                                Text("返回扫码")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .liquidGlassPill(cornerRadius: 7)
                            }
                            .buttonStyle(.plain)

                            Button {
                                let cleaned = manualCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !cleaned.isEmpty {
                                    sessdata = cleaned
                                    UserDefaults.standard.set(cleaned, forKey: "Bssist.sessdata")
                                    dismiss()
                                }
                            } label: {
                                Text("确认")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .liquidGlassPill(cornerRadius: 7, isProminent: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 186)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 150, height: 150)

                        if let qrImage {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 134, height: 134)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(qrStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 10) {
                        Button {
                            startQRFlow()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .medium))
                                Text("刷新")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .liquidGlassPill(cornerRadius: 7)
                        }
                        .buttonStyle(.plain)

                        Button {
                            pollTask?.cancel()
                            showManualInput = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key")
                                    .font(.system(size: 10, weight: .medium))
                                Text("凭据")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .liquidGlassPill(cornerRadius: 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            if sessdata.isEmpty && !showManualInput {
                startQRFlow()
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private func startQRFlow() {
        pollTask?.cancel()
        isLoading = true
        qrImage = nil
        qrStatusText = "请使用哔哩哔哩客户端扫码登录"

        pollTask = Task {
            do {
                let session = try await BiliAPIService.shared.generateQRCode()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.qrKey = session.qrcodeKey
                    self.qrImage = makeQRImage(from: session.url)
                    self.isLoading = false
                }

                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_800_000_000)
                    guard !Task.isCancelled else { break }
                    let result = try await BiliAPIService.shared.pollQRCode(key: session.qrcodeKey)
                    switch result {
                    case .success(let cookie):
                        await MainActor.run {
                            self.sessdata = cookie
                            UserDefaults.standard.set(cookie, forKey: "Bssist.sessdata")
                            self.dismiss()
                        }
                        return
                    case .scanned:
                        await MainActor.run {
                            self.qrStatusText = "已扫码 · 请在手机端确认"
                        }
                    case .expired:
                        await MainActor.run {
                            startQRFlow()
                        }
                        return
                    case .waiting:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    private func makeQRImage(from string: String) -> NSImage? {
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 134, height: 134))
    }
}
