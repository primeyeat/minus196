import Foundation

/// A per-program tweak, matched on the executable's file name (case-insensitive).
/// The five effects mirror what a compatibility layer typically needs: choose a backend,
/// override DLLs, set environment variables, append arguments, or run a different executable.
public struct AppRule: Codable, Equatable {
    public var match: String
    public var note: String?
    public var backend: String?
    public var forceBackend: Bool?
    public var env: [String: String]?
    public var dllOverrides: [String: String]?
    public var appendArgs: [String]?
    public var replaceExecutable: String?

    public init(match: String, note: String? = nil, backend: String? = nil, forceBackend: Bool? = nil,
                env: [String: String]? = nil, dllOverrides: [String: String]? = nil,
                appendArgs: [String]? = nil, replaceExecutable: String? = nil) {
        self.match = match; self.note = note; self.backend = backend; self.forceBackend = forceBackend
        self.env = env; self.dllOverrides = dllOverrides; self.appendArgs = appendArgs
        self.replaceExecutable = replaceExecutable
    }
}

public struct RuleSet: Codable, Equatable {
    public var rules: [AppRule]
    public init(rules: [AppRule] = []) { self.rules = rules }

    public static func load(from url: URL) -> RuleSet {
        guard let data = try? Data(contentsOf: url),
              let set = try? JSONDecoder().decode(RuleSet.self, from: data) else { return RuleSet() }
        return set
    }

    /// First rule whose `match` equals the program's file name.
    public func firstMatch(program: String) -> AppRule? {
        let file = Self.fileName(of: program).lowercased()
        return rules.first { $0.match.lowercased() == file }
    }

    /// Handles both Unix and Windows separators.
    static func fileName(of program: String) -> String {
        let cut = program.lastIndex(where: { $0 == "/" || $0 == "\\" })
        return cut.map { String(program[program.index(after: $0)...]) } ?? program
    }
}
