import Foundation

/// Where -196 keeps engines, backends, bottles and rules.
/// Override the root with the MINUS196_HOME environment variable (used by tests).
public struct Paths {
    public let root: URL

    public init(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
        } else if let override = environment["MINUS196_HOME"], !override.isEmpty {
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("minus196", isDirectory: true)
        }
    }

    public var engines: URL { root.appendingPathComponent("engines", isDirectory: true) }
    public var backends: URL { root.appendingPathComponent("backends", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("bottles", isDirectory: true) }
    public var rulesFile: URL { root.appendingPathComponent("rules.json") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }

    public func bottle(_ name: String) -> URL { bottles.appendingPathComponent(name, isDirectory: true) }

    public func ensureLayout() throws {
        for dir in [root, engines, backends, bottles] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum Minus196Error: Error, CustomStringConvertible, Equatable {
    case invalidName(String)
    case bottleExists(String)
    case bottleNotFound(String)
    case engineNotFound(String)
    case engineExists(String)
    case engineInvalid(String, missing: String)
    case noEngine
    case processFailed(String, Int32)
    case badSetting(String)

    public var description: String {
        switch self {
        case .invalidName(let n): return "'\(n)' is not a valid name (use letters, digits, space, - _ .)"
        case .bottleExists(let n): return "bottle '\(n)' already exists"
        case .engineExists(let n): return "there is already an engine folder named '\(n)'; choose another name"
        case .bottleNotFound(let n): return "bottle '\(n)' not found"
        case .engineNotFound(let n): return "engine '\(n)' not found"
        case .engineInvalid(let n, let missing): return "engine '\(n)' is not a usable Wine install: missing \(missing)"
        case .noEngine: return "no Wine engine is installed; add one with 'minus196 engine add <path>'"
        case .processFailed(let what, let code): return "\(what) failed with exit code \(code)"
        case .badSetting(let s): return "cannot apply setting '\(s)'"
        }
    }
}
