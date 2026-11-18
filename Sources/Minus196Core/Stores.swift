import Foundation

/// A game store whose Windows installer -196 can fetch from the store's own server.
public struct GameStore: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let maker: String
    public let installer: URL
    public let fileName: String
    public var isMSI: Bool { fileName.lowercased().hasSuffix(".msi") }

    public static let steam = GameStore(
        id: "steam", name: "Steam", maker: "Valve",
        installer: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!,
        fileName: "SteamSetup.exe")

    public static let all: [GameStore] = [
        steam,
        GameStore(id: "epic", name: "Epic Games", maker: "Epic Games",
                  installer: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
                  fileName: "EpicGamesLauncherInstaller.msi"),
        GameStore(id: "gog", name: "GOG Galaxy", maker: "GOG",
                  installer: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
                  fileName: "GOG_Galaxy_2.0.exe"),
        GameStore(id: "battlenet", name: "Battle.net", maker: "Blizzard",
                  installer: URL(string: "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!,
                  fileName: "Battle.net-Setup.exe"),
        GameStore(id: "ea", name: "EA app", maker: "Electronic Arts",
                  installer: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
                  fileName: "EAappInstaller.exe"),
        GameStore(id: "ubisoft", name: "Ubisoft Connect", maker: "Ubisoft",
                  installer: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
                  fileName: "UbisoftConnectInstaller.exe"),
    ]

    /// Downloads the installer into the bottle's downloads folder and returns the file. Blocks.
    public func download(into bottle: Bottle, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let folder = bottle.directory.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName)
        let partial = folder.appendingPathComponent(fileName + ".part")
        try? fm.removeItem(at: partial)
        try Downloader.fetch(installer, to: partial, progress: progress)
        // A sign-in page or an error page is not an installer: Windows programs start with "MZ",
        // installer packages (.msi) with the bytes D0 CF 11 E0.
        let start = (try? FileHandle(forReadingFrom: partial))?.readData(ofLength: 4) ?? Data()
        let expected: [UInt8] = isMSI ? [0xD0, 0xCF, 0x11, 0xE0] : [0x4D, 0x5A]
        guard Array(start.prefix(expected.count)) == expected else {
            try? fm.removeItem(at: partial)
            throw SetupError.downloadFailed("\(maker)'s server did not send an installer")
        }
        try? fm.removeItem(at: file)
        try fm.moveItem(at: partial, to: file)
        return file
    }
}
