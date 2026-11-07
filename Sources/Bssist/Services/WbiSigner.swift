import Foundation
import CryptoKit

actor WbiSigner {
    static let shared = WbiSigner()

    private let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    private var cachedMixinKey: String?
    private var lastFetchDate: Date?

    func invalidateCache() {
        cachedMixinKey = nil
        lastFetchDate = nil
    }

    func sign(params: [String: String], cookieHeader: String) async -> [String: String] {
        guard let mixinKey = await getMixinKey(cookieHeader: cookieHeader) else {
            return params
        }

        var signedParams = params
        let wts = String(Int(Date().timeIntervalSince1970))
        signedParams["wts"] = wts

        let allowedCharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

        let query = signedParams.keys.sorted().compactMap { key -> String? in
            guard let rawValue = signedParams[key] else { return nil }
            let filtered = rawValue.filter { !"!'()*".contains($0) }
            guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharSet),
                  let encodedVal = filtered.addingPercentEncoding(withAllowedCharacters: allowedCharSet) else {
                return nil
            }
            return "\(encodedKey)=\(encodedVal)"
        }.joined(separator: "&")

        let toHash = query + mixinKey
        let digest = Insecure.MD5.hash(data: Data(toHash.utf8))
        let wRid = digest.map { String(format: "%02x", $0) }.joined()

        signedParams["w_rid"] = wRid
        return signedParams
    }

    private func getMixinKey(cookieHeader: String) async -> String? {
        if let key = cachedMixinKey,
           let last = lastFetchDate,
           Date().timeIntervalSince(last) < 1800 {
            return key
        }

        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(BiliAPIService.userAgent, forHTTPHeaderField: "User-Agent")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let wbiImg = dataObj["wbi_img"] as? [String: Any],
                  let imgUrl = wbiImg["img_url"] as? String,
                  let subUrl = wbiImg["sub_url"] as? String else {
                return nil
            }

            let imgKey = URL(fileURLWithPath: imgUrl).deletingPathExtension().lastPathComponent
            let subKey = URL(fileURLWithPath: subUrl).deletingPathExtension().lastPathComponent
            let rawKey = Array(imgKey + subKey)

            guard rawKey.count >= 64 else { return nil }
            let mixin = String(mixinKeyEncTab.prefix(32).map { rawKey[$0] })
            cachedMixinKey = mixin
            lastFetchDate = Date()
            return mixin
        } catch {
            return nil
        }
    }
}
