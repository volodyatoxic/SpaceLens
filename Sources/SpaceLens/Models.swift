import SwiftUI
import AppKit

/// Узел дерева файлов. Мелкие файлы (< 1 МБ) схлопываются в один «агрегатный» узел,
/// чтобы дерево на миллионах файлов помещалось в память.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let url: URL
    var name: String
    let isDir: Bool
    let isAggregate: Bool
    var size: Int64
    var fileCount: Int
    var modified: Date?
    /// Когда содержимое папки читали с диска в последний раз (0 — всегда перечитывать, напр. если был отказ в доступе).
    var scannedAt: Double = 0
    var children: [FileNode] = []
    weak var parent: FileNode?

    init(url: URL, name: String? = nil, isDir: Bool, size: Int64 = 0, fileCount: Int = 0,
         isAggregate: Bool = false, modified: Date? = nil, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDir = isDir
        self.size = size
        self.fileCount = fileCount
        self.isAggregate = isAggregate
        self.modified = modified
    }

    var path: String { url.path }

    var ancestors: [FileNode] {
        var a: [FileNode] = []
        var p = parent
        while let x = p { a.append(x); p = x.parent }
        return a.reversed()
    }

    func isDescendant(of other: FileNode) -> Bool {
        var p = parent
        while let x = p { if x === other { return true }; p = x.parent }
        return false
    }

    /// Узел всё ещё в дереве (его не убрали после удаления в Корзину).
    var isAttached: Bool {
        var n: FileNode = self
        while let p = n.parent {
            if !p.children.contains(where: { $0 === n }) { return false }
            n = p
        }
        return true
    }

    static func == (l: FileNode, r: FileNode) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum FileKind: String, CaseIterable {
    case folder, app, video, image, audio, archive, document, code, diskImage, small, other

    var label: String {
        switch self {
        case .folder: "Папки"
        case .app: "Приложения"
        case .video: "Видео"
        case .image: "Изображения"
        case .audio: "Аудио"
        case .archive: "Архивы"
        case .document: "Документы"
        case .code: "Код и данные"
        case .diskImage: "Образы дисков"
        case .small: "Мелкие файлы"
        case .other: "Прочее"
        }
    }
    var color: Color {
        switch self {
        case .folder: .blue
        case .app: .green
        case .video: .purple
        case .image: .pink
        case .audio: .red
        case .archive: .orange
        case .document: .teal
        case .code: .cyan
        case .diskImage: .indigo
        case .small: Color(white: 0.55)
        case .other: Color(white: 0.5)
        }
    }
    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .app: "app.fill"
        case .video: "film.fill"
        case .image: "photo.fill"
        case .audio: "music.note"
        case .archive: "archivebox.fill"
        case .document: "doc.text.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .diskImage: "opticaldiscdrive.fill"
        case .small: "square.stack.3d.up.fill"
        case .other: "doc.fill"
        }
    }

    private static let map: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        func add(_ k: FileKind, _ e: String) { e.split(separator: " ").forEach { m[String($0)] = k } }
        add(.video, "mp4 mov m4v mkv avi webm mpg mpeg wmv braw mxf r3d prores")
        add(.image, "jpg jpeg png heic heif gif tiff tif bmp raw cr2 cr3 nef arw dng psd ai svg webp icns exr")
        add(.audio, "mp3 wav aiff aif m4a flac ogg aac wma caf")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz zst xip")
        add(.document, "pdf doc docx xls xlsx ppt pptx key pages numbers txt rtf md epub csv")
        add(.code, "swift js ts tsx jsx py rb go rs java kt c cpp h m json xml yml yaml html css sh sql db sqlite sqlite3 log plist")
        add(.diskImage, "dmg iso img vmdk vdi qcow2 vhd vhdx utm pvm vmwarevm hdd sparseimage sparsebundle ipsw pkg")
        return m
    }()

    static func of(_ n: FileNode) -> FileKind {
        if n.isAggregate { return .small }
        let ext = n.url.pathExtension.lowercased()
        if n.isDir { return ext == "app" ? .app : .folder }
        return map[ext] ?? .other
    }
}

func fmtSize(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func fmtCount(_ n: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    func shade(_ f: CGFloat) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: ns.blended(withFraction: f, of: .black) ?? ns)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static var custom: [String: NSImage?] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 400 { cache.removeAll() }
        cache[path] = i
        return i
    }
    /// Настоящая иконка для приложений и для папок с пользовательской иконкой; для остальных — nil (рисуем символ).
    static func real(for n: FileNode) -> NSImage? {
        if n.isAggregate { return nil }
        if n.isDir && n.url.pathExtension.lowercased() == "app" { return icon(n.path) }
        guard n.isDir else { return nil }
        if let c = custom[n.path] { return c }
        let img = (try? n.url.resourceValues(forKeys: [.customIconKey]))?.customIcon as? NSImage
        if custom.count > 2000 { custom.removeAll() }
        custom[n.path] = .some(img)
        return img
    }
}
