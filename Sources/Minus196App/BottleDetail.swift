import AppKit
import Minus196Core
import SwiftUI

/// One thing the user can start: a pinned program or a shortcut an installer left behind.
struct AppTile: Identifiable {
    let id: String, name: String, iconPath: String?
    let program: String, args: [String], cwd: String?, pinned: Program?
}

struct BottleDetail: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var showingSettings = false

    private var isRunning: Bool { model.running.contains(bottle.name) }
    private var busy: String? { model.activity[bottle.name] }

    private var tiles: [AppTile] {
        var out = bottle.config.programs.map {
            AppTile(id: "pin:" + $0.path, name: $0.name, iconPath: nil, program: $0.path, args: $0.args,
                    cwd: $0.workingDirectory, pinned: $0)
        }
        let pinnedNames = Set(out.map { $0.name.lowercased() })
        for s in model.shortcuts[bottle.name] ?? [] where !pinnedNames.contains(s.name.lowercased()) {
            out.append(AppTile(id: "lnk:" + s.id, name: s.name, iconPath: s.iconPath, program: s.target, args: [], cwd: nil, pinned: nil))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let busy, busy != "Starting…" {
                VStack(spacing: 12) { ProgressView(); Text(busy).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tiles.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(tiles) { tile in TileView(bottle: bottle, tile: tile) }
                    }
                    .padding(24)
                }
            }
        }
        .sheet(isPresented: $showingSettings) { BottleSettings(bottleName: bottle.name) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    if isRunning { Circle().fill(.green).frame(width: 8, height: 8) }
                    Text(isRunning ? "Running" : (tiles.isEmpty ? "Nothing installed yet" : "\(tiles.count) \(tiles.count == 1 ? "app" : "apps")"))
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning {
                Button { model.stop(bottle) } label: { Label("Quit All", systemImage: "xmark.circle") }
                    .help("Close everything that is running in this bottle")
            }
            Button { model.runFile(in: bottle) } label: { Label("Install App…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .help("Choose a Windows installer or program you downloaded (.exe or .msi)")
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings for this bottle")
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("This bottle is empty").font(.title2.weight(.semibold))
            Text("Install a Windows app to get started. After installing, it shows up here and you start it with one click.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            HStack(spacing: 10) {
                Button { model.installSteam(in: bottle) } label: { Label("Install Steam", systemImage: "gamecontroller") }
                    .buttonStyle(.borderedProminent)
                    .help("Downloads the Steam installer from Valve and starts it")
                Button { model.runFile(in: bottle) } label: { Label("Install Another App…", systemImage: "square.and.arrow.down") }
            }
            .controlSize(.large).padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TileView: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    let tile: AppTile
    @State private var hovering = false

    private var key: String { bottle.name + "/" + tile.id }
    private var starting: Bool { model.launching.contains(key) }

    var body: some View {
        Button { model.launch(bottle, key: key, program: tile.program, args: tile.args, cwd: tile.cwd) } label: {
            VStack(spacing: 8) {
                ZStack {
                    AppIcon(name: tile.name, iconPath: tile.iconPath).opacity(starting ? 0.35 : 1)
                    if starting { ProgressView() }
                }
                .frame(width: 72, height: 72)
                Text(starting ? "Starting…" : tile.name)
                    .font(.callout).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundStyle(starting ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
            }
            .padding(10)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(starting)
        .onHover { hovering = $0 }
        .help("Open \(tile.name)")
        .contextMenu {
            Button("Open") { model.launch(bottle, key: key, program: tile.program, args: tile.args, cwd: tile.cwd) }
            if let pinned = tile.pinned {
                Button("Remove from This List") { model.update(bottle) { $0.programs.removeAll { $0 == pinned } } }
            }
        }
    }
}

/// The app's own icon when the shortcut names one, otherwise a coloured tile with its initial.
struct AppIcon: View {
    let name: String
    let iconPath: String?

    private static var cache: [String: NSImage] = [:]
    private var image: NSImage? {
        guard let iconPath else { return nil }
        if let hit = Self.cache[iconPath] { return hit }
        guard let loaded = NSImage(contentsOfFile: iconPath) else { return nil }
        // An .ico holds several sizes; draw from the largest.
        if let best = loaded.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) {
            loaded.size = NSSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        Self.cache[iconPath] = loaded
        return loaded
    }

    /// The same name always gets the same colour.
    private var hue: Double {
        Double(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                              Color(hue: hue, saturation: 0.75, brightness: 0.6)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Text(String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased())
                    .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white))
        }
    }
}

struct BottleSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bottleName: String
    @State private var confirmingDelete = false
    @State private var duplicating = false
    @State private var duplicateName = ""
    @State private var showingHelp = false

    var body: some View {
        if let bottle = model.bottles.first(where: { $0.name == bottleName }) {
            content(bottle)
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { dismiss() }
        }
    }

    private func choices(for bottle: Bottle) -> [BackendChoice] {
        BackendChoice.allCases.filter { choice in
            guard let backend = Backend(rawValue: choice.rawValue) else { return true }
            return choice == bottle.config.backend || model.backendStatus(backend, for: bottle).available
        }
    }

    /// A switch stored as a per-bottle environment variable: "1" when on, absent when off.
    private func envSwitch(_ bottle: Bottle, _ name: String) -> Binding<Bool> {
        Binding(get: { bottle.config.env[name] == "1" },
                set: { on in model.update(bottle) { $0.env[name] = on ? "1" : nil } })
    }

    private func content(_ bottle: Bottle) -> some View {
        let isRunning = model.running.contains(bottle.name)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings for “\(bottle.name)”").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Graphics").font(.headline)
                Picker("Graphics", selection: Binding(get: { bottle.config.backend },
                                                      set: { new in model.update(bottle) { $0.backend = new } })) {
                    ForEach(choices(for: bottle), id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text(bottle.config.backend.explanation).font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Windows version").font(.headline)
                Picker("Windows version", selection: Binding(get: { bottle.config.windowsVersion },
                                                             set: { model.setWindowsVersion(bottle, to: $0) })) {
                    ForEach(WindowsVersion.all, id: \.id) { Text($0.label).tag($0.id) }
                    if !WindowsVersion.all.contains(where: { $0.id == bottle.config.windowsVersion }) {
                        Text(bottle.config.windowsVersion).tag(bottle.config.windowsVersion)
                    }
                }
                .labelsHidden().fixedSize()
                Text("What apps in this bottle believe they are running on. Only change it if an app asks for a different Windows.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Speed boost", isOn: Binding(get: { bottle.config.msync }, set: { new in model.update(bottle) { $0.msync = new } }))
                    .font(.headline)
                Text("Makes games run smoother. Turn it off only if an app freezes or crashes. (MSync)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if model.resolvedBackend(for: bottle)?.backend == .d3dmetal {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Smart upscaling", isOn: envSwitch(bottle, "D3DM_ENABLE_METALFX")).font(.headline)
                    Text("Lets games offer DLSS, which raises the frame rate with little loss in sharpness. You still switch DLSS on in the game's own graphics options. (DLSS through MetalFX)")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show speed meter", isOn: envSwitch(bottle, "MTL_HUD_ENABLED")).font(.headline)
                Text("Shows frames per second in a corner of your games. (Metal HUD)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if isRunning {
                Label("Changes apply after you choose Quit All and open your app again.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            DisclosureGroup("Help with a problem", isExpanded: $showingHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Show Files") { NSWorkspace.shared.open(bottle.prefix.appendingPathComponent("drive_c")) }
                            .help("Opens this bottle's Windows drive (C:) in Finder")
                        Button("Add Existing App…") { model.pinProgram(in: bottle) }
                            .help("An installed app is missing from the list? Pick its .exe to add it")
                        Button("Show Error Report") {
                            if let log = model.latestLog(of: bottle) { NSWorkspace.shared.open(log) }
                            else { model.errorMessage = "Nothing has been run in this bottle yet." }
                        }
                        .help("Opens the notes from the last app that was started")
                    }
                    HStack(spacing: 8) {
                        Button("Windows Control Panel") { model.run(bottle, program: "winecfg") }
                        Button("Registry Editor") { model.run(bottle, program: "regedit") }
                    }
                }
                .padding(.top, 8)
            }

            Divider()

            HStack {
                Button("Duplicate…") { duplicateName = bottle.name + " copy"; duplicating = true }
                    .help("Make a full copy, for example before trying something risky")
                Spacer()
                Button("Delete Bottle…", role: .destructive) { confirmingDelete = true }
            }
        }
        .padding(22)
        .frame(width: 500)
        .confirmationDialog("Delete “\(bottle.name)”?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { dismiss(); model.delete(bottle) }
        } message: {
            Text("The bottle and every app installed in it move to the Trash. Anything still running in it is closed.")
        }
        .alert("Duplicate “\(bottle.name)”", isPresented: $duplicating) {
            TextField("Name of the copy", text: $duplicateName)
            Button("Duplicate") {
                let name = duplicateName.trimmingCharacters(in: .whitespaces)
                if BottleStore.isValidName(name) { dismiss(); model.duplicate(bottle, as: name) }
                else { model.errorMessage = "Please use only letters, numbers, spaces, - _ and . in the name." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isRunning ? "Apps running in this bottle are closed first." : "Makes a full copy of this bottle and everything in it.")
        }
    }
}
