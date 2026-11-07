import SwiftUI
import CoreImage.CIFilterBuiltins

struct AuthPopoverView: View {
    @Binding var sessdata: String
    var accountInfo: BiliAccountInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: NSImage?
    @State private var qrKey: String?
    @State private var qrStatusText: String = "请使用哔哩哔哩 App 扫码登录"
    @State private var isLoading = false
    @State private var pollTask: Task<Void, Never>?
    @State private var manualCookieInput = ""
    @State private var showManualInput = false

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        VStack(spacing: 12) {
            if !sessdata.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.primary)

                    HStack(spacing: 5) {
                        Text(accountInfo?.uname ?? "已登录")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if accountInfo?.isVIP == true {
                            Text("VIP")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    Button {
                        sessdata = ""
                        UserDefaults.standard.removeObject(forKey: "Bssist.sessdata")
                        startQRFlow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("退出登录")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 176, height: 150)
            } else if showManualInput {
                VStack(spacing: 10) {
                    Text("粘贴 SESSDATA / Cookie")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("SESSDATA", text: $manualCookieInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 8) {
                        Button {
                            showManualInput = false
                            startQRFlow()
                        } label: {
                            Image(systemName: "qrcode")
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
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
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                                .background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 176)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                        .frame(width: 148, height: 148)

                    if let qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(qrStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 14) {
                    Button {
                        startQRFlow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        pollTask?.cancel()
                        showManualInput = true
                    } label: {
                        Image(systemName: "key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
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
        qrStatusText = "请使用哔哩哔哩 App 扫码登录"

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
        return NSImage(cgImage: cgImage, size: NSSize(width: 132, height: 132))
    }
}
