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
    public func createBottle(_ config: BottleConfig, progress: ((Double) -> Void)? = nil) throws -> Bottle {
        let engine = try engines.resolve(for: config)
        try engine.validate()
        let bottle = try store.create(config)
        do {
            progress?(0.02)
            // Most of the time goes into Windows' system files being put in place, so the share
            // of them that has arrived is the progress. A bottle gets about three quarters of
            // the files the engine has.
            let watcher = progress.map { report in
                SystemFilesWatcher(prefix: bottle.prefix, expected: max(1, engine.windowsFileCount * 3 / 4)) { report(0.05 + 0.8 * $0) }
            }
            defer { watcher?.stop() }
            // See Engine.setupOverrides: keeps Wine's "install Mono / Gecko?" dialogs from blocking.
            try tool(bottle, engine: engine, ["wineboot", "--init"], label: "wineboot-init",
                     extraEnv: engine.setupOverrides.map { ["WINEDLLOVERRIDES": $0] } ?? [:])
            watcher?.stop()
            progress?(0.88)
            try tool(bottle, engine: engine, ["winecfg", "/v", config.windowsVersion], label: "winecfg-version")
            progress?(0.95)
            let home = fm.homeDirectoryForCurrentUser
            let y = bottle.prefix.appendingPathComponent("dosdevices/y:")
            if (try? fm.attributesOfItem(atPath: y.path)) == nil {
                try? fm.createSymbolicLink(at: y, withDestinationURL: home)
            }
            // Everything is set up once the two tools above return. Left alone, Windows' idle
            // background helpers take another 40 seconds or so to exit; stopping the bottle ends
            // them now, and the server writes the registry to disk on its way out.
            try? tool(bottle, engine: engine, ["-k"], label: "wineserver-kill", executable: engine.wineserver)
            try waitUntilStopped(bottle, engine: engine)
        } catch {
            // Leave nothing half-made behind.
            try? fm.removeItem(at: bottle.directory)
            throw error
        }
        return bottle
    }

    /// Waits for the bottle's server to be gone and its registry to be on disk.
    func waitUntilStopped(_ bottle: Bottle, engine: Engine) throws {
        let registry = bottle.prefix.appendingPathComponent("system.reg").path
        for _ in 0..<100 {
            if !bottle.isRunning && fm.fileExists(atPath: registry) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Not stopped after ten seconds: fall back to waiting for it to finish by itself.
        try tool(bottle, engine: engine, ["-w"], label: "wineserver-wait", executable: engine.wineserver)
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
                 extraEnv: engine.setupOverrides.map { ["WINEDLLOVERRIDES": $0] } ?? [:])
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
        endLeftovers(of: bottle)
    }

    /// The Windows programs that belong to this bottle, found by the WINEPREFIX each was
    /// started with. Wine rewrites a process's name, which hides its environment from `ps`,
    /// so the startup data the system keeps for each process is searched directly. `title` is
    /// the Windows command line Wine shows as the process name.
    public func processList(of bottle: Bottle) -> [(pid: pid_t, title: String)] {
        let needle = Data("\0WINEPREFIX=\(bottle.prefix.path)\0".utf8)
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var found: [(pid_t, String)] = []
        for pid in pids.prefix(Int(count)) where pid > 1 && pid != getpid() {
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size <= 4_000_000 else { continue }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { continue }   // other users' processes fail here
            let data = Data(buffer.prefix(size))
            guard data.range(of: needle) != nil else { continue }
            // Layout: argument count (4 bytes), the program's path, zero padding, then the name.
            // Layout: argument count (4 bytes), the program's path, zero padding, the arguments.
            let argc = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
            var at = 4
            while at < data.count, data[at] != 0 { at += 1 }
            if String(decoding: data[4..<at], as: UTF8.self).hasSuffix("/wineserver") { continue }   // the server itself
            while at < data.count, data[at] == 0 { at += 1 }
            var parts: [String] = []
            while parts.count < max(1, min(argc, 64)), at < data.count {
                var end = at
                while end < data.count, data[end] != 0 { end += 1 }
                parts.append(String(decoding: data[at..<end], as: UTF8.self))
                at = end + 1
            }
            found.append((pid, parts.joined(separator: " ")))
        }
        return found
    }

    public func processes(of bottle: Bottle) -> [pid_t] { processList(of: bottle).map(\.pid) }

    /// Parts of Windows itself that run in every bottle.
    static let systemPrograms: Set<String> = ["services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
                                              "explorer.exe", "conhost.exe", "start.exe", "wineboot.exe", "winemenubuilder.exe"]

    /// Launchers such as Steam are built on a web browser engine that runs helper processes
    /// (their command line carries "--type=renderer" and the like). When the launcher exits,
    /// a helper sometimes fails to notice and spins at full speed for hours. Given a bottle's
    /// processes, returns those helpers when nothing but them and Windows itself is left.
    static func orphanedHelpers(in list: [(pid: pid_t, title: String)]) -> [pid_t] {
        var helpers: [pid_t] = []
        for (pid, title) in list {
            let lower = title.lowercased()
            guard let exe = lower.range(of: ".exe") else { return [] }             // unknown: leave everything alone
            let name = lower[..<exe.upperBound].split(separator: "\\").last.map(String.init) ?? ""
            if lower[exe.upperBound...].contains(" --type=") { helpers.append(pid) }
            else if !systemPrograms.contains(name) { return [] }                   // a real program is still running
        }
        return helpers
    }

    public func orphanedHelpers(of bottle: Bottle) -> [pid_t] { Self.orphanedHelpers(in: processList(of: bottle)) }

    /// Ends programs that outlived the bottle's wineserver (after it crashed, say). Without the
    /// server they can do nothing useful, but some keep using the processor. Does nothing while
    /// the bottle is running.
    public func endLeftovers(of bottle: Bottle, olderThan seconds: TimeInterval = 0) {
        guard !bottle.isRunning else { return }
        let first = processes(of: bottle).filter { Self.age(of: $0) >= seconds }
        guard !first.isEmpty else { return }
        first.forEach { kill($0, SIGTERM) }
        Thread.sleep(forTimeInterval: 1)
        guard !bottle.isRunning else { return }
        processes(of: bottle).filter(first.contains).forEach { kill($0, SIGKILL) }
    }

    /// Seconds since a process started; 0 when that cannot be read. A program that is just
    /// starting has no server yet either, and must not be taken for a leftover.
    static func age(of pid: pid_t) -> TimeInterval {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Date().timeIntervalSince1970 - TimeInterval(info.pbi_start_tvsec)
    }
}

/// Reports, a few times a second, how many of the expected Windows system files a new bottle has.
final class SystemFilesWatcher {
    private let timer: DispatchSourceTimer
    private var stopped = false
    private let lock = NSLock()

    init(prefix: URL, expected: Int, report: @escaping (Double) -> Void) {
        let folders = ["system32", "syswow64"].map { prefix.appendingPathComponent("drive_c/windows/\($0)").path }
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(100))
        timer.setEventHandler {
            let count = folders.reduce(0) { $0 + ((try? FileManager.default.contentsOfDirectory(atPath: $1).count) ?? 0) }
            report(min(1, Double(count) / Double(expected)))
        }
        timer.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stopped = true; timer.cancel() }
    }
}
