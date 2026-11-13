import Foundation

/// Everything needed to start one Wine process. Built without side effects so it can be
/// inspected (`minus196 run --dry-run`) and unit-tested.
public struct LaunchPlan: Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var backend: Backend
    public var backendNote: String
    public var ruleNote: String?
}

public struct LaunchPlanner {
    public let paths: Paths
    public let resolver: BackendResolver
    public let rules: RuleSet
    public let baseEnvironment: [String: String]

    public init(paths: Paths = Paths(), resolver: BackendResolver? = nil, rules: RuleSet? = nil,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.resolver = resolver ?? BackendResolver(paths: paths)
        self.rules = rules ?? RuleSet.load(from: paths.rulesFile)
        self.baseEnvironment = baseEnvironment
    }

    /// Programs whose own windows break on a replacement Direct3D. The Steam client's embedded
    /// browser never finishes starting on DXVK (verified 2026-11-13); games it launches are
    /// separate programs and still get the bottle's backend.
    public static let builtinGraphicsPrograms = ["steam.exe", "steamwebhelper.exe"]

    /// Arguments added to a program's command line unless it already contains `unlessContains`.
    /// Steam's browser draws from a separate GPU process into a window owned by its parent,
    /// which Wine's Mac driver cannot show; keeping the GPU work in the browser process fixes
    /// that. The rule skips the browser's own helper processes (they carry "--type=").
    public static let appendedArguments: [(program: String, unlessContains: String, arguments: String)] = [
        ("steamwebhelper.exe", "--type=", "--in-process-gpu"),
    ]

    /// Variables inherited from the caller: only the ordinary session ones. Everything else is
    /// dropped, so a stray setting in the user's shell cannot change which Wine or which DLLs
    /// get used, and tokens or keys kept in the shell are not handed to Windows programs.
    static func sanitised(_ env: [String: String]) -> [String: String] {
        let names: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SHELL", "LANG", "TZ", "TERM",
                                  "__CF_USER_TEXT_ENCODING"]
        return env.filter { key, _ in names.contains(key) || key.hasPrefix("LC_") }
    }

    /// The environment shared by every process in a bottle (wineboot, wineserver, programs).
    public func environment(for bottle: Bottle, engine: Engine, backend: Backend,
                            extraEnv: [String: String] = [:], extraOverrides: [String: String] = [:],
                            debug: String? = nil) -> [String: String] {
        var env = Self.sanitised(baseEnvironment)
        env["WINEPREFIX"] = bottle.prefix.path
        env["WINEARCH"] = bottle.config.arch.rawValue
        env["WINESERVER"] = engine.wineserver.path
        env["WINELOADER"] = engine.wine.path
        env["WINEDEBUG"] = debug ?? "-all"
        env["PATH"] = engine.root.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        if bottle.config.msync { env["WINEMSYNC"] = "1" }
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        // Extra arguments for particular programs, appended by the engine when it creates the
        // process (engine/patches/0001). A bottle's own env.MINUS196_APPEND_ARGS replaces this.
        env["MINUS196_APPEND_ARGS"] = Self.appendedArguments
            .map { "\($0.program)|\($0.unlessContains)|\($0.arguments)" }.joined(separator: ";")

        // Backend: put its DLL folder ahead of Wine's own, and tell Wine which one is active.
        env["CX_ACTIVE_GRAPHICS_BACKEND"] = backend.rawValue
        // Wine searches its own DLL folder before WINEDLLPATH, so the backend folder is handed to
        // the engine's start-up hook (engine/compat-hook), which puts it first.
        if let folder = resolver.folder(for: backend) {
            env["MINUS196_DLL_PATH"] = folder.path
            // Programs that keep Wine's own Direct3D whatever the bottle uses; the hook checks
            // this in every process, so it also holds for children of whatever is launched.
            env["MINUS196_BUILTIN_EXES"] = Self.builtinGraphicsPrograms.joined(separator: ":")
        }
        if backend == .d3dmetal, let lib = resolver.libd3dshared { env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = lib.path }
        // Wine loads its Vulkan library by soname from the engine's lib folder (rpath). The
        // CX_LIBVULKAN override is only honoured by the source when the backend is wined3d,
        // so it is not set here.
        if let gst = engine.gstreamerPlugins {
            env["GST_PLUGIN_SYSTEM_PATH"] = gst.path
            env["GST_REGISTRY"] = bottle.directory.appendingPathComponent("gstreamer-registry.bin").path
        }

        var overrides = bottle.config.dllOverrides
        overrides.merge(extraOverrides) { _, new in new }
        if !overrides.isEmpty {
            env["WINEDLLOVERRIDES"] = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        }

        // Bottle variables, then rule variables, go last so they can override anything above
        // except the prefix itself.
        for (k, v) in bottle.config.env where BottleConfig.isAllowedEnvName(k) { env[k] = v }
        for (k, v) in extraEnv where BottleConfig.isAllowedEnvName(k) { env[k] = v }
        return env
    }

    /// How a path should be handed to Wine.
    static func wineArguments(program: String, args: [String]) -> [String] {
        let lower = program.lowercased()
        if lower.hasSuffix(".msi") { return ["msiexec", "/i", program] + args }
        if lower.hasSuffix(".exe") || lower.hasSuffix(".com") || !program.contains("/") && !program.contains(".") {
            return [program] + args                      // an executable, or a builtin like "winecfg"
        }
        if lower.hasSuffix(".bat") || lower.hasSuffix(".cmd") { return ["cmd", "/c", program] + args }
        if program.hasPrefix("/") { return ["start", "/unix", program] + args }   // document or shortcut
        return ["start", program] + args
    }

    public func plan(bottle: Bottle, engine: Engine, program: String, args: [String] = [],
                     workingDirectory: URL? = nil, debug: String? = nil) -> LaunchPlan {
        let rule = rules.firstMatch(program: program)
        let ruleBackend = rule?.backend.flatMap(Backend.init(rawValue:)).map { ($0, rule?.forceBackend ?? false) }
        let resolved = resolver.resolve(choice: bottle.config.backend,
                                        rule: ruleBackend.map { (backend: $0.0, force: $0.1) },
                                        engine: engine, arch: bottle.config.arch)
        let env = environment(for: bottle, engine: engine, backend: resolved.backend,
                              extraEnv: rule?.env ?? [:], extraOverrides: rule?.dllOverrides ?? [:], debug: debug)
        let target = rule?.replaceExecutable ?? program
        let allArgs = args + (rule?.appendArgs ?? [])
        var cwd = workingDirectory
        if cwd == nil, target.hasPrefix("/") { cwd = URL(fileURLWithPath: target).deletingLastPathComponent() }
        return LaunchPlan(executable: engine.wine, arguments: Self.wineArguments(program: target, args: allArgs),
                          environment: env, workingDirectory: cwd, backend: resolved.backend,
                          backendNote: resolved.note, ruleNote: rule.map { $0.note ?? "rule for \($0.match)" })
    }
}
