import AppKit
import Minus196Core
import SwiftUI

@main
struct Minus196App: App {
    @StateObject private var model = AppModel()

    init() {
        // Started from a plain executable (swift run) there is no bundle to make this a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("-196") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 500)
                .onAppear {
                    model.start()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { NotificationCenter.default.post(name: .newBottle, object: nil) }
                    .keyboardShortcut("n")
                Button("Add Apple’s Graphics…") { NotificationCenter.default.post(name: .appleGraphics, object: nil) }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.reload() }.keyboardShortcut("r")
            }
        }
    }
}

extension Notification.Name {
    static let newBottle = Notification.Name("minus196.newBottle")
    static let appleGraphics = Notification.Name("minus196.appleGraphics")
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingNewBottle = false
    @State private var showingAppleGraphics = false

    private var pendingNames: [String] {
        model.activity.keys.sorted().filter { name in !model.bottles.contains { $0.name == name } }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Bottles") {
                    ForEach(model.bottles, id: \.name) { bottle in
                        BottleRow(bottle: bottle).tag(bottle.name)
                    }
                    ForEach(pendingNames, id: \.self) { name in
                        HStack { ProgressView().controlSize(.small); Text(name).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            .safeAreaInset(edge: .bottom) {
                Button { showingNewBottle = true } label: {
                    Label("New Bottle", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
                .disabled(!model.hasEngine)
                .help("A bottle is a separate little Windows for your apps")
            }
        } detail: {
            if !model.hasEngine {
                SetupView()
            } else if let bottle = model.selected {
                BottleDetail(bottle: bottle).id(bottle.name)
            } else if let name = pendingNames.first {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Setting up “\(name)”…").font(.title3.weight(.semibold))
                    Text("This takes about a minute.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Message(symbol: "wineglass", title: "Run Windows apps on your Mac",
                        text: "Start by creating a bottle: a separate little Windows that your apps and games get installed into.",
                        action: ("Create a Bottle", { showingNewBottle = true }))
            }
        }
        .sheet(isPresented: $showingNewBottle) { NewBottleSheet() }
        .sheet(isPresented: $showingAppleGraphics) { AppleGraphicsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .newBottle)) { _ in if model.hasEngine { showingNewBottle = true } }
        .onReceive(NotificationCenter.default.publisher(for: .appleGraphics)) { _ in showingAppleGraphics = true }
        .alert("That didn't work", isPresented: Binding(get: { model.errorMessage != nil },
                                                        set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

/// First start: nothing can run until the engine has been downloaded.
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    private var megabytes: Int { Int(EngineRelease.current.bytes / 1_000_000) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Welcome to -196").font(.title2.weight(.semibold))
            if let step = model.setupStep {
                switch step {
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 280)
                    Text("Downloading… \(Int(fraction * 100))%").foregroundStyle(.secondary)
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking the download…").foregroundStyle(.secondary)
                case .unpacking:
                    ProgressView().controlSize(.small)
                    Text("Unpacking… this takes about a minute.").foregroundStyle(.secondary)
                }
            } else {
                Text("To run Windows apps, -196 first has to download the part that does the work. It is about \(megabytes) MB and only has to be downloaded once.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                if let problem = model.setupProblem {
                    Text(problem).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 400)
                }
                if !HostInfo.hasRosetta {
                    VStack(spacing: 6) {
                        Text("This Mac also needs Rosetta, Apple’s free add-on for running apps made for Intel Macs. Open the Terminal app, paste this line and press Return:")
                            .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 400)
                        HStack {
                            Text("softwareupdate --install-rosetta").font(.callout.monospaced()).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("softwareupdate --install-rosetta", forType: .string)
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Button(model.setupProblem == nil ? "Download and Set Up" : "Try Again") { model.setUp() }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
                Text("Downloaded from the -196 page on GitHub. It is the free Wine software, plus graphics add-ons (DXMT, DXVK), and takes about 1 GB on your disk.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 400).padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Apple's graphics part (D3DMetal) may not be included or downloaded by -196, so the user
/// fetches Apple's file themselves and hands it over here.
struct AppleGraphicsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Apple’s Graphics").font(.title2.weight(.semibold))
            Text("The newest games (the ones that need DirectX 12) and DLSS use a part made by Apple. -196 isn’t allowed to include it or download it for you, but you can get it for free with your Apple Account. Everything else works without it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.hasAppleGraphics {
                Label("Apple’s graphics are added on this Mac.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("1.").bold()
                    Text("Open Apple’s download page and sign in.")
                    Spacer()
                    Button("Open Apple’s Page") {
                        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("2.").bold()
                    Text("Download “Game Porting Toolkit”. Apple asks you to agree to its terms.")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("3.").bold()
                    Text("Choose the file you downloaded.")
                    Spacer()
                    if model.addingAppleGraphics { ProgressView().controlSize(.small) }
                    Button(model.hasAppleGraphics ? "Choose a Newer File…" : "Choose File…") { model.addAppleGraphics() }
                        .disabled(model.addingAppleGraphics)
                }
            }
            .padding(.vertical, 4)
            Text("The file ends in .dmg. Apple’s part stays on this Mac. (D3DMetal, from Apple’s Game Porting Toolkit)")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct Message: View {
    let symbol: String, title: String, text: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let action {
                Button(action.label, action: action.run).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BottleRow: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wineglass")
            Text(bottle.name).lineLimit(1)
            Spacer()
            if model.activity[bottle.name] != nil {
                ProgressView().controlSize(.small)
            } else if model.running.contains(bottle.name) {
                Circle().fill(.green).frame(width: 8, height: 8).help("Something is running in this bottle")
            }
        }
    }
}

struct NewBottleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var version = "win10"
    @State private var arch = WineArch.win64
    @State private var showingMore = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var problem: String? {
        if trimmed.isEmpty { return nil }
        if !BottleStore.isValidName(trimmed) { return "Please use only letters, numbers, spaces, - _ and ." }
        if model.bottles.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) { return "You already have a bottle with this name." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Bottle").font(.title2.weight(.semibold))
            Text("A bottle is a separate little Windows. Each bottle has its own settings and installed apps, so many people use one per app or one for all their games. Apps in a bottle can still reach your files, so only run apps you trust.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name, for example “Games”", text: $name).textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            DisclosureGroup("More options", isExpanded: $showingMore) {
                Form {
                    Picker("Windows version", selection: $version) {
                        ForEach(WindowsVersion.all, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("For", selection: $arch) {
                        Text("Current apps (recommended)").tag(WineArch.win64)
                        Text("Very old apps only (32-bit)").tag(WineArch.win32)
                    }
                }
                .padding(.top, 6)
            }
            HStack {
                Text("Takes about a minute.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.create(BottleConfig(name: trimmed, arch: arch, windowsVersion: version))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

enum WindowsVersion {
    static let all: [(id: String, label: String)] = [
        ("win11", "Windows 11"), ("win10", "Windows 10 (recommended)"), ("win81", "Windows 8.1"), ("win8", "Windows 8"),
        ("win7", "Windows 7"), ("winxp64", "Windows XP (64-bit)"), ("winxp", "Windows XP"),
    ]
}

extension BackendChoice {
    /// Plain-language names; the technical name stays visible in small print for troubleshooting.
    var label: String {
        switch self {
        case .auto: return "Automatic (recommended)"
        case .d3dmetal: return "Newest games"
        case .dxmt: return "Fast"
        case .dxvk: return "Alternative"
        case .wined3d: return "Basic"
        }
    }

    var explanation: String {
        switch self {
        case .auto: return "Picks the best option this Mac has."
        case .d3dmetal: return "For games that need DirectX 12. (D3DMetal)"
        case .dxmt: return "Best choice for most games. (DXMT)"
        case .dxvk: return "Try this if a game looks wrong or won't start with “Fast”. (DXVK)"
        case .wined3d: return "Slow, but works with nearly everything. Good for old apps. (Wine's own)"
        }
    }
}
