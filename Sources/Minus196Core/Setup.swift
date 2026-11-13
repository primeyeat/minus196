import CryptoKit
import Foundation

/// One published engine archive: the Wine engine plus the open graphics layers (DXMT, DXVK),
/// made by engine/package-engine.sh and attached to a release of the -196 repository.
public struct EngineRelease: Equatable {
    public let version: String
    public let url: URL
    public let sha256: String
    public let bytes: Int64

    /// The name the engine gets in <root>/engines.
    public var engineName: String { "minus196-\(version)" }

    public static let current = EngineRelease(
        version: "26.3-1",
        url: URL(string: "https://github.com/primeyeat/minus196/releases/download/engine-26.3-1/minus196-engine-26.3-1.tar.xz")!,
        sha256: "d36ff618171d0a4a512093d6b12c8a68b96d7f21f21f77923fff7904179e27bf",
        bytes: 190_562_276)
}

public enum SetupStep: Equatable {
    case downloading(fraction: Double)
    case checking
    case unpacking
}

public enum SetupError: Error, CustomStringConvertible, Equatable {
    case downloadFailed(String)
    case wrongChecksum
    case unpackFailed(String)
    case badArchive(String)
    case notAToolkitImage(String)
    case notFromApple
    case toolFailed(String)

    public var description: String {
        switch self {
        case .downloadFailed(let why): return "The download didn't finish (\(why)). Check your internet connection and try again."
        case .wrongChecksum: return "The downloaded file is damaged or is not the file -196 expects, so it was not used. Please try again."
        case .unpackFailed(let why): return "The downloaded file could not be unpacked (\(why))."
        case .badArchive(let why): return "The downloaded file does not look right (\(why))."
        case .notAToolkitImage(let why): return "This is not Apple's Game Porting Toolkit file (\(why))."
        case .notFromApple: return "These files are not signed by Apple, so they were not installed."
        case .toolFailed(let what): return "\(what) failed."
        }
    }
}

/// Downloads, checks and installs an engine archive.
public struct EngineInstaller {
    public let paths: Paths
    private let fm = FileManager.default

    public init(paths: Paths = Paths()) { self.paths = paths }

    /// True when no engine is installed, so nothing can run yet.
    public var isNeeded: Bool { EngineStore(paths: paths).list().isEmpty }

    /// The whole first-time setup. Blocks; call it off the main thread.
    public func setUp(_ release: EngineRelease = .current, source: URL? = nil,
                      progress: @escaping (SetupStep) -> Void = { _ in }) throws {
        try paths.ensureLayout()
        let work = paths.root.appendingPathComponent("setup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("engine.tar.xz")

        progress(.downloading(fraction: 0))
        try Downloader.fetch(source ?? release.url, to: archive) { progress(.downloading(fraction: $0)) }
        progress(.checking)
        guard try Self.sha256(of: archive) == release.sha256.lowercased() else { throw SetupError.wrongChecksum }
        progress(.unpacking)
        try install(archive: archive, release: release, workFolder: work)
    }

    /// Unpacks a checked archive and moves its parts into place.
    func install(archive: URL, release: EngineRelease, workFolder: URL) throws {
        let unpacked = workFolder.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let result = try Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", unpacked.path])
        guard result.status == 0 else { throw SetupError.unpackFailed(result.lastLine) }

        let engine = Engine(name: release.engineName, root: unpacked.appendingPathComponent("engine", isDirectory: true))
        if let missing = engine.firstMissingFile() { throw SetupError.badArchive("\(missing) is missing") }

        let destination = paths.engines.appendingPathComponent(release.engineName, isDirectory: true)
        // A folder of this name can only be an earlier, possibly half-finished, copy of the same release.
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil { try fm.removeItem(at: destination) }
        try fm.moveItem(at: engine.root, to: destination)

        // Graphics layers: never replace ones that are already there.
        for name in ["dxmt", "dxvk"] {
            let from = unpacked.appendingPathComponent("backends/\(name)", isDirectory: true)
            let to = paths.backends.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try fm.moveItem(at: from, to: to) }
        }
        let licences = unpacked.appendingPathComponent("LICENSES", isDirectory: true)
        if fm.fileExists(atPath: licences.path) {
            try? fm.copyItem(at: licences, to: destination.appendingPathComponent("LICENSES", isDirectory: true))
        }
        let store = EngineStore(paths: paths)
        if store.loadSettings().defaultEngine.flatMap({ try? store.find($0) }) == nil {
            try store.setDefault(release.engineName)
        }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Installs Apple's D3DMetal from a Game Porting Toolkit disk image the user downloaded with
/// their own Apple account. The files stay on this Mac; -196 never downloads or ships them.
public struct AppleGraphicsInstaller {
    public let paths: Paths
    private let fm = FileManager.default

    public init(paths: Paths = Paths()) { self.paths = paths }

    public var isInstalled: Bool {
        fm.fileExists(atPath: paths.backends.appendingPathComponent("gptk/x86_64-windows/d3d12.dll").path)
            && fm.fileExists(atPath: paths.backends.appendingPathComponent("gptk/external/libd3dshared.dylib").path)
    }

    /// Accepts the "Game Porting Toolkit" image (which holds the evaluation environment image)
    /// or the "Evaluation environment for Windows games" image itself. Returns the version name.
    @discardableResult
    public func install(from image: URL) throws -> String {
        try paths.ensureLayout()
        let work = fm.temporaryDirectory.appendingPathComponent("minus196-gptk-\(UUID().uuidString)", isDirectory: true)
        let outer = work.appendingPathComponent("outer"), inner = work.appendingPathComponent("inner")
        try fm.createDirectory(at: outer, withIntermediateDirectories: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        defer {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", inner.path])
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", outer.path])
            try? fm.removeItem(at: work)
        }
        func attach(_ file: URL, at mount: URL) throws {
            let r = try Shell.run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                                                       "-mountpoint", mount.path, file.path])
            guard r.status == 0 else { throw SetupError.notAToolkitImage("it could not be opened as a disk image") }
        }
        try attach(image, at: outer)
        var root = outer
        var version = image.deletingPathExtension().lastPathComponent
        if !fm.fileExists(atPath: root.appendingPathComponent("redist/lib").path) {
            let names = (try? fm.contentsOfDirectory(atPath: outer.path)) ?? []
            guard let nested = names.first(where: { $0.hasPrefix("Evaluation environment") && $0.hasSuffix(".dmg") }) else {
                throw SetupError.notAToolkitImage("the graphics files are not in it")
            }
            try attach(outer.appendingPathComponent(nested), at: inner)
            root = inner
            version = String(nested.dropLast(4))
        }
        let lib = root.appendingPathComponent("redist/lib")
        for rel in ["external/libd3dshared.dylib", "external/D3DMetal.framework", "wine/x86_64-windows/d3d12.dll"] {
            guard fm.fileExists(atPath: lib.appendingPathComponent(rel).path) else {
                throw SetupError.notAToolkitImage("\(rel) is missing")
            }
        }
        // The files are loaded into every game, so they must really be Apple's.
        let dylib = lib.appendingPathComponent("external/libd3dshared.dylib").path
        let framework = lib.appendingPathComponent("external/D3DMetal.framework").path
        guard try Shell.run("/usr/bin/codesign", ["--verify", "-R=anchor apple", dylib]).status == 0,
              try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "-R=anchor apple", framework]).status == 0 else {
            throw SetupError.notFromApple
        }

        // Build the new folder beside the old one and swap at the end.
        let destination = paths.backends.appendingPathComponent("gptk", isDirectory: true)
        let staged = paths.backends.appendingPathComponent("gptk-new-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staged.appendingPathComponent("x86_64-unix"), withIntermediateDirectories: true)
            for (from, to) in [("external", "external"), ("wine/x86_64-windows", "x86_64-windows")] {
                let r = try Shell.run("/usr/bin/ditto", [lib.appendingPathComponent(from).path, staged.appendingPathComponent(to).path])
                guard r.status == 0 else { throw SetupError.toolFailed("Copying Apple's files") }
            }
            // In Apple's layout the Unix halves are links to ../../external/libd3dshared.dylib;
            // ours sit one level higher, so the links are made again.
            let unixNames = (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("wine/x86_64-unix").path)) ?? []
            for name in unixNames where name.hasSuffix(".so") {
                try fm.createSymbolicLink(atPath: staged.appendingPathComponent("x86_64-unix/\(name)").path,
                                          withDestinationPath: "../external/libd3dshared.dylib")
            }
            // DLSS through Apple's MetalFX: the bridge has to be found under the name games ask for.
            let bridge = staged.appendingPathComponent("x86_64-windows/nvngx-on-metalfx.dll")
            if fm.fileExists(atPath: bridge.path) {
                try fm.copyItem(at: bridge, to: staged.appendingPathComponent("x86_64-windows/nvngx.dll"))
                try fm.createSymbolicLink(atPath: staged.appendingPathComponent("x86_64-unix/nvngx.so").path,
                                          withDestinationPath: "../external/libd3dshared.dylib")
            }
            try? fm.copyItem(at: root.appendingPathComponent("License.rtf"), to: staged.appendingPathComponent("License.rtf"))
            try Data((version + "\n").utf8).write(to: staged.appendingPathComponent("VERSION"))
            if (try? fm.attributesOfItem(atPath: destination.path)) != nil { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staged, to: destination)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return version
    }
}

enum Shell {
    struct Result { let status: Int32; let output: String
        var lastLine: String { output.split(separator: "\n").last.map(String.init) ?? "exit code \(status)" } }

    static func run(_ tool: String, _ arguments: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// A blocking download with progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: (Double) -> Void
    private let done = DispatchSemaphore(value: 0)
    private var failure: SetupError?
    private var lastReported = -1.0

    private init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) throws {
        if url.isFileURL {                                   // a local archive (tests, offline installs)
            try FileManager.default.copyItem(at: url, to: destination)
            progress(1)
            return
        }
        guard url.scheme == "https" else { throw SetupError.downloadFailed("not a secure address") }
        let delegate = Downloader(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        delegate.done.wait()
        session.finishTasksAndInvalidate()
        if let failure = delegate.failure { throw failure }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.005 { lastReported = fraction; progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { failure = .downloadFailed("the server answered \(status)"); return }
        do { try FileManager.default.moveItem(at: location, to: destination) }
        catch { failure = .downloadFailed(error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { failure = .downloadFailed(error.localizedDescription) }
        done.signal()
    }
}
