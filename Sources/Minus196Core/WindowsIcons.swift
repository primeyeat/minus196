import Foundation

/// Reads little-endian numbers out of untrusted file data; every read is bounds-checked.
struct ByteReader {
    let data: Data
    init(_ data: Data) { self.data = data }

    func u8(_ at: Int) -> Int? { at >= 0 && at < data.count ? Int(data[data.startIndex + at]) : nil }
    func u16(_ at: Int) -> Int? {
        guard let a = u8(at), let b = u8(at + 1) else { return nil }
        return a | b << 8
    }
    func u32(_ at: Int) -> Int? {
        guard let a = u16(at), let b = u16(at + 2) else { return nil }
        return a | b << 16
    }
    func bytes(_ at: Int, _ count: Int) -> Data? {
        guard at >= 0, count >= 0, count <= data.count, at <= data.count - count else { return nil }
        return data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + count))
    }
}

/// Pulls the main icon out of a Windows program (.exe or .dll) as an .ico file's bytes.
public enum WindowsIcon {
    /// Returns nil for anything that is not a program with an icon.
    public static func icon(inProgramAt path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return icon(inProgram: data)
    }

    static func icon(inProgram data: Data) -> Data? {
        let r = ByteReader(data)
        guard r.u16(0) == 0x5A4D, let pe = r.u32(0x3C), r.u32(pe) == 0x0000_4550,
              let sectionCount = r.u16(pe + 6), sectionCount <= 96, let optionalSize = r.u16(pe + 20) else { return nil }
        let optional = pe + 24
        let directories: Int
        switch r.u16(optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }
        guard let resourceRVA = r.u32(directories + 2 * 8), resourceRVA != 0 else { return nil }

        // Section table: turns addresses in the loaded program into places in the file.
        var sections: [(rva: Int, size: Int, file: Int)] = []
        for i in 0..<sectionCount {
            let s = optional + optionalSize + i * 40
            guard let virtualSize = r.u32(s + 8), let rva = r.u32(s + 12), let rawSize = r.u32(s + 16), let raw = r.u32(s + 20) else { return nil }
            sections.append((rva, max(virtualSize, rawSize), raw))
        }
        func offset(_ rva: Int) -> Int? {
            for s in sections where rva >= s.rva && rva < s.rva + s.size { return rva - s.rva + s.file }
            return nil
        }
        guard let root = offset(resourceRVA) else { return nil }

        /// Entries of one resource folder: (id, or nil for a named entry; offset; is a folder).
        func entries(_ directory: Int) -> [(id: Int?, at: Int, isFolder: Bool)] {
            guard let named = r.u16(directory + 12), let ids = r.u16(directory + 14), named + ids <= 4096 else { return [] }
            var out: [(Int?, Int, Bool)] = []
            for i in 0..<(named + ids) {
                let e = directory + 16 + i * 8
                guard let name = r.u32(e), let to = r.u32(e + 4) else { break }
                out.append((name & 0x8000_0000 == 0 ? name : nil, root + (to & 0x7FFF_FFFF), to & 0x8000_0000 != 0))
            }
            return out
        }
        /// The bytes of the first language version under a resource's folder.
        func firstData(under folder: Int) -> Data? {
            guard let language = entries(folder).first, !language.isFolder,
                  let rva = r.u32(language.at), let size = r.u32(language.at + 4), size <= 4_000_000,
                  let at = offset(rva) else { return nil }
            return r.bytes(at, size)
        }
        let types = entries(root)
        guard let groups = types.first(where: { $0.id == 14 && $0.isFolder }),          // RT_GROUP_ICON
              let icons = types.first(where: { $0.id == 3 && $0.isFolder }),            // RT_ICON
              let firstGroup = entries(groups.at).first, firstGroup.isFolder,
              let group = firstData(under: firstGroup.at) else { return nil }

        // The group lists the same picture at several sizes; take the largest, then the deepest.
        let g = ByteReader(group)
        guard g.u16(2) == 1, let count = g.u16(4), count > 0, count <= 64 else { return nil }
        var best: (entry: Data, width: Int, depth: Int, id: Int)?
        for i in 0..<count {
            let e = 6 + i * 14
            guard let width = g.u8(e), let depth = g.u16(e + 6), let id = g.u16(e + 12), let entry = g.bytes(e, 12) else { break }
            let real = width == 0 ? 256 : width
            if best == nil || (real, depth) > (best!.width, best!.depth) { best = (entry, real, depth, id) }
        }
        guard let best, let folder = entries(icons.at).first(where: { $0.id == best.id && $0.isFolder }),
              let image = firstData(under: folder.at), !image.isEmpty else { return nil }

        // An .ico file: a 6-byte header, one 16-byte entry (the group's 12 bytes + where the
        // picture starts), then the picture.
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(best.entry)
        ico.append(contentsOf: [22, 0, 0, 0])
        ico.append(image)
        return ico
    }
}

/// The parts of a Windows shortcut (.lnk) needed to find its icon.
public struct WindowsShortcut: Equatable {
    /// The program the shortcut starts, as a Windows path ("C:\Games\x.exe").
    public var target: String?
    /// The file its icon comes from, when the shortcut names one.
    public var iconLocation: String?

    public init?(contentsOf url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? .max) <= 1_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        let r = ByteReader(data)
        guard r.u32(0) == 0x4C, let flags = r.u32(0x14) else { return nil }
        var at = 0x4C
        if flags & 0x01 != 0 {                                   // list of folder items: skip
            guard let size = r.u16(at) else { return nil }
            at += 2 + size
        }
        if flags & 0x02 != 0 {                                   // where the target is
            guard let size = r.u32(at), size >= 0x1C, let headerSize = r.u32(at + 4), let infoFlags = r.u32(at + 8),
                  let info = r.bytes(at, size) else { return nil }
            let i = ByteReader(info)
            func ansi(_ offset: Int?) -> String? {
                guard let offset, offset > 0, offset < info.count else { return nil }
                let rest = info[(info.startIndex + offset)...]
                return String(bytes: rest.prefix { $0 != 0 }, encoding: .windowsCP1252)
            }
            func wide(_ offset: Int?) -> String? {
                guard let offset, offset > 0 else { return nil }
                var units: [UInt16] = []
                var p = offset
                while let unit = i.u16(p), unit != 0, units.count < 1024 { units.append(UInt16(unit)); p += 2 }
                return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
            }
            if infoFlags & 1 != 0 {
                let base = (headerSize >= 0x24 ? wide(i.u32(0x1C)) : nil) ?? ansi(i.u32(0x10))
                let suffix = (headerSize >= 0x24 ? wide(i.u32(0x20)) : nil) ?? ansi(i.u32(0x18)) ?? ""
                if let base, !base.isEmpty { target = base + suffix }
            }
            at += size
        }
        // Then up to five strings: description, relative path, working folder, arguments, icon.
        let unicode = flags & 0x80 != 0
        for bit in [0x04, 0x08, 0x10, 0x20, 0x40] where flags & bit != 0 {
            guard let count = r.u16(at) else { return }
            let length = unicode ? count * 2 : count
            guard let raw = r.bytes(at + 2, length) else { return }
            if bit == 0x40 {
                let text = unicode ? String(data: raw, encoding: .utf16LittleEndian) : String(data: raw, encoding: .windowsCP1252)
                if let text, !text.isEmpty { iconLocation = text }
            }
            at += 2 + length
        }
    }

    /// Turns "C:\dir\file" into the matching file inside the bottle, or nil when it is on
    /// another drive, would leave the bottle's C: drive, or does not exist.
    public static func unixPath(forWindowsPath windows: String, prefix: URL) -> String? {
        guard windows.count > 3, windows.lowercased().hasPrefix("c:\\") else { return nil }
        let relative = windows.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        let c = prefix.appendingPathComponent("drive_c").standardizedFileURL
        let url = c.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(c.path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// The file to take this shortcut's icon from: the icon it names, else its program.
    public func iconSource(prefix: URL) -> String? {
        for candidate in [iconLocation, target] {
            guard let candidate, let path = Self.unixPath(forWindowsPath: candidate, prefix: prefix) else { continue }
            if ["ico", "exe", "dll"].contains((path as NSString).pathExtension.lowercased()) { return path }
        }
        return nil
    }
}
