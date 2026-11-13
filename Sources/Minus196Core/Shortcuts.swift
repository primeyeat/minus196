import Foundation

/// Something a bottle's installers left behind for the user to start: a Start Menu or Desktop
/// shortcut (.lnk) or an internet shortcut with a program-defined address (.url, e.g. steam://).
public struct Shortcut: Equatable, Identifiable {
    public let name: String
    /// What to hand to `Launcher.run`: the shortcut file's Unix path, or the address itself.
    public let target: String
    /// A Windows icon file (.ico) for it, as a Unix path, when the shortcut names one.
    public var iconPath: String? = nil
    public var id: String { name.lowercased() }
}

public struct ShortcutScanner {
    private let fm = FileManager.default
    public init() {}

    /// Folders searched, most specific first; the first shortcut of a given name wins.
    static func folders(in prefix: URL) -> [URL] {
        let c = prefix.appendingPathComponent("drive_c", isDirectory: true)
        var out: [URL] = []
        let users = c.appendingPathComponent("users", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).sorted()
        for user in names where user != "Public" && !user.hasPrefix(".") {
            out.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu"))
        }
        out.append(c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu"))
        for user in names where !user.hasPrefix(".") { out.append(users.appendingPathComponent("\(user)/Desktop")) }
        return out
    }

    /// The address inside an internet shortcut, unless it is an ordinary web page.
    static func programAddress(inURLFile text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("url=") else { continue }
            let address = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let lower = address.lowercased()
            // Only "scheme://…" addresses (steam://rungameid/…) are programs; web pages and
            // anything that is really a file path are not.
            guard let colon = lower.range(of: "://"), !lower[..<colon.lowerBound].isEmpty,
                  lower[..<colon.lowerBound].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
                  !["http", "https", "file"].contains(String(lower[..<colon.lowerBound])) else { return nil }
            return address
        }
        return nil
    }

    /// The icon an internet shortcut names ("IconFile=C:\\dir\\game.ico"), as a path in the prefix.
    static func iconPath(inURLFile text: String, prefix: URL) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("iconfile=") else { continue }
            let windows = String(trimmed.dropFirst(9))
            guard windows.count > 3, windows.lowercased().hasPrefix("c:\\") else { return nil }
            let relative = windows.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
            let c = prefix.appendingPathComponent("drive_c").standardizedFileURL
            let url = c.appendingPathComponent(relative).standardizedFileURL
            // "C:\..\.." must not reach files outside the bottle.
            guard url.path.hasPrefix(c.path + "/") else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        return nil
    }

    static func isNoise(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["uninstall", "deinstall", "readme", "read me", "license", "website", "support"].contains { lower.contains($0) }
    }

    public func scan(prefix: URL) -> [Shortcut] {
        var seen = Set<String>()
        var out: [Shortcut] = []
        for folder in Self.folders(in: prefix) {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            var found: [URL] = []
            for case let url as URL in walker { found.append(url) }
            for url in found.sorted(by: { $0.path < $1.path }) {
                let ext = url.pathExtension.lowercased()
                let name = url.deletingPathExtension().lastPathComponent
                guard ext == "lnk" || ext == "url", !Self.isNoise(name), !seen.contains(name.lowercased()) else { continue }
                var target = url.path
                var icon: String?
                if ext == "url" {
                    // A shortcut is a small text file; skip links, pipes and anything large.
                    guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                          attributes[.type] as? FileAttributeType == .typeRegular,
                          (attributes[.size] as? Int ?? .max) <= 65536,
                          let data = try? Data(contentsOf: url) else { continue }
                    let text = String(decoding: data, as: UTF8.self)
                    guard let address = Self.programAddress(inURLFile: text) else { continue }
                    target = address
                    icon = Self.iconPath(inURLFile: text, prefix: prefix)
                }
                seen.insert(name.lowercased())
                out.append(Shortcut(name: name, target: target, iconPath: icon))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension Bottle {
    /// True while the bottle's wineserver is up. Wine keeps its socket in
    /// /tmp/.wine-<uid>/server-<device>-<inode>/ (hex, taken from the prefix folder) and removes
    /// it on a clean exit; after a crash this can report a bottle as running until the next start.
    public var isRunning: Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let dir = "/tmp/.wine-\(getuid())/server-\(String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))"
        return FileManager.default.fileExists(atPath: dir + "/socket")
    }
}
