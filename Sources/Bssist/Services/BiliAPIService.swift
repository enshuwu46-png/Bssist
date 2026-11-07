import Foundation

enum BiliError: LocalizedError {
    case invalidInput
    case videoNotFound(String)
    case streamUnavailable(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid URL / BV"
        case .videoNotFound(let msg):
            return msg.isEmpty ? "Not Found" : msg
        case .streamUnavailable(let msg):
            return msg.isEmpty ? "Stream Unavailable" : msg
        case .networkError(let err):
            return err.localizedDescription
        }
    }
}

struct QRLoginSession {
    let url: String
    let qrcodeKey: String
}

struct BiliAccountInfo: Equatable {
    let uname: String
    let isVIP: Bool
}

enum QRPollResult {
    case waiting
    case scanned
    case expired
    case success(sessdata: String)
}

final class BiliAPIService {
    static let shared = BiliAPIService()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    private let qualityLabels: [Int: String] = [
        127: "8K",
        126: "Dolby",
        125: "HDR",
        120: "4K",
        116: "1080P60",
        112: "1080P+",
        80: "1080P",
        74: "720P60",
        64: "720P",
        32: "480P",
        16: "360P"
    ]

    private var cachedBuvid3: String?
    private var cachedBuvid4: String?

    // MARK: - Cookie & Buvid3 Fingerprint Construction

    func buildCookieHeader(sessdata: String?) async -> String {
        await ensureBuvid()

        var parts: [String] = [
            "CURRENT_FNVAL=4048",
            "CURRENT_QUALITY=127"
        ]

        if let b3 = cachedBuvid3, !b3.isEmpty {
            parts.append("buvid3=\(b3)")
        }
        if let b4 = cachedBuvid4, !b4.isEmpty {
            parts.append("buvid4=\(b4)")
        }

        if let raw = sessdata?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if raw.contains("SESSDATA=") {
                parts.append(raw)
            } else {
                // Ensure commas inside SESSDATA are percent-encoded (%2C) so HTTP Cookie header stays valid
                let encoded = raw.replacingOccurrences(of: ",", with: "%2C")
                parts.append("SESSDATA=\(encoded)")
            }
        }

        return parts.joined(separator: "; ")
    }

    private func ensureBuvid() async {
        if cachedBuvid3 != nil { return }
        if let savedB3 = UserDefaults.standard.string(forKey: "Bssist.buvid3"), !savedB3.isEmpty {
            cachedBuvid3 = savedB3
            cachedBuvid4 = UserDefaults.standard.string(forKey: "Bssist.buvid4")
            return
        }

        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let b3 = dataObj["b_3"] as? String {
                let b4 = dataObj["b_4"] as? String ?? ""
                cachedBuvid3 = b3
                cachedBuvid4 = b4
                UserDefaults.standard.set(b3, forKey: "Bssist.buvid3")
                UserDefaults.standard.set(b4, forKey: "Bssist.buvid4")
            }
        } catch {
            let fallback = UUID().uuidString + "infoc"
            cachedBuvid3 = fallback
        }
    }

    // MARK: - Input Resolution

    func resolveVideoInfo(from rawInput: String, sessdata: String?) async throws -> BiliVideoInfo {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BiliError.invalidInput }

        var workingText = trimmed

        if let shortURL = extractShortURL(from: workingText) {
            if let expanded = try? await resolveRedirect(url: shortURL) {
                workingText = expanded.absoluteString
            }
        }

        let pageNumber = extractPageNumber(from: workingText)

        if let bvid = extractBVID(from: workingText) {
            return try await fetchVideoInfo(queryItems: [URLQueryItem(name: "bvid", value: bvid)], pageNumber: pageNumber, sessdata: sessdata)
        } else if let aid = extractAID(from: workingText) {
            return try await fetchVideoInfo(queryItems: [URLQueryItem(name: "aid", value: aid)], pageNumber: pageNumber, sessdata: sessdata)
        } else {
            throw BiliError.invalidInput
        }
    }

    private func extractShortURL(from text: String) -> URL? {
        let pattern = #"https?://b23\.tv/[A-Za-z0-9_-]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    private func resolveRedirect(url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url ?? url
    }

    private func extractBVID(from text: String) -> String? {
        let pattern = #"BV[0-9A-Za-z]{10}"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let matched = String(text[range])
        return "BV" + matched.dropFirst(2)
    }

    private func extractAID(from text: String) -> String? {
        let pattern = #"(?:av|aid=)(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func extractPageNumber(from text: String) -> Int {
        let pattern = #"[?&]p=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let p = Int(text[range]), p >= 1 else {
            return 1
        }
        return p
    }

    // MARK: - Video Metadata

    private func fetchVideoInfo(queryItems: [URLQueryItem], pageNumber: Int, sessdata: String?) async throws -> BiliVideoInfo {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
        components.queryItems = queryItems
        guard let url = components.url else { throw BiliError.invalidInput }

        let cookieHeader = await buildCookieHeader(sessdata: sessdata)
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BiliError.videoNotFound("Invalid response")
        }

        let code = json["code"] as? Int ?? -1
        guard code == 0, let dataObj = json["data"] as? [String: Any] else {
            let message = json["message"] as? String ?? "Video unavailable"
            throw BiliError.videoNotFound(message)
        }

        let bvid = dataObj["bvid"] as? String ?? ""
        let aid = dataObj["aid"] as? Int ?? 0
        let title = dataObj["title"] as? String ?? bvid
        let pic = (dataObj["pic"] as? String)?.replacingOccurrences(of: "http://", with: "https://")
        let coverURL = pic.flatMap(URL.init(string:))
        let duration = dataObj["duration"] as? Int ?? 0
        let ownerObj = dataObj["owner"] as? [String: Any]
        let ownerName = ownerObj?["name"] as? String ?? ""

        var pages: [BiliPage] = []
        if let pagesArr = dataObj["pages"] as? [[String: Any]] {
            for item in pagesArr {
                if let cid = item["cid"] as? Int {
                    let page = item["page"] as? Int ?? 1
                    let part = item["part"] as? String ?? "P\(page)"
                    let dur = item["duration"] as? Int ?? duration
                    pages.append(BiliPage(cid: cid, page: page, part: part, duration: dur))
                }
            }
        }

        if pages.isEmpty, let cid = dataObj["cid"] as? Int {
            pages.append(BiliPage(cid: cid, page: 1, part: title, duration: duration))
        }

        let defaultIndex = max(0, min(pages.count - 1, pageNumber - 1))

        return BiliVideoInfo(
            bvid: bvid,
            aid: aid,
            title: title,
            coverURL: coverURL,
            ownerName: ownerName,
            duration: duration,
            pages: pages,
            defaultPageIndex: defaultIndex
        )
    }

    // MARK: - Stream Resolution (Up to 8K qn=127, Dolby Vision, HDR, 4K, 1080P60)

    func fetchQualityOptions(bvid: String, cid: Int, sessdata: String?) async throws -> [BiliQualityOption] {
        let cookieHeader = await buildCookieHeader(sessdata: sessdata)
        let isGuest = (sessdata == nil || sessdata?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)

        var rawParams: [String: String] = [
            "bvid": bvid,
            "cid": String(cid),
            "qn": "127",
            "fnver": "0",
            "fnval": "4048",
            "fourk": "1",
            "voice_balance": "1",
            "gaia_source": "pre-load",
            "isGaiaAvoided": "true",
            "web_location": "1315873"
        ]

        // Only pass try_look=1 for unauthenticated users (unlocks 1080P for guests; omitting it when logged in allows 4K/8K/1080P60)
        if isGuest {
            rawParams["try_look"] = "1"
        }

        let signedParams = await WbiSigner.shared.sign(params: rawParams, cookieHeader: cookieHeader)
        var components = URLComponents(string: "https://api.bilibili.com/x/player/wbi/playurl")!
        components.queryItems = signedParams.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { throw BiliError.streamUnavailable("Invalid URL") }

        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com/video/\(bvid)", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataObj = json["data"] as? [String: Any] else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "Stream error"
            throw BiliError.streamUnavailable(msg)
        }

        // Parse all formats supported by this video (e.g., 127=8K, 126=Dolby, 125=HDR, 120=4K, 116=1080P60, 80=1080P...)
        var supportedQNs: [Int] = []
        if let supportFormats = dataObj["support_formats"] as? [[String: Any]] {
            for fmt in supportFormats {
                if let q = fmt["quality"] as? Int, !supportedQNs.contains(q) {
                    supportedQNs.append(q)
                }
            }
        } else if let acceptQuality = dataObj["accept_quality"] as? [Int] {
            supportedQNs = acceptQuality
        }

        var options: [BiliQualityOption] = []
        var unlockedQNs = Set<Int>()

        if let dash = dataObj["dash"] as? [String: Any] {
            let bestAudio = parseBestAudioStream(from: dash)

            if let videoArr = dash["video"] as? [[String: Any]] {
                var groupedByQn: [Int: [BiliDashStream]] = [:]
                for v in videoArr {
                    guard let id = v["id"] as? Int,
                          let baseUrlStr = (v["baseUrl"] as? String) ?? (v["base_url"] as? String),
                          let baseURL = URL(string: baseUrlStr) else { continue }
                    let backupStrs = (v["backupUrl"] as? [String]) ?? (v["backup_url"] as? [String]) ?? []
                    let backupURLs = backupStrs.compactMap(URL.init(string:))
                    let codecs = v["codecs"] as? String ?? ""
                    let bandwidth = v["bandwidth"] as? Int ?? 0
                    let codecid = v["codecid"] as? Int ?? 7

                    let stream = BiliDashStream(
                        id: id,
                        baseURL: baseURL,
                        backupURLs: backupURLs,
                        codecs: codecs,
                        bandwidth: bandwidth,
                        codecid: codecid
                    )
                    groupedByQn[id, default: []].append(stream)
                }

                // Combine supportedQNs and returned DASH stream QNs, sorted highest (8K=127) first
                let allQNs = Set(supportedQNs).union(groupedByQn.keys).sorted(by: >)

                for qn in allQNs {
                    let label = qualityLabels[qn] ?? "\(qn)P"
                    if let candidates = groupedByQn[qn], !candidates.isEmpty {
                        let chosen = candidates.sorted { lhs, rhs in
                            let lhsRank = codecPriority(lhs.codecid)
                            let rhsRank = codecPriority(rhs.codecid)
                            if lhsRank != rhsRank { return lhsRank < rhsRank }
                            return lhs.bandwidth > rhs.bandwidth
                        }.first!

                        unlockedQNs.insert(qn)
                        options.append(
                            BiliQualityOption(
                                id: "dash-\(qn)",
                                qn: qn,
                                label: label,
                                videoStream: chosen,
                                audioStream: bestAudio,
                                directMP4URL: nil,
                                isAudioOnly: false,
                                requiresAuth: false
                            )
                        )
                    } else if isGuest {
                        // Video supports this higher tier (e.g. 8K / 4K / 1080P60), surface it as locked so user can click to scan QR
                        options.append(
                            BiliQualityOption(
                                id: "locked-\(qn)",
                                qn: qn,
                                label: label,
                                videoStream: nil,
                                audioStream: nil,
                                directMP4URL: nil,
                                isAudioOnly: false,
                                requiresAuth: true
                            )
                        )
                    }
                }
            }

            if let bestAudio {
                options.append(
                    BiliQualityOption(
                        id: "audio-only",
                        qn: 0,
                        label: "M4A",
                        videoStream: nil,
                        audioStream: bestAudio,
                        directMP4URL: nil,
                        isAudioOnly: true,
                        requiresAuth: false
                    )
                )
            }
        }

        // Fallback to durl (progressive MP4) if DASH is empty
        if unlockedQNs.isEmpty,
           let durls = dataObj["durl"] as? [[String: Any]],
           let first = durls.first,
           let urlStr = first["url"] as? String,
           let mp4URL = URL(string: urlStr) {
            let qn = dataObj["quality"] as? Int ?? 64
            let label = qualityLabels[qn] ?? "MP4"
            options.append(
                BiliQualityOption(
                    id: "mp4-\(qn)",
                    qn: qn,
                    label: label,
                    videoStream: nil,
                    audioStream: nil,
                    directMP4URL: mp4URL,
                    isAudioOnly: false,
                    requiresAuth: false
                )
            )
        }

        if options.isEmpty {
            throw BiliError.streamUnavailable("No playable streams")
        }

        return options
    }

    private func codecPriority(_ codecid: Int) -> Int {
        switch codecid {
        case 7: return 0  // AVC / H.264
        case 12: return 1 // HEVC / H.265 (used by 4K, 8K, HDR, Dolby, 1080P60)
        default: return 2 // AV1
        }
    }

    private func parseBestAudioStream(from dash: [String: Any]) -> BiliDashStream? {
        var candidates: [BiliDashStream] = []

        // Check Dolby & Hi-Res FLAC audio first, then standard DASH audio
        if let dolbyObj = dash["dolby"] as? [String: Any],
           let audioArr = dolbyObj["audio"] as? [[String: Any]] {
            for a in audioArr {
                if let s = parseDashItem(a) { candidates.append(s) }
            }
        }
        if let flacObj = dash["flac"] as? [String: Any],
           let audioObj = flacObj["audio"] as? [String: Any],
           let s = parseDashItem(audioObj) {
            candidates.append(s)
        }
        if let audioArr = dash["audio"] as? [[String: Any]] {
            for a in audioArr {
                if let s = parseDashItem(a) { candidates.append(s) }
            }
        }

        return candidates.sorted { $0.bandwidth > $1.bandwidth }.first
    }

    private func parseDashItem(_ dict: [String: Any]) -> BiliDashStream? {
        guard let id = dict["id"] as? Int,
              let baseUrlStr = (dict["baseUrl"] as? String) ?? (dict["base_url"] as? String),
              let baseURL = URL(string: baseUrlStr) else { return nil }
        let backupStrs = (dict["backupUrl"] as? [String]) ?? (dict["backup_url"] as? [String]) ?? []
        let backupURLs = backupStrs.compactMap(URL.init(string:))
        let codecs = dict["codecs"] as? String ?? ""
        let bandwidth = dict["bandwidth"] as? Int ?? 0
        let codecid = dict["codecid"] as? Int ?? 0
        return BiliDashStream(
            id: id,
            baseURL: baseURL,
            backupURLs: backupURLs,
            codecs: codecs,
            bandwidth: bandwidth,
            codecid: codecid
        )
    }

    // MARK: - Account Verification & QR Code Login

    func fetchAccountInfo(sessdata: String?) async -> BiliAccountInfo? {
        guard let sessdata, !sessdata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            return nil
        }

        let cookieHeader = await buildCookieHeader(sessdata: sessdata)
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let isLogin = dataObj["isLogin"] as? Bool, isLogin else {
                return nil
            }
            let uname = dataObj["uname"] as? String ?? "Bilibili"
            let vipStatus = (dataObj["vipStatus"] as? Int ?? 0) == 1
            return BiliAccountInfo(uname: uname, isVIP: vipStatus)
        } catch {
            return nil
        }
    }

    func generateQRCode() async throws -> QRLoginSession {
        let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let qrUrl = dataObj["url"] as? String,
              let key = dataObj["qrcode_key"] as? String else {
            throw BiliError.networkError(URLError(.badServerResponse))
        }
        return QRLoginSession(url: qrUrl, qrcodeKey: key)
    }

    func pollQRCode(key: String) async throws -> QRPollResult {
        var components = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let code = dataObj["code"] as? Int else {
            return .waiting
        }

        switch code {
        case 0:
            await WbiSigner.shared.invalidateCache()

            // Extract raw query parameters WITHOUT URL-decoding %2C / %2A so SESSDATA stays valid
            if let urlStr = dataObj["url"] as? String,
               let qIndex = urlStr.firstIndex(of: "?") {
                let rawQuery = String(urlStr[urlStr.index(after: qIndex)...])
                let pairs = rawQuery.components(separatedBy: "&")
                let keepKeys: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
                var cookiePairs: [String] = []
                for pair in pairs {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2, keepKeys.contains(kv[0]) {
                        cookiePairs.append("\(kv[0])=\(kv[1])")
                    }
                }
                if !cookiePairs.isEmpty {
                    return .success(sessdata: cookiePairs.joined(separator: "; "))
                }
            }

            if let httpResp = response as? HTTPURLResponse,
               let url = httpResp.url {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: httpResp.allHeaderFields as? [String: String] ?? [:], for: url)
                if let sessCookie = cookies.first(where: { $0.name == "SESSDATA" }) {
                    let encoded = sessCookie.value.replacingOccurrences(of: ",", with: "%2C")
                    return .success(sessdata: "SESSDATA=\(encoded)")
                }
            }
            return .waiting
        case 86090:
            return .scanned
        case 86038:
            return .expired
        default:
            return .waiting
        }
    }
}
