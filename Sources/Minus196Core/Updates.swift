import Foundation

public enum AppInfo {
    /// The app's version. make-app.sh reads this line for the bundle's version.
    public static let version = "0.2"
    public static let repository = "primeyeat/minus196"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    public static let newIssuePage = URL(string: "https://github.com/\(repository)/issues/new")!
}

/// A newer version of the app, found on the project's releases page.
public struct AvailableUpdate: Equatable {
    public let version: String
    /// The disk image to download, or the release's page when it has none.
    public let download: URL
}

/// Looks at the project's public releases for a newer app. App releases are tagged "v<version>"
/// (v0.2, v1.0.3); other tags, such as the engine's, are ignored. Nothing about this Mac or its
/// user is sent: it is one plain request for a public list.
public struct UpdateChecker {
    public init() {}

    static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            out.append(n)
        }
        return out
    }

    /// True when `a` is a later version than `b` ("0.10" is later than "0.9"; "1.0" equals "1").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = numbers(a), let y = numbers(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Picks the newest published app release out of GitHub's release list.
    public static func newest(inReleaseList data: Data, newerThan current: String) -> AvailableUpdate? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: AvailableUpdate?
        for release in list {
            guard release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                  let tag = release["tag_name"] as? String, tag.hasPrefix("v") else { continue }
            let version = String(tag.dropFirst())
            guard isNewer(version, than: best?.version ?? current) else { continue }
            // Only addresses on the project's own release pages are ever opened.
            let prefix = "https://github.com/\(AppInfo.repository)/releases/"
            let assets = release["assets"] as? [[String: Any]] ?? []
            let image = assets.compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasPrefix(prefix) && $0.lowercased().hasSuffix(".dmg") }
            let page = (release["html_url"] as? String).flatMap { $0.hasPrefix(prefix) ? $0 : nil }
            guard let address = image ?? page, let url = URL(string: address) else { continue }
            best = AvailableUpdate(version: version, download: url)
        }
        return best
    }

    /// Asks GitHub. Calls back with nil when there is nothing newer or the check could not be made.
    public func check(current: String = AppInfo.version, completion: @escaping (AvailableUpdate?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases?per_page=30")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("minus196", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let data, data.count < 4_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else { return completion(nil) }
            completion(Self.newest(inReleaseList: data, newerThan: current))
        }.resume()
    }
}
