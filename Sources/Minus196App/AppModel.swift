import AppKit
import Minus196Core
import SwiftUI
import UniformTypeIdentifiers

/// What the window shows. All Wine work goes through Minus196Core on a background queue; this
/// object only holds the results and is touched on the main thread.
@MainActor
final class AppModel: ObservableObject {
    @Published var bottles: [Bottle] = []
    /// Remembered between launches.
    @Published var selection: String? = UserDefaults.standard.string(forKey: "selectedBottle") {
        didSet { if let selection { UserDefaults.standard.set(selection, forKey: "selectedBottle") } }
    }
    @Published var running: Set<String> = []
    @Published var shortcuts: [String: [Shortcut]] = [:]
    /// Bottle name -> what is being done to it right now ("Creating…").
    @Published var activity: [String: String] = [:]
    @Published var errorMessage: String?
    @Published var hasEngine = true
    /// First-time setup (downloading the engine): nil when idle.
    @Published var setupStep: SetupStep?
    @Published var setupProblem: String?
    @Published var hasAppleGraphics = false
    @Published var addingAppleGraphics = false
    /// Tiles showing "Starting…" (bottle name + "/" + tile id).
    @Published var launching: Set<String> = []

    let paths = Paths()
    private let work = DispatchQueue(label: "minus196.work", qos: .userInitiated, attributes: .concurrent)
    private var timer: Timer?

    var selected: Bottle? { bottles.first { $0.name == selection } }

    func start() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    func reload() {
        bottles = (try? BottleStore(paths: paths).list()) ?? []
        hasEngine = !EngineStore(paths: paths).list().isEmpty
        hasAppleGraphics = AppleGraphicsInstaller(paths: paths).isInstalled
        if selected == nil { selection = bottles.first?.name }
        refreshRunning()
        for bottle in bottles { rescan(bottle) }
    }

    func refreshRunning() {
        let now = Set(bottles.filter(\.isRunning).map(\.name))
        if now != running { running = now }
    }

    func rescan(_ bottle: Bottle) {
        let name = bottle.name, prefix = bottle.prefix
        work.async {
            let found = ShortcutScanner().scan(prefix: prefix)
            DispatchQueue.main.async { if self.shortcuts[name] != found { self.shortcuts[name] = found } }
        }
    }

    /// Runs `body` off the main thread, showing `label` on the bottle while it runs.
    private func perform(_ label: String?, on name: String, then: (() -> Void)? = nil,
                         _ body: @escaping (Launcher) throws -> Void) {
        if let label { activity[name] = label }
        let paths = self.paths
        work.async {
            var failure: String?
            do { try body(Launcher(paths: paths)) } catch let e as Minus196Error { failure = e.description } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if label != nil { self.activity[name] = nil }
                if let failure { self.errorMessage = failure }
                self.reload()
                then?()
            }
        }
    }

    // MARK: setup

    /// Downloads the engine and installs it. Shown on first start, when nothing can run yet.
    func setUp() {
        guard setupStep == nil else { return }
        setupProblem = nil
        setupStep = .downloading(fraction: 0)
        let paths = self.paths
        work.async {
            var failure: String?
            do {
                try EngineInstaller(paths: paths).setUp { step in DispatchQueue.main.async { self.setupStep = step } }
            } catch let e as SetupError { failure = e.description } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.setupStep = nil
                self.setupProblem = failure
                self.reload()
            }
        }
    }

    /// Lets the user pick the Game Porting Toolkit file they downloaded from Apple and installs
    /// Apple's graphics part from it.
    func addAppleGraphics() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Game Porting Toolkit file you downloaded from Apple"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.diskImage]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let image = panel.url else { return }
        addingAppleGraphics = true
        let paths = self.paths
        work.async {
            var failure: String?
            do { try AppleGraphicsInstaller(paths: paths).install(from: image) }
            catch let e as SetupError { failure = e.description } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.addingAppleGraphics = false
                if let failure { self.errorMessage = failure }
                self.reload()
            }
        }
    }

    func run(_ bottle: Bottle, program: String, args: [String] = [], cwd: String? = nil) {
        let name = bottle.name
        perform("Starting…", on: name) { launcher in
            try launcher.run(bottleName: name, program: program, args: args,
                             workingDirectory: cwd.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Starts a tile's program and shows "Starting…" on it for a moment: Windows apps take a
    /// few seconds to put up their first window, and without feedback people click again.
    func launch(_ bottle: Bottle, key: String, program: String, args: [String], cwd: String?) {
        launching.insert(key)
        run(bottle, program: program, args: args, cwd: cwd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.launching.remove(key) }
    }

    /// Downloads Valve's Steam installer and starts it in the bottle.
    func installSteam(in bottle: Bottle) {
        let name = bottle.name
        let folder = bottle.directory.appendingPathComponent("downloads", isDirectory: true)
        let file = folder.appendingPathComponent("SteamSetup.exe")
        activity[name] = "Downloading Steam…"
        let url = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
        URLSession.shared.downloadTask(with: url) { temp, response, error in
            var failure: String?
            if let temp, (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: temp, to: file)
                } catch { failure = error.localizedDescription }
            } else {
                failure = "Steam could not be downloaded. Check your internet connection and try again."
            }
            DispatchQueue.main.async {
                self.activity[name] = nil
                if let failure { self.errorMessage = failure; return }
                self.run(bottle, program: file.path)
            }
        }.resume()
    }

    func stop(_ bottle: Bottle) {
        let name = bottle.name
        perform("Stopping…", on: name) { try $0.stop(bottleName: name) }
    }

    func create(_ config: BottleConfig) {
        let name = config.name
        selection = nil
        activity[name] = "Creating…"
        perform("Creating…", on: name, then: { self.selection = name }) { _ = try $0.createBottle(config) }
    }

    func duplicate(_ bottle: Bottle, as newName: String) {
        let name = bottle.name
        perform("Duplicating…", on: name, then: { self.selection = newName }) { launcher in
            try? launcher.stop(bottleName: name)          // a copy of a live prefix would be inconsistent
            _ = try launcher.store.duplicate(name, as: newName)
        }
    }

    func delete(_ bottle: Bottle) {
        let name = bottle.name
        perform("Deleting…", on: name, then: { self.selection = self.bottles.first?.name }) { launcher in
            try? launcher.stop(bottleName: name, force: true)
            try launcher.store.delete(name)
        }
    }

    /// Changes a bottle's stored settings. They apply the next time the bottle starts.
    func update(_ bottle: Bottle, _ change: (inout BottleConfig) -> Void) {
        var copy = bottle
        change(&copy.config)
        guard copy != bottle else { return }
        do { try BottleStore(paths: paths).save(copy) } catch { errorMessage = error.localizedDescription }
        reload()
    }

    /// The Windows version also lives inside the prefix, so it is set there through winecfg.
    func setWindowsVersion(_ bottle: Bottle, to version: String) {
        let name = bottle.name
        update(bottle) { $0.windowsVersion = version }
        perform("Applying…", on: name) { launcher in
            _ = try launcher.run(bottleName: name, program: "winecfg", args: ["/v", version], wait: true)
        }
    }

    // MARK: choosing files

    /// Lets the user pick a Windows program or installer, starting inside the bottle's C: drive.
    func chooseFile(in bottle: Bottle, title: String, startInBottle: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startInBottle ? bottle.prefix.appendingPathComponent("drive_c")
                                           : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    func runFile(in bottle: Bottle) {
        guard let url = chooseFile(in: bottle, title: "Choose a Windows installer or app (.exe or .msi)", startInBottle: false) else { return }
        run(bottle, program: url.path)
    }

    func pinProgram(in bottle: Bottle) {
        guard let url = chooseFile(in: bottle, title: "Choose the app to add (.exe)", startInBottle: true) else { return }
        let entry = Program(name: url.deletingPathExtension().lastPathComponent, path: url.path)
        update(bottle) { config in
            config.programs.removeAll { $0.path == entry.path }
            config.programs.append(entry)
        }
    }

    func latestLog(of bottle: Bottle) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bottle.logs.path)) ?? []
        return names.filter { $0.hasSuffix(".log") }.sorted().last.map { bottle.logs.appendingPathComponent($0) }
    }

    /// What "Automatic" (or the chosen backend) turns into on this Mac, for display.
    func resolvedBackend(for bottle: Bottle) -> (backend: Backend, note: String)? {
        guard let engine = try? EngineStore(paths: paths).resolve(for: bottle.config) else { return nil }
        return BackendResolver(paths: paths).resolve(choice: bottle.config.backend, engine: engine, arch: bottle.config.arch)
    }

    func backendStatus(_ backend: Backend, for bottle: Bottle) -> BackendStatus {
        let engine = try? EngineStore(paths: paths).resolve(for: bottle.config)
        return BackendResolver(paths: paths).status(of: backend, engine: engine, arch: bottle.config.arch)
    }
}
