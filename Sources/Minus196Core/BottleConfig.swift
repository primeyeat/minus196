import Foundation

public enum WineArch: String, Codable, CaseIterable { case win64, win32 }

public enum BackendChoice: String, Codable, CaseIterable {
    case auto, d3dmetal, dxmt, dxvk, wined3d
}

public struct Program: Codable, Equatable {
    public var name: String
    public var path: String
    public var args: [String]
    public var workingDirectory: String?

    public init(name: String, path: String, args: [String] = [], workingDirectory: String? = nil) {
        self.name = name; self.path = path; self.args = args; self.workingDirectory = workingDirectory
    }
}

/// Settings for one bottle. Stored as bottle.json next to (never inside) the Wine prefix.
public struct BottleConfig: Codable, Equatable {
    public var name: String
    public var engine: String?
    public var arch: WineArch
    public var windowsVersion: String
    public var backend: BackendChoice
    public var msync: Bool
    public var env: [String: String]
    public var dllOverrides: [String: String]
    public var programs: [Program]
    public var created: Date

    public init(name: String, engine: String? = nil, arch: WineArch = .win64, windowsVersion: String = "win10",
                backend: BackendChoice = .auto, msync: Bool = true, env: [String: String] = [:],
                dllOverrides: [String: String] = [:], programs: [Program] = [], created: Date = Date()) {
        self.name = name; self.engine = engine; self.arch = arch; self.windowsVersion = windowsVersion
        self.backend = backend; self.msync = msync; self.env = env; self.dllOverrides = dllOverrides
        self.programs = programs; self.created = created
    }

    /// Apply a "key=value" setting from the command line or UI.
    public mutating func apply(setting: String) throws {
        guard let eq = setting.firstIndex(of: "=") else { throw Minus196Error.badSetting(setting) }
        let key = String(setting[..<eq]); let value = String(setting[setting.index(after: eq)...])
        switch key {
        case "backend":
            guard let b = BackendChoice(rawValue: value) else { throw Minus196Error.badSetting(setting) }
            backend = b
        case "msync":
            guard let b = Self.parseBool(value) else { throw Minus196Error.badSetting(setting) }
            msync = b
        case "winver": windowsVersion = value
        case "engine": engine = value.isEmpty ? nil : value
        default:
            if key.hasPrefix("env.") {
                let name = String(key.dropFirst(4))
                guard Self.isAllowedEnvName(name) else { throw Minus196Error.badSetting(setting) }
                if value.isEmpty { env.removeValue(forKey: name) } else { env[name] = value }
            } else if key.hasPrefix("dll.") {
                let name = String(key.dropFirst(4))
                guard !name.isEmpty else { throw Minus196Error.badSetting(setting) }
                if value.isEmpty { dllOverrides.removeValue(forKey: name) } else { dllOverrides[name] = value }
            } else {
                throw Minus196Error.badSetting(setting)
            }
        }
    }

    /// Variable names a bottle or a rule may set: plain identifiers only (they are printed as
    /// shell exports), and never the ones that choose which Wine runs or inject libraries into it.
    public static func isAllowedEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
              first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) })
        else { return false }
        return !["WINEPREFIX", "WINESERVER", "WINELOADER"].contains(name) && !name.hasPrefix("DYLD_")
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "1", "on", "yes", "true": return true
        case "0", "off", "no", "false": return false
        default: return nil
        }
    }
}
