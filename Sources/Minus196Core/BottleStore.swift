import Foundation

public struct Bottle: Equatable {
    public var config: BottleConfig
    public let directory: URL

    public var name: String { config.name }
    public var prefix: URL { directory.appendingPathComponent("prefix", isDirectory: true) }
    public var logs: URL { directory.appendingPathComponent("logs", isDirectory: true) }
    public var configFile: URL { directory.appendingPathComponent("bottle.json") }
    /// A prefix is initialised once Wine has written its registry.
    public var isInitialised: Bool { FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) }
}

/// Creates, lists and removes bottle directories. Does not run Wine.
public struct BottleStore {
    public let paths: Paths
    private let fm = FileManager.default

    public init(paths: Paths = Paths()) { self.paths = paths }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name != ".", name != "..", !name.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public func list() throws -> [Bottle] {
        guard fm.fileExists(atPath: paths.bottles.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: paths.bottles.path).sorted().compactMap { try? load($0) }
    }

    public func load(_ name: String) throws -> Bottle {
        guard Self.isValidName(name) else { throw Minus196Error.invalidName(name) }
        let dir = paths.bottle(name)
        let file = dir.appendingPathComponent("bottle.json")
        guard let data = try? Data(contentsOf: file) else { throw Minus196Error.bottleNotFound(name) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var config = try decoder.decode(BottleConfig.self, from: data)
        // The folder is the bottle's identity. A copied folder still carries the old name in its
        // file, and acting on that name would hit the wrong bottle.
        config.name = name
        return Bottle(config: config, directory: dir)
    }

    public func save(_ bottle: Bottle) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bottle.config).write(to: bottle.configFile, options: .atomic)
    }

    @discardableResult
    public func create(_ config: BottleConfig) throws -> Bottle {
        guard Self.isValidName(config.name) else { throw Minus196Error.invalidName(config.name) }
        let dir = paths.bottle(config.name)
        guard !fm.fileExists(atPath: dir.path) else { throw Minus196Error.bottleExists(config.name) }
        try paths.ensureLayout()
        let bottle = Bottle(config: config, directory: dir)
        try fm.createDirectory(at: bottle.prefix, withIntermediateDirectories: true)
        try fm.createDirectory(at: bottle.logs, withIntermediateDirectories: true)
        try save(bottle)
        return bottle
    }

    /// Copies a bottle. On APFS, FileManager.copyItem clones files, so this is fast and cheap.
    @discardableResult
    public func duplicate(_ name: String, as newName: String) throws -> Bottle {
        let source = try load(name)
        guard Self.isValidName(newName) else { throw Minus196Error.invalidName(newName) }
        let dest = paths.bottle(newName)
        guard !fm.fileExists(atPath: dest.path) else { throw Minus196Error.bottleExists(newName) }
        var copy = Bottle(config: source.config, directory: dest)
        copy.config.name = newName
        copy.config.created = Date()
        do {
            try fm.copyItem(at: source.directory, to: dest)
            try save(copy)
        } catch {
            try? fm.removeItem(at: dest)                    // leave no half-made copy behind
            throw error
        }
        return copy
    }

    /// Moves the bottle to the Trash rather than deleting it outright.
    public func delete(_ name: String) throws {
        let bottle = try load(name)
        try fm.trashItem(at: bottle.directory, resultingItemURL: nil)
    }
}
