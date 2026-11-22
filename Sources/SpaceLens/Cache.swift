import Foundation

/// Индекс: результат последнего сканирования, сохранённый на диск, чтобы не сканировать всё заново при каждом запуске.
/// Формат бинарный (на весь диск — сотни тысяч узлов), лежит в ~/Library/Application Support/SpaceLens.
enum Cache {
    struct Loaded {
        var tree: FileNode
        var date: Date
        var read: Int      // сколько папок пересканировали в последней синхронизации
        var reused: Int    // сколько взяли из кэша
    }

    private static let magic: [UInt8] = Array("SLC2".utf8)

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpaceLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func key(_ path: String) -> String {
        path == "/" ? "root" : path.replacingOccurrences(of: "/", with: "_")
    }
    private static func file(_ path: String) -> URL { dir.appendingPathComponent("index\(key(path)).bin") }
    private static func staleMark(_ path: String) -> URL { dir.appendingPathComponent("index\(key(path)).stale") }

    /// После удаления файлов сохранённый индекс устарел: при следующем запуске его нужно дообновить.
    static func markStale(_ path: String) {
        FileManager.default.createFile(atPath: staleMark(path).path, contents: Data())
    }

    // MARK: запись

    static func save(_ root: FileNode, rootPath: String, date: Date, read: Int, reused: Int) {
        var w = Writer()
        w.b.reserveCapacity(1 << 20)
        w.b.append(contentsOf: magic)
        w.str(rootPath)
        w.f64(date.timeIntervalSinceReferenceDate)
        w.u32(UInt32(truncatingIfNeeded: read))
        w.u32(UInt32(truncatingIfNeeded: reused))
        w.node(root)
        try? Data(w.b).write(to: file(rootPath), options: .atomic)
        try? FileManager.default.removeItem(at: staleMark(rootPath))
    }

    private struct Writer {
        var b: [UInt8] = []
        mutating func u8(_ v: UInt8) { b.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { b.append(contentsOf: $0) } }
        mutating func str(_ s: String) {
            let u = Array(s.utf8.prefix(65535))
            u16(UInt16(u.count))
            b.append(contentsOf: u)
        }
        mutating func node(_ n: FileNode) {
            var flags: UInt8 = 0
            if n.isDir { flags |= 1 }
            if n.isAggregate { flags |= 2 }
            if n.modified != nil { flags |= 4 }
            u8(flags)
            str(n.name)
            i64(n.size)
            u32(UInt32(truncatingIfNeeded: n.fileCount))
            f64(n.modified?.timeIntervalSinceReferenceDate ?? 0)
            f64(n.scannedAt)
            if n.isDir {
                u32(UInt32(n.children.count))
                for c in n.children { node(c) }
            }
        }
    }

    // MARK: чтение

    static func load(_ path: String) -> Loaded? {
        guard let data = try? Data(contentsOf: file(path), options: .mappedIfSafe) else { return nil }
        var r = Reader(b: [UInt8](data))
        guard r.b.count > 4, Array(r.b[0..<4]) == magic else { return nil }
        r.p = 4
        let rootPath = r.str()
        let t = r.f64()
        let read = Int(r.u32()), reused = Int(r.u32())
        guard !r.bad, rootPath == path,
              let tree = r.node(parentURL: URL(fileURLWithPath: rootPath), isRoot: true, parent: nil), !r.bad
        else { try? FileManager.default.removeItem(at: file(path)); return nil }
        var date = Date(timeIntervalSinceReferenceDate: t)
        if FileManager.default.fileExists(atPath: staleMark(path).path) { date = .distantPast }
        return Loaded(tree: tree, date: date, read: read, reused: reused)
    }

    private struct Reader {
        let b: [UInt8]
        var p = 0
        var bad = false

        mutating func u8() -> UInt8 {
            guard p + 1 <= b.count else { bad = true; return 0 }
            defer { p += 1 }
            return b[p]
        }
        mutating func raw<T>(_ t: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard p + n <= b.count else { bad = true; return nil }
            defer { p += n }
            return b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: T.self) }
        }
        mutating func u16() -> UInt16 { UInt16(littleEndian: raw(UInt16.self) ?? 0) }
        mutating func u32() -> UInt32 { UInt32(littleEndian: raw(UInt32.self) ?? 0) }
        mutating func i64() -> Int64 { Int64(littleEndian: raw(Int64.self) ?? 0) }
        mutating func f64() -> Double { Double(bitPattern: UInt64(littleEndian: raw(UInt64.self) ?? 0)) }
        mutating func str() -> String {
            let n = Int(u16())
            guard p + n <= b.count else { bad = true; return "" }
            defer { p += n }
            return String(decoding: b[p..<p + n], as: UTF8.self)
        }

        mutating func node(parentURL: URL, isRoot: Bool, parent: FileNode?) -> FileNode? {
            let flags = u8()
            let name = str()
            let size = i64()
            let files = Int(u32())
            let mod = f64()
            let scanned = f64()
            if bad { return nil }
            let isDir = flags & 1 != 0, agg = flags & 2 != 0
            let url = isRoot || agg ? parentURL : parentURL.appendingPathComponent(name, isDirectory: isDir)
            let n = FileNode(url: url, name: name, isDir: isDir, size: size, fileCount: files, isAggregate: agg,
                             modified: flags & 4 != 0 ? Date(timeIntervalSinceReferenceDate: mod) : nil)
            n.scannedAt = scanned
            n.parent = parent
            if isDir {
                let cnt = Int(u32())
                if bad || cnt > 50_000_000 { bad = true; return nil }
                n.children.reserveCapacity(cnt)
                for _ in 0..<cnt {
                    guard let c = node(parentURL: url, isRoot: false, parent: n) else { return nil }
                    n.children.append(c)
                }
            }
            return n
        }
    }
}
