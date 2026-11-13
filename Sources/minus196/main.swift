import Minus196Core
import Foundation

let usage = """
minus196 — Wine bottle wrapper

  minus196 doctor
  minus196 engine list
  minus196 engine add <path> [--name NAME]
  minus196 engine default <name>
  minus196 bottle list
  minus196 bottle create <name> [--arch win64|win32] [--winver win10] [--backend auto|d3dmetal|dxmt|dxvk|wined3d] [--engine NAME] [--no-msync]
  minus196 bottle info <name>
  minus196 bottle set <name> key=value...      keys: backend msync winver engine env.NAME dll.NAME
  minus196 bottle duplicate <name> <new-name>
  minus196 bottle delete <name>                moves it to the Trash
  minus196 run <bottle> <program> [--cwd DIR] [--wait] [--debug CHANNELS] [--dry-run] [-- args...]
  minus196 kill <bottle> [--force]
  minus196 env <bottle>                        prints the bottle's environment as shell exports
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("minus196: \(message)\n".utf8))
    exit(code)
}

/// Splits "--flag value" options from positional arguments; everything after "--" is passed through.
struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var passthrough: [String] = []

    init(_ raw: [String], valueOptions: Set<String>, flagOptions: Set<String>) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a == "--" { passthrough = Array(raw[(i + 1)...]); break }
            if valueOptions.contains(a) {
                guard i + 1 < raw.count else { fail("\(a) needs a value") }
                options[a] = raw[i + 1]; i += 2; continue
            }
            if flagOptions.contains(a) { flags.insert(a); i += 1; continue }
            if a.hasPrefix("--") { fail("unknown option \(a)") }
            positional.append(a); i += 1
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

let paths = Paths()
let store = BottleStore(paths: paths)
let engines = EngineStore(paths: paths)
var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
argv.removeFirst()

do {
    switch command {
    case "help", "--help", "-h":
        print(usage)

    case "doctor":
        print(Doctor(paths: paths).report())

    case "engine":
        guard let sub = argv.first else { fail("engine: list | add | default") }
        let a = Args(Array(argv.dropFirst()), valueOptions: ["--name"], flagOptions: [])
        switch sub {
        case "list":
            let def = engines.loadSettings().defaultEngine
            for e in engines.list() { print("\(e.name)\(e.name == def ? " *" : "")\t\(e.root.path)") }
        case "add":
            guard let path = a.positional.first else { fail("engine add <path>") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let e = try engines.add(path: url, name: a.options["--name"] ?? url.lastPathComponent)
            print("added engine '\(e.name)' -> \(e.root.path)")
        case "default":
            guard let name = a.positional.first else { fail("engine default <name>") }
            try engines.setDefault(name); print("default engine: \(name)")
        default: fail("unknown engine command '\(sub)'")
        }

    case "bottle":
        guard let sub = argv.first else { fail("bottle: list | create | info | set | duplicate | delete") }
        let a = Args(Array(argv.dropFirst()), valueOptions: ["--arch", "--winver", "--backend", "--engine"],
                     flagOptions: ["--no-msync"])
        switch sub {
        case "list":
            for b in try store.list() {
                print("\(b.name)\t\(b.config.arch.rawValue)\t\(b.config.windowsVersion)\t\(b.config.backend.rawValue)\t\(b.isInitialised ? "ready" : "not initialised")")
            }
        case "create":
            guard let name = a.positional.first else { fail("bottle create <name>") }
            guard let arch = WineArch(rawValue: a.options["--arch"] ?? "win64") else { fail("--arch must be win64 or win32") }
            guard let backend = BackendChoice(rawValue: a.options["--backend"] ?? "auto") else { fail("unknown backend") }
            let config = BottleConfig(name: name, engine: a.options["--engine"], arch: arch,
                                      windowsVersion: a.options["--winver"] ?? "win10", backend: backend,
                                      msync: !a.flags.contains("--no-msync"))
            let bottle = try Launcher(paths: paths).createBottle(config)
            print("created bottle '\(bottle.name)' at \(bottle.directory.path)")
        case "info":
            guard let name = a.positional.first else { fail("bottle info <name>") }
            let b = try store.load(name)
            print(String(decoding: try Data(contentsOf: b.configFile), as: UTF8.self))
            print("prefix: \(b.prefix.path) (\(b.isInitialised ? "ready" : "not initialised"))")
        case "set":
            guard a.positional.count >= 2 else { fail("bottle set <name> key=value...") }
            var b = try store.load(a.positional[0])
            for s in a.positional.dropFirst() { try b.config.apply(setting: s) }
            try store.save(b); print("updated '\(b.name)'")
        case "duplicate":
            guard a.positional.count == 2 else { fail("bottle duplicate <name> <new-name>") }
            let b = try store.duplicate(a.positional[0], as: a.positional[1]); print("created '\(b.name)'")
        case "delete":
            guard let name = a.positional.first else { fail("bottle delete <name>") }
            try? Launcher(paths: paths).stop(bottleName: name, force: true)
            try store.delete(name); print("moved '\(name)' to the Trash")
        default: fail("unknown bottle command '\(sub)'")
        }

    case "run":
        let a = Args(argv, valueOptions: ["--cwd", "--debug"], flagOptions: ["--wait", "--dry-run"])
        guard a.positional.count >= 2 else { fail("run <bottle> <program> [-- args...]") }
        let cwd = a.options["--cwd"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let args = Array(a.positional.dropFirst(2)) + a.passthrough
        let launcher = Launcher(paths: paths)
        if a.flags.contains("--dry-run") {
            let bottle = try store.load(a.positional[0])
            let engine = try engines.resolve(for: bottle.config)
            let plan = launcher.planner.plan(bottle: bottle, engine: engine, program: a.positional[1], args: args,
                                             workingDirectory: cwd, debug: a.options["--debug"])
            print("backend: \(plan.backend.rawValue) (\(plan.backendNote))")
            if let r = plan.ruleNote { print("rule: \(r)") }
            print("cwd: \(plan.workingDirectory?.path ?? "(inherit)")")
            print(([plan.executable.path] + plan.arguments).map(shellQuote).joined(separator: " "))
            break
        }
        let r = try launcher.run(bottleName: a.positional[0], program: a.positional[1], args: args,
                                 workingDirectory: cwd, wait: a.flags.contains("--wait"), debug: a.options["--debug"])
        print("backend: \(r.plan.backend.rawValue) (\(r.plan.backendNote))")
        print("log: \(r.log.path)")
        if let code = r.exitCode, code != 0 { exit(code) }

    case "kill":
        let a = Args(argv, valueOptions: [], flagOptions: ["--force"])
        guard let name = a.positional.first else { fail("kill <bottle>") }
        try Launcher(paths: paths).stop(bottleName: name, force: a.flags.contains("--force"))
        print("stopped '\(name)'")

    case "env":
        guard let name = argv.first else { fail("env <bottle>") }
        let bottle = try store.load(name)
        let engine = try engines.resolve(for: bottle.config)
        let planner = LaunchPlanner(paths: paths, baseEnvironment: [:])
        let backend = planner.resolver.resolve(choice: bottle.config.backend, engine: engine, arch: bottle.config.arch).backend
        let env = planner.environment(for: bottle, engine: engine, backend: backend)
        for (k, v) in env.sorted(by: { $0.key < $1.key }) where k != "PATH" && BottleConfig.isAllowedEnvName(k) || ["WINEPREFIX", "WINESERVER", "WINELOADER"].contains(k) { print("export \(k)=\(shellQuote(v))") }
        print("export PATH=\(shellQuote(engine.root.appendingPathComponent("bin").path)):\"$PATH\"")

    default:
        fail("unknown command '\(command)'\n\n\(usage)")
    }
} catch let error as Minus196Error {
    fail(error.description)
} catch {
    fail(error.localizedDescription)
}
