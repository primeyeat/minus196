import Foundation

/// Runs Wine. The only type in the core that starts processes.
public struct Launcher {
    public let paths: Paths
    public let planner: LaunchPlanner
    public let engines: EngineStore
    public let store: BottleStore
    private let fm = FileManager.default

    public init(paths: Paths = Paths()) {
        self.paths = paths
        self.planner = LaunchPlanner(paths: paths)
        self.engines = EngineStore(paths: paths)
        self.store = BottleStore(paths: paths)
    }

    public struct RunResult { public let exitCode: Int32?; public let log: URL; public let plan: LaunchPlan }

    func logFile(for bottle: Bottle, label: String) throws -> URL {
        try fm.createDirectory(at: bottle.logs, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let safe = label.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return bottle.logs.appendingPathComponent("\(f.string(from: Date()))-\(String(safe.suffix(40))).log")
    }

    /// Starts a process described by a plan. With `wait`, returns its exit code.
    @discardableResult
    public func start(_ plan: LaunchPlan, bottle: Bottle, label: String, wait: Bool) throws -> RunResult {
        let log = try logFile(for: bottle, label: label)
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let header = "# \(plan.executable.path) \(plan.arguments.joined(separator: " "))\n# backend: \(plan.backend.rawValue) (\(plan.backendNote))\n"
        handle.write(Data(header.utf8))
        let p = Process()
        p.executableURL = plan.executable
        p.arguments = plan.arguments
        p.environment = plan.environment
        p.currentDirectoryURL = plan.workingDirectory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        if wait {
            p.waitUntilExit()
            return RunResult(exitCode: p.terminationStatus, log: log, plan: plan)
        }
        return RunResult(exitCode: nil, log: log, plan: plan)
    }

    /// Runs a Wine tool in the bottle and waits; throws on a non-zero exit.
    func tool(_ bottle: Bottle, engine: Engine, _ args: [String], label: String, executable: URL? = nil,
              extraEnv: [String: String] = [:]) throws {
        var env = planner.environment(for: bottle, engine: engine, backend: .wined3d)
        env.merge(extraEnv) { _, new in new }
        let plan = LaunchPlan(executable: executable ?? engine.wine, arguments: args, environment: env,
                              workingDirectory: nil, backend: .wined3d, backendNote: "tool", ruleNote: nil)
        let r = try start(plan, bottle: bottle, label: label, wait: true)
        if let code = r.exitCode, code != 0 { throw Minus196Error.processFailed("\(label) (log: \(r.log.path))", code) }
    }

    /// Creates the bottle on disk and initialises its Wine prefix.
    @discardableResult
    public func createBottle(_ config: BottleConfig) throws -> Bottle {
        let engine = try engines.resolve(for: config)
        try engine.validate()
        let bottle = try store.create(config)
        do {
            // Disabling mscoree and mshtml during first boot stops Wine's "install Mono / Gecko?"
            // dialogs, which would otherwise block creation until someone clicks them.
            try tool(bottle, engine: engine, ["wineboot", "--init"], label: "wineboot-init",
                     extraEnv: ["WINEDLLOVERRIDES": "mscoree,mshtml="])
            try tool(bottle, engine: engine, ["winecfg", "/v", config.windowsVersion], label: "winecfg-version")
            let home = fm.homeDirectoryForCurrentUser
            let y = bottle.prefix.appendingPathComponent("dosdevices/y:")
            if (try? fm.attributesOfItem(atPath: y.path)) == nil {
                try? fm.createSymbolicLink(at: y, withDestinationURL: home)
            }
            try tool(bottle, engine: engine, ["-w"], label: "wineserver-wait", executable: engine.wineserver)
        } catch {
            // Leave nothing half-made behind.
            try? fm.removeItem(at: bottle.directory)
            throw error
        }
        return bottle
    }

    @discardableResult
    public func run(bottleName: String, program: String, args: [String] = [], workingDirectory: URL? = nil,
                    wait: Bool = false, debug: String? = nil) throws -> RunResult {
        let bottle = try store.load(bottleName)
        let engine = try engines.resolve(for: bottle.config)
        try engine.validate()
        try updatePrefixIfNeeded(bottle, engine: engine)
        let plan = planner.plan(bottle: bottle, engine: engine, program: program, args: args,
                                workingDirectory: workingDirectory, debug: debug)
        if let folder = planner.resolver.folder(for: plan.backend) {
            installPlaceholders(from: folder, into: bottle)
        }
        return try start(plan, bottle: bottle, label: RuleSet.fileName(of: program), wait: wait)
    }

    /// Wine loads a builtin DLL from its search path only when a file of that name exists in
    /// the bottle's system folder (it finds the name there, sees the builtin marker and then
    /// loads the real one from the search path). Backends bring DLLs Wine does not have, such
    /// as DXMT's winemetal.dll, so copy any that are missing. Existing files are never replaced.
    func installPlaceholders(from backendFolder: URL, into bottle: Bottle) {
        let windows = bottle.prefix.appendingPathComponent("drive_c/windows")
        let is64 = fm.fileExists(atPath: windows.appendingPathComponent("syswow64").path)
        let targets: [(source: String, system: String)] = is64
            ? [("x86_64-windows", "system32"), ("i386-windows", "syswow64")]
            : [("i386-windows", "system32")]
        for target in targets {
            let source = backendFolder.appendingPathComponent(target.source)
            let system = windows.appendingPathComponent(target.system)
            guard let names = try? fm.contentsOfDirectory(atPath: source.path),
                  fm.fileExists(atPath: system.path) else { continue }
            for name in names where name.lowercased().hasSuffix(".dll") {
                let destination = system.appendingPathComponent(name)
                // Wine's own empty stand-in (made at prefix creation for a few names such as
                // nvngx.dll) is replaced by the backend's file: games check that file's digital
                // signature before using DLSS, and the stand-in has none.
                if isWinePlaceholder(destination) { try? fm.removeItem(at: destination) }
                if !fm.fileExists(atPath: destination.path) {
                    try? fm.copyItem(at: source.appendingPathComponent(name), to: destination)
                }
            }
        }
    }

    /// Wine's generated stand-in DLLs are tiny files carrying the text "Wine placeholder DLL".
    func isWinePlaceholder(_ url: URL) -> Bool {
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 4096,
              let data = try? Data(contentsOf: url) else { return false }
        return data.range(of: Data("Wine placeholder DLL".utf8)) != nil
    }

    /// True when Wine would update the prefix on its next start: it compares the number stored in
    /// `<prefix>/.update-timestamp` with the modification time of the engine's `wine.inf`.
    func prefixNeedsUpdate(_ bottle: Bottle, engine: Engine) -> Bool {
        let inf = engine.root.appendingPathComponent("share/wine/wine.inf")
        guard let modified = (try? fm.attributesOfItem(atPath: inf.path))?[.modificationDate] as? Date else { return false }
        let stampFile = bottle.prefix.appendingPathComponent(".update-timestamp")
        guard let text = try? String(contentsOf: stampFile, encoding: .utf8) else { return true }
        let stamp = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stamp == "disable" { return false }
        return stamp != String(Int(modified.timeIntervalSince1970))
    }

    /// Runs the prefix update ourselves after an engine change, with the Mono and Gecko prompts
    /// suppressed, so the program being launched does not hang behind an installer dialog.
    func updatePrefixIfNeeded(_ bottle: Bottle, engine: Engine) throws {
        // The update ends with stopping the bottle; never do that under a running program.
        guard prefixNeedsUpdate(bottle, engine: engine), !bottle.isRunning else { return }
        try tool(bottle, engine: engine, ["wineboot", "--update"], label: "wineboot-update",
                 extraEnv: ["WINEDLLOVERRIDES": "mscoree,mshtml="])
        // wineboot also starts the bottle's autostart programs (Steam registers itself with
        // "-silent"). Waiting for them would block for as long as they run, and they would keep
        // this tool environment, so stop everything and let the real launch start clean.
        try? tool(bottle, engine: engine, ["-k"], label: "wineserver-kill", executable: engine.wineserver)
    }

    /// Asks Windows programs to exit, then stops the bottle's wineserver.
    public func stop(bottleName: String, force: Bool = false) throws {
        let bottle = try store.load(bottleName)
        let engine = try engines.resolve(for: bottle.config)
        if !force { try? tool(bottle, engine: engine, ["wineboot", "--end-session", "--shutdown"], label: "wineboot-shutdown") }
        try? tool(bottle, engine: engine, ["-k"], label: "wineserver-kill", executable: engine.wineserver)
    }
}
