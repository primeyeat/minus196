import Foundation

/// A concrete Direct3D implementation, after "auto" has been resolved.
public enum Backend: String, CaseIterable, Equatable {
    case d3dmetal, dxmt, dxvk, wined3d

    /// Folder under <root>/backends holding this backend's replacement DLLs
    /// (laid out as <folder>/x86_64-windows/*.dll, optionally i386-windows and x86_64-unix).
    public var folderName: String? {
        switch self {
        case .d3dmetal: return "gptk"
        case .dxmt: return "dxmt"
        case .dxvk: return "dxvk"
        case .wined3d: return nil
        }
    }
}

public struct BackendStatus: Equatable {
    public let backend: Backend
    public let available: Bool
    public let reason: String
}

/// What the host can do; injected so the logic is testable.
public struct HostInfo: Equatable {
    public var macOSMajor: Int
    public var isAppleSilicon: Bool

    public init(macOSMajor: Int, isAppleSilicon: Bool) {
        self.macOSMajor = macOSMajor; self.isAppleSilicon = isAppleSilicon
    }

    /// Rosetta, Apple's translator for Intel programs; the engine is an Intel build.
    public static var hasRosetta: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    public static var current: HostInfo {
        var size = 0
        var arm = false
        var value: Int32 = 0; size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { arm = value != 0 }
        return HostInfo(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, isAppleSilicon: arm)
    }
}

public struct BackendResolver {
    public let paths: Paths
    public let host: HostInfo
    private let fm = FileManager.default

    public init(paths: Paths = Paths(), host: HostInfo = .current) { self.paths = paths; self.host = host }

    public func folder(for backend: Backend) -> URL? {
        backend.folderName.map { paths.backends.appendingPathComponent($0, isDirectory: true) }
    }

    /// libd3dshared.dylib is the D3DMetal support library Wine's loader opens (macOS 14+).
    public var libd3dshared: URL? {
        guard let gptk = folder(for: .d3dmetal) else { return nil }
        for rel in ["external/libd3dshared.dylib", "libd3dshared.dylib"] {
            let url = gptk.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func status(of backend: Backend, engine: Engine?, arch: WineArch = .win64) -> BackendStatus {
        func no(_ why: String) -> BackendStatus { BackendStatus(backend: backend, available: false, reason: why) }
        func yes(_ why: String) -> BackendStatus { BackendStatus(backend: backend, available: true, reason: why) }
        if backend == .wined3d { return yes("built into Wine") }
        guard let dir = folder(for: backend) else { return no("no folder") }
        let dll = dir.appendingPathComponent("x86_64-windows/d3d11.dll")
        guard fm.fileExists(atPath: dll.path) else { return no("not installed (\(dll.path) missing)") }
        switch backend {
        case .d3dmetal:
            guard host.isAppleSilicon else { return no("needs Apple silicon") }
            guard host.macOSMajor >= 14 else { return no("needs macOS 14 or later") }
            guard arch == .win64 else { return no("needs a 64-bit bottle") }
            guard libd3dshared != nil else { return no("libd3dshared.dylib missing") }
            return yes("installed")
        case .dxmt:
            guard host.isAppleSilicon else { return no("needs Apple silicon") }
            guard host.macOSMajor >= 14 else { return no("needs macOS 14 or later") }
            return yes("installed")
        case .dxvk:
            guard engine?.moltenVK != nil else { return no("engine has no MoltenVK") }
            return yes("installed")
        case .wined3d:
            return yes("built into Wine")
        }
    }

    /// Order tried for "auto", and the fallback order when a pick is unavailable.
    public static let preference: [Backend] = [.d3dmetal, .dxmt, .dxvk, .wined3d]

    /// Resolves a bottle's choice (and an optional per-app rule) to a backend that can run.
    /// A rule wins over "auto"; a forced rule wins over an explicit bottle choice too.
    public func resolve(choice: BackendChoice, rule: (backend: Backend, force: Bool)? = nil,
                        engine: Engine?, arch: WineArch = .win64) -> (backend: Backend, note: String) {
        var wanted: Backend? = Backend(rawValue: choice.rawValue)
        var note = wanted == nil ? "auto" : "bottle setting"
        if let rule, wanted == nil || rule.force { wanted = rule.backend; note = rule.force ? "forced by rule" : "rule" }
        var order = Self.preference
        if let wanted { order.removeAll { $0 == wanted }; order.insert(wanted, at: 0) }
        for candidate in order {
            let s = status(of: candidate, engine: engine, arch: arch)
            if s.available {
                if let wanted, candidate != wanted {
                    let why = status(of: wanted, engine: engine, arch: arch).reason
                    return (candidate, "\(wanted.rawValue) unavailable (\(why)); fell back to \(candidate.rawValue)")
                }
                return (candidate, note)
            }
        }
        return (.wined3d, "fallback")
    }
}
