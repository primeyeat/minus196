import Foundation

public struct Doctor {
    public let paths: Paths
    public init(paths: Paths = Paths()) { self.paths = paths }

    public func report() -> String {
        var out: [String] = []
        let host = HostInfo.current
        out.append("-196 home: \(paths.root.path)")
        out.append("Host: macOS \(host.macOSMajor), \(host.isAppleSilicon ? "Apple silicon" : "Intel")")
        let store = EngineStore(paths: paths)
        let engines = store.list()
        let def = store.loadSettings().defaultEngine
        out.append("Engines:")
        if engines.isEmpty { out.append("  none installed (minus196 engine add <path>)") }
        for e in engines {
            let state = e.firstMissingFile().map { "INVALID, missing \($0)" } ?? "ok"
            let extras = [e.supports32Bit ? "32-bit" : "no 32-bit", e.supportsTLS ? "TLS" : "no TLS (HTTPS will fail)",
                          e.moltenVK != nil ? "MoltenVK" : "no MoltenVK"]
            out.append("  \(e.name)\(e.name == def ? " (default)" : ""): \(state); \(extras.joined(separator: ", ")); \(e.root.path)")
        }
        let engine = def.flatMap { try? store.find($0) } ?? engines.first
        let resolver = BackendResolver(paths: paths, host: host)
        out.append("Graphics backends:")
        for b in Backend.allCases {
            let s = resolver.status(of: b, engine: engine)
            out.append("  \(b.rawValue): \(s.available ? "available" : "unavailable") (\(s.reason))")
        }
        let bottles = (try? BottleStore(paths: paths).list()) ?? []
        out.append("Bottles: \(bottles.isEmpty ? "none" : bottles.map { $0.name }.joined(separator: ", "))")
        return out.joined(separator: "\n")
    }
}
