import XCTest
@testable import Minus196Core

final class Minus196CoreTests: XCTestCase {
    var tmp: URL!
    var paths: Paths!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("minus196-tests-\(UUID().uuidString)")
        paths = Paths(root: tmp)
        try paths.ensureLayout()
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func touch(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data())
    }

    /// A folder with the files Engine.validate() looks for (empty placeholders, not a real Wine).
    func fakeEngine(_ name: String = "fake", moltenVK: Bool = false) throws -> Engine {
        let root = tmp.appendingPathComponent("fake-engines/\(name)")
        for rel in ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-windows/ntdll.dll"] {
            try touch(root.appendingPathComponent(rel))
        }
        if moltenVK { try touch(root.appendingPathComponent("lib/libMoltenVK.dylib")) }
        return try EngineStore(paths: paths).add(path: root, name: name)
    }

    func installBackend(_ b: Backend) throws {
        let dir = paths.backends.appendingPathComponent(b.folderName!)
        try touch(dir.appendingPathComponent("x86_64-windows/d3d11.dll"))
        if b == .d3dmetal { try touch(dir.appendingPathComponent("external/libd3dshared.dylib")) }
    }

    let m3 = HostInfo(macOSMajor: 15, isAppleSilicon: true)

    // MARK: bottle store

    func testNameValidation() {
        XCTAssertTrue(BottleStore.isValidName("Steam"))
        XCTAssertTrue(BottleStore.isValidName("My Games-2.0_a"))
        for bad in ["", ".", "..", ".hidden", "a/b", "a:b", String(repeating: "x", count: 65)] {
            XCTAssertFalse(BottleStore.isValidName(bad), bad)
        }
    }

    func testCreateLoadDuplicateRoundTrip() throws {
        let store = BottleStore(paths: paths)
        var config = BottleConfig(name: "One", backend: .dxmt)
        config.env["FOO"] = "bar"
        let b = try store.create(config)
        XCTAssertTrue(fm.fileExists(atPath: b.prefix.path))
        XCTAssertFalse(b.isInitialised)
        XCTAssertEqual(try store.load("One").config.env["FOO"], "bar")
        XCTAssertEqual(try store.load("One").config.backend, .dxmt)
        XCTAssertThrowsError(try store.create(config)) { XCTAssertEqual($0 as? Minus196Error, .bottleExists("One")) }
        try touch(b.prefix.appendingPathComponent("drive_c/file.txt"))
        let copy = try store.duplicate("One", as: "Two")
        XCTAssertEqual(copy.config.name, "Two")
        XCTAssertTrue(fm.fileExists(atPath: copy.prefix.appendingPathComponent("drive_c/file.txt").path))
        XCTAssertEqual(try store.list().map(\.name), ["One", "Two"])
        XCTAssertThrowsError(try store.load("Missing")) { XCTAssertEqual($0 as? Minus196Error, .bottleNotFound("Missing")) }
        XCTAssertThrowsError(try store.load("../x")) { XCTAssertEqual($0 as? Minus196Error, .invalidName("../x")) }
    }

    func testSettings() throws {
        var c = BottleConfig(name: "S")
        try c.apply(setting: "backend=dxvk"); XCTAssertEqual(c.backend, .dxvk)
        try c.apply(setting: "msync=off"); XCTAssertFalse(c.msync)
        try c.apply(setting: "env.A=1=2"); XCTAssertEqual(c.env["A"], "1=2")
        try c.apply(setting: "env.A="); XCTAssertNil(c.env["A"])
        try c.apply(setting: "dll.winhttp=builtin"); XCTAssertEqual(c.dllOverrides["winhttp"], "builtin")
        for bad in ["backend=opengl", "msync=maybe", "nonsense=1", "noequals", "env.WINEPREFIX=/tmp", "env.=x"] {
            XCTAssertThrowsError(try c.apply(setting: bad), bad)
        }
    }

    // MARK: engines

    func testEngineValidationAndDefault() throws {
        let store = EngineStore(paths: paths)
        let empty = tmp.appendingPathComponent("empty"); try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.add(path: empty, name: "bad")) {
            XCTAssertEqual($0 as? Minus196Error, .engineInvalid("bad", missing: "bin/wine"))
        }
        XCTAssertThrowsError(try store.resolve(for: BottleConfig(name: "x"))) { XCTAssertEqual($0 as? Minus196Error, .noEngine) }
        let e = try fakeEngine("a")
        XCTAssertEqual(store.loadSettings().defaultEngine, "a")
        XCTAssertEqual(try store.resolve(for: BottleConfig(name: "x")).name, e.name)
        _ = try fakeEngine("b")
        XCTAssertEqual(try store.resolve(for: BottleConfig(name: "x")).name, "a")
        XCTAssertEqual(try store.resolve(for: BottleConfig(name: "x", engine: "b")).name, "b")
        XCTAssertThrowsError(try store.resolve(for: BottleConfig(name: "x", engine: "zzz")))
    }

    // MARK: backends

    func testBackendResolution() throws {
        let engine = try fakeEngine()
        let r = BackendResolver(paths: paths, host: m3)
        // Nothing installed: everything resolves to wined3d.
        XCTAssertEqual(r.resolve(choice: .auto, engine: engine).backend, .wined3d)
        let fallback = r.resolve(choice: .dxmt, engine: engine)
        XCTAssertEqual(fallback.backend, .wined3d)
        XCTAssertTrue(fallback.note.contains("dxmt unavailable"), fallback.note)

        try installBackend(.dxmt)
        XCTAssertEqual(r.resolve(choice: .auto, engine: engine).backend, .dxmt)
        try installBackend(.d3dmetal)
        XCTAssertEqual(r.resolve(choice: .auto, engine: engine).backend, .d3dmetal)
        XCTAssertEqual(r.resolve(choice: .dxmt, engine: engine).backend, .dxmt)
        XCTAssertEqual(r.resolve(choice: .wined3d, engine: engine).backend, .wined3d)
        // D3DMetal is 64-bit only.
        XCTAssertEqual(r.resolve(choice: .d3dmetal, engine: engine, arch: .win32).backend, .dxmt)

        // Rules: win over auto, lose to an explicit choice unless forced.
        XCTAssertEqual(r.resolve(choice: .auto, rule: (.dxmt, false), engine: engine).backend, .dxmt)
        XCTAssertEqual(r.resolve(choice: .d3dmetal, rule: (.dxmt, false), engine: engine).backend, .d3dmetal)
        XCTAssertEqual(r.resolve(choice: .d3dmetal, rule: (.dxmt, true), engine: engine).backend, .dxmt)

        // DXVK needs MoltenVK in the engine.
        try installBackend(.dxvk)
        XCTAssertFalse(r.status(of: .dxvk, engine: engine).available)
        let withMVK = try fakeEngine("mvk", moltenVK: true)
        XCTAssertTrue(r.status(of: .dxvk, engine: withMVK).available)

        // Older macOS or Intel: no D3DMetal or DXMT.
        let old = BackendResolver(paths: paths, host: HostInfo(macOSMajor: 13, isAppleSilicon: true))
        XCTAssertEqual(old.resolve(choice: .auto, engine: withMVK).backend, .dxvk)
        let intel = BackendResolver(paths: paths, host: HostInfo(macOSMajor: 15, isAppleSilicon: false))
        XCTAssertEqual(intel.resolve(choice: .d3dmetal, engine: engine).backend, .wined3d)
    }

    // MARK: launch plans

    func testEnvironment() throws {
        let engine = try fakeEngine()
        try installBackend(.d3dmetal)
        var config = BottleConfig(name: "Env", backend: .auto)
        config.env = ["WINEDEBUG": "+loaddll", "WINEPREFIX": "/evil", "MY": "1"]
        config.dllOverrides = ["winhttp": "builtin", "atl": "native"]
        let bottle = try BottleStore(paths: paths).create(config)
        let planner = LaunchPlanner(paths: paths, resolver: BackendResolver(paths: paths, host: m3), rules: RuleSet(),
                                    baseEnvironment: ["HOME": "/Users/x", "PATH": "/usr/bin", "WINEPREFIX": "/stale",
                                                      "DYLD_INSERT_LIBRARIES": "/x.dylib", "CX_ROOT": "/cx", "WINEDLLPATH": "/old"])
        let plan = planner.plan(bottle: bottle, engine: engine, program: "/tmp/game/Game.exe", args: ["-w"])
        let env = plan.environment
        XCTAssertEqual(plan.backend, .d3dmetal)
        XCTAssertEqual(env["WINEPREFIX"], bottle.prefix.path)           // never overridable
        XCTAssertEqual(env["WINEDEBUG"], "+loaddll")                    // bottle env wins over defaults
        XCTAssertEqual(env["MY"], "1")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["CX_ROOT"])
        XCTAssertEqual(env["MINUS196_DLL_PATH"], paths.backends.appendingPathComponent("gptk").path)
        XCTAssertEqual(env["CX_ACTIVE_GRAPHICS_BACKEND"], "d3dmetal")
        XCTAssertEqual(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"], paths.backends.appendingPathComponent("gptk/external/libd3dshared.dylib").path)
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "atl=native;winhttp=builtin")
        XCTAssertTrue(env["PATH"]!.hasPrefix(engine.root.appendingPathComponent("bin").path + ":"))
        XCTAssertEqual(plan.arguments, ["/tmp/game/Game.exe", "-w"])
        XCTAssertEqual(plan.workingDirectory?.path, "/tmp/game")
        XCTAssertEqual(plan.executable, engine.wine)
    }

    func testWinedDoesNotSetDllPath() throws {
        let engine = try fakeEngine()
        var config = BottleConfig(name: "Plain", backend: .wined3d); config.msync = false
        let bottle = try BottleStore(paths: paths).create(config)
        let planner = LaunchPlanner(paths: paths, resolver: BackendResolver(paths: paths, host: m3), rules: RuleSet(), baseEnvironment: [:])
        let env = planner.plan(bottle: bottle, engine: engine, program: "notepad").environment
        XCTAssertNil(env["WINEDLLPATH"]); XCTAssertNil(env["WINEMSYNC"]); XCTAssertNil(env["WINEDLLOVERRIDES"])
        XCTAssertEqual(env["WINEDEBUG"], "-all")
    }

    func testArgumentShapes() {
        XCTAssertEqual(LaunchPlanner.wineArguments(program: "notepad", args: []), ["notepad"])
        XCTAssertEqual(LaunchPlanner.wineArguments(program: "C:\\x\\a.EXE", args: ["1"]), ["C:\\x\\a.EXE", "1"])
        XCTAssertEqual(LaunchPlanner.wineArguments(program: "/t/setup.msi", args: ["/q"]), ["msiexec", "/i", "/t/setup.msi", "/q"])
        XCTAssertEqual(LaunchPlanner.wineArguments(program: "/t/run.bat", args: []), ["cmd", "/c", "/t/run.bat"])
        XCTAssertEqual(LaunchPlanner.wineArguments(program: "/t/readme.pdf", args: []), ["start", "/unix", "/t/readme.pdf"])
    }

    func testRulesApply() throws {
        let engine = try fakeEngine()
        try installBackend(.d3dmetal); try installBackend(.dxmt)
        let rules = RuleSet(rules: [AppRule(match: "Game.exe", note: "test", backend: "dxmt", env: ["R": "1", "WINEPREFIX": "/evil"],
                                            dllOverrides: ["winhttp": "native"], appendArgs: ["-dx11"])])
        XCTAssertNotNil(rules.firstMatch(program: "C:\\Games\\GAME.EXE"))
        XCTAssertNil(rules.firstMatch(program: "/x/othergame.exe"))
        var config = BottleConfig(name: "R"); config.dllOverrides = ["winhttp": "builtin"]
        let bottle = try BottleStore(paths: paths).create(config)
        let planner = LaunchPlanner(paths: paths, resolver: BackendResolver(paths: paths, host: m3), rules: rules, baseEnvironment: [:])
        let plan = planner.plan(bottle: bottle, engine: engine, program: "/g/Game.exe", args: ["-a"])
        XCTAssertEqual(plan.backend, .dxmt)
        XCTAssertEqual(plan.arguments, ["/g/Game.exe", "-a", "-dx11"])
        XCTAssertEqual(plan.environment["R"], "1")
        XCTAssertEqual(plan.environment["WINEPREFIX"], bottle.prefix.path)
        XCTAssertEqual(plan.environment["WINEDLLOVERRIDES"], "winhttp=native")
        XCTAssertEqual(plan.ruleNote, "test")
    }

    func testShortcutScan() throws {
        let prefix = tmp.appendingPathComponent("prefix")
        let menu = prefix.appendingPathComponent("drive_c/users/me/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Steam")
        let desktop = prefix.appendingPathComponent("drive_c/users/Public/Desktop")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data().write(to: menu.appendingPathComponent("Steam.lnk"))
        try Data().write(to: desktop.appendingPathComponent("Steam.lnk"))
        try Data().write(to: menu.appendingPathComponent("Uninstall Steam.lnk"))
        try Data("[InternetShortcut]\r\nURL=steam://rungameid/1\r\n".utf8).write(to: menu.appendingPathComponent("Game.url"))
        try Data("[InternetShortcut]\nURL=https://example.com\n".utf8).write(to: menu.appendingPathComponent("Homepage.url"))
        let found = ShortcutScanner().scan(prefix: prefix)
        XCTAssertEqual(found.map(\.name), ["Game", "Steam"])
        XCTAssertEqual(found[0].target, "steam://rungameid/1")
        XCTAssertTrue(found[1].target.hasSuffix("/Start Menu/Programs/Steam/Steam.lnk"))   // not the Desktop copy
        XCTAssertFalse(Bottle(config: BottleConfig(name: "x"), directory: tmp.appendingPathComponent("nope")).isRunning)
    }

    /// Builds a tiny archive laid out like a real engine archive and installs it.
    func testEngineSetupFromArchive() throws {
        let stage = tmp.appendingPathComponent("stage")
        for rel in ["engine/bin/wine", "engine/bin/wineserver", "engine/lib/wine/x86_64-unix/ntdll.so",
                    "engine/lib/wine/x86_64-windows/ntdll.dll", "backends/dxmt/x86_64-windows/d3d11.dll",
                    "backends/dxvk/x86_64-windows/d3d11.dll", "LICENSES/SOURCE.txt"] {
            try touch(stage.appendingPathComponent(rel))
        }
        let archive = tmp.appendingPathComponent("engine.tar.xz")
        XCTAssertEqual(try Shell.run("/usr/bin/tar", ["-C", stage.path, "-cJf", archive.path, "."]).status, 0)
        let installer = EngineInstaller(paths: paths)
        XCTAssertTrue(installer.isNeeded)

        let wrong = EngineRelease(version: "t-1", url: archive, sha256: String(repeating: "0", count: 64), bytes: 1)
        XCTAssertThrowsError(try installer.setUp(wrong)) { XCTAssertEqual($0 as? SetupError, .wrongChecksum) }
        XCTAssertTrue(installer.isNeeded)

        let release = EngineRelease(version: "t-1", url: archive, sha256: try EngineInstaller.sha256(of: archive), bytes: 1)
        var steps: [SetupStep] = []
        try installer.setUp(release) { steps.append($0) }
        XCTAssertEqual(steps.last, .unpacking)
        XCTAssertFalse(installer.isNeeded)
        let store = EngineStore(paths: paths)
        XCTAssertEqual(store.loadSettings().defaultEngine, "minus196-t-1")
        XCTAssertNil(try store.find("minus196-t-1").firstMissingFile())
        XCTAssertTrue(fm.fileExists(atPath: paths.backends.appendingPathComponent("dxmt/x86_64-windows/d3d11.dll").path))
        XCTAssertTrue(fm.fileExists(atPath: paths.engines.appendingPathComponent("minus196-t-1/LICENSES/SOURCE.txt").path))
        // Nothing is left behind in the data folder.
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: paths.root.path).contains { $0.hasPrefix("setup-") })
        XCTAssertFalse(AppleGraphicsInstaller(paths: paths).isInstalled)
    }
}
