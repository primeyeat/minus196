import Foundation

/// Gathers what someone helping with a problem needs to see: versions, this Mac, the bottle's
/// settings and the end of its latest logs. The home folder and the account name are replaced
/// before anything is written, since the report is meant to be shared.
public struct ProblemReport {
    public let paths: Paths
    private let fm = FileManager.default
    public init(paths: Paths = Paths()) { self.paths = paths }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Replaces the home folder with "~" and the account name with "user".
    public static func scrub(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var out = text.replacingOccurrences(of: home, with: "~")
        if user.count >= 3 {
            for separator in ["/", "\\"] {
                out = out.replacingOccurrences(of: "sers\(separator)\(user)", with: "sers\(separator)user", options: .caseInsensitive)
            }
        }
        return out
    }

    static func tail(of file: URL, lines: Int, maxBytes: Int = 200_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "(could not be read)" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    public func text(bottleName: String?, date: Date = Date()) -> String {
        var out: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("-196 problem report")
        out.append("Made: \(ISO8601DateFormatter().string(from: date))")
        out.append("")
        out.append("== This Mac")
        out.append("-196 version: \(AppInfo.version)")
        out.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        out.append("Model: \(Self.sysctlString("hw.model") ?? "?")")
        out.append("Chip: \(Self.sysctlString("machdep.cpu.brand_string") ?? "?")")
        out.append("Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        out.append("Rosetta: \(HostInfo.hasRosetta ? "installed" : "NOT installed")")
        out.append("")
        out.append("== Setup")
        out.append(Doctor(paths: paths).report())
        if let bottleName, let bottle = try? BottleStore(paths: paths).load(bottleName) {
            out.append("")
            out.append("== Bottle \"\(bottle.name)\"")
            out.append((try? String(contentsOf: bottle.configFile, encoding: .utf8)) ?? "(settings could not be read)")
            let names = ((try? fm.contentsOfDirectory(atPath: bottle.logs.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
            out.append("Runs logged: \(names.count)")
            for name in names.suffix(3).reversed() {
                out.append("")
                out.append("== Log \(name) (the end of it)")
                out.append(Self.tail(of: bottle.logs.appendingPathComponent(name), lines: 300))
            }
        }
        return Self.scrub(out.joined(separator: "\n")) + "\n"
    }

    /// Writes the report into `folder` and returns the file.
    public func save(bottleName: String?, to folder: URL, date: Date = Date()) throws -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"; f.locale = Locale(identifier: "en_US_POSIX")
        let file = folder.appendingPathComponent("-196 problem report \(f.string(from: date)).txt")
        try Data(text(bottleName: bottleName, date: date).utf8).write(to: file, options: .atomic)
        return file
    }
}
