import Foundation

/// A Wine install tree: bin/wine, bin/wineserver, lib/wine/<arch>-unix, lib/wine/<arch>-windows.
public struct Engine: Equatable {
    public let name: String
    public let root: URL

    public var wine: URL { root.appendingPathComponent("bin/wine") }
    public var wineserver: URL { root.appendingPathComponent("bin/wineserver") }
    public var libWine: URL { root.appendingPathComponent("lib/wine", isDirectory: true) }

    /// Returns the first required file that is missing, or nil if the tree looks usable.
    public func firstMissingFile() -> String? {
        let fm = FileManager.default
        for rel in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-windows/ntdll.dll"] {
            if !fm.fileExists(atPath: root.appendingPathComponent(rel).path) { return rel }
        }
        return nil
    }

    public func validate() throws {
        if let missing = firstMissingFile() { throw Minus196Error.engineInvalid(name, missing: missing) }
    }

    /// True when the tree can run 32-bit Windows programs (new-style WoW64 needs i386-windows DLLs).
    public var supports32Bit: Bool {
        FileManager.default.fileExists(atPath: libWine.appendingPathComponent("i386-windows/ntdll.dll").path)
    }

    /// The MoltenVK library bundled with the engine, if any.
    public var moltenVK: URL? {
        for rel in ["lib/libMoltenVK.dylib", "lib64/libMoltenVK.dylib"] {
            let url = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// True when the engine can do TLS (HTTPS): Wine's secur32 was built against GnuTLS and the
    /// GnuTLS library it loads at run time is present in the engine.
    public var supportsTLS: Bool {
        let fm = FileManager.default
        let hasLibrary = ["lib/libgnutls.30.dylib", "lib64/libgnutls.30.dylib"]
            .contains { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard hasLibrary,
              let data = try? Data(contentsOf: libWine.appendingPathComponent("x86_64-unix/secur32.so"),
                                   options: .mappedIfSafe) else { return false }
        return data.range(of: Data("libgnutls".utf8)) != nil
    }

    public var gstreamerPlugins: URL? {
        for rel in ["lib/gstreamer-1.0", "lib64/gstreamer-1.0"] {
            let url = root.appendingPathComponent(rel, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

public struct Settings: Codable, Equatable {
    public var defaultEngine: String?
    public init(defaultEngine: String? = nil) { self.defaultEngine = defaultEngine }
}

/// Engines live in <root>/engines/<name>; an entry may be a real folder or a symlink to one.
public struct EngineStore {
    public let paths: Paths
    private let fm = FileManager.default
    public init(paths: Paths = Paths()) { self.paths = paths }

    public func list() -> [Engine] {
        guard let names = try? fm.contentsOfDirectory(atPath: paths.engines.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().map {
            Engine(name: $0, root: paths.engines.appendingPathComponent($0, isDirectory: true).resolvingSymlinksInPath())
        }
    }

    public func find(_ name: String) throws -> Engine {
        guard let e = list().first(where: { $0.name == name }) else { throw Minus196Error.engineNotFound(name) }
        return e
    }

    /// Registers an existing Wine install by symlinking it; nothing is copied.
    @discardableResult
    public func add(path: URL, name: String) throws -> Engine {
        guard BottleStore.isValidName(name) else { throw Minus196Error.invalidName(name) }
        let engine = Engine(name: name, root: path.resolvingSymlinksInPath())
        try engine.validate()
        try paths.ensureLayout()
        let link = paths.engines.appendingPathComponent(name)
        guard engine.root.standardizedFileURL.path != link.resolvingSymlinksInPath().standardizedFileURL.path
                || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil else {
            return engine                                   // already a real folder in engines/: nothing to do
        }
        if let existing = try? fm.attributesOfItem(atPath: link.path) {
            // Only an earlier link is replaced. A real folder here is someone's engine: never delete it.
            guard existing[.type] as? FileAttributeType == .typeSymbolicLink else { throw Minus196Error.engineExists(name) }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: engine.root)
        if loadSettings().defaultEngine == nil { try setDefault(name) }
        return engine
    }

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func setDefault(_ name: String) throws {
        _ = try find(name)
        var s = loadSettings(); s.defaultEngine = name
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try paths.ensureLayout()
        try enc.encode(s).write(to: paths.settingsFile, options: .atomic)
    }

    /// The engine a bottle should use: its own choice, else the default, else the only one installed.
    public func resolve(for config: BottleConfig) throws -> Engine {
        if let name = config.engine { return try find(name) }
        if let name = loadSettings().defaultEngine, let e = try? find(name) { return e }
        if let only = list().first, list().count == 1 { return only }
        throw Minus196Error.noEngine
    }
}
