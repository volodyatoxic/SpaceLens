import Foundation

/// Общее состояние сканирования. Один замок защищает и счётчики, и структуру «живого» дерева:
/// интерфейс может в любой момент забрать снимок, пока потоки ещё достраивают карту.
final class ScanProgress: @unchecked Sendable {
    let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var path = ""
    private var denied = 0
    private var cancelled = false
    private var dirsRead = 0
    private var dirsReused = 0
    private var liveRoot: FileNode?

    func add(files f: Int, bytes b: Int64, path p: String) {
        lock.lock(); files += f; bytes += b; path = p; lock.unlock()
    }
    func addDenied() { lock.lock(); denied += 1; lock.unlock() }
    func countDir(reused: Bool) {
        lock.lock(); if reused { dirsReused += 1 } else { dirsRead += 1 }; lock.unlock()
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func snapshot() -> (files: Int, bytes: Int64, path: String, denied: Int, read: Int, reused: Int) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes, path, denied, dirsRead, dirsReused)
    }

    // MARK: живое дерево

    func setRoot(_ n: FileNode) { lock.lock(); liveRoot = n; lock.unlock() }

    func attach(_ child: FileNode, to parent: FileNode) {
        lock.lock(); child.parent = parent; parent.children.append(child); lock.unlock()
    }

    /// Добавляет размер узлу и всем его предкам — карта растёт на глазах.
    func grow(_ node: FileNode, bytes: Int64, files: Int) {
        lock.lock()
        var p: FileNode? = node
        while let x = p { x.size += bytes; x.fileCount += files; p = x.parent }
        lock.unlock()
    }

    /// Лёгкая копия верхних уровней дерева (с теми же id, чтобы плитки не пересоздавались).
    func liveSnapshot(depth: Int = 3) -> FileNode? {
        lock.lock(); defer { lock.unlock() }
        guard let r = liveRoot else { return nil }
        return Self.copy(r, depth: depth, parent: nil)
    }

    private static func copy(_ n: FileNode, depth: Int, parent: FileNode?) -> FileNode {
        let c = FileNode(url: n.url, name: n.name, isDir: n.isDir, size: n.size, fileCount: n.fileCount,
                         isAggregate: n.isAggregate, id: n.id)
        c.parent = parent
        if depth > 0 && !n.children.isEmpty {
            let floor = n.size / 400
            let kids = n.children.filter { $0.size > 0 && $0.size >= floor }   // порядок обнаружения — плитки не прыгают
            c.children = kids.map { copy($0, depth: depth - 1, parent: c) }
        }
        return c
    }
}

private final class ScanCtx: @unchecked Sendable {
    let progress: ScanProgress
    let queue = OperationQueue()
    let now = Date().timeIntervalSinceReferenceDate
    init(_ p: ScanProgress) {
        progress = p
        queue.maxConcurrentOperationCount = 12
        queue.qualityOfService = .userInitiated
    }
}

enum DiskScanner {
    static let bigFile: Int64 = 1_000_000
    /// Папку, которая не менялась (по дате изменения) и читалась меньше суток назад, повторно не перечитываем.
    static let trust: Double = 24 * 3600
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .contentModificationDateKey,
    ]
    static let keySet = Set(keys)
    static let skip: Set<String> = [
        "/System/Volumes", "/.nofollow", "/.resolve", "/.vol", "/dev", "/home", "/net", "/Volumes", "/private/var/vm", "/.Spotlight-V100",
        "/.fseventsd", "/.DocumentRevisions-V100", "/Library/Developer/CoreSimulator/Volumes",
    ]

    /// iCloud/облачные папки не обходим: это может запускать подгрузку файлов и системные запросы доступа,
    /// а «выгруженные» файлы всё равно не занимают места на диске.
    static func isCloudPlaceholderDir(_ p: String) -> Bool {
        p.hasSuffix("/Library/Mobile Documents") || p.hasSuffix("/Library/CloudStorage")
    }

    /// `old` — предыдущий результат: из него берём всё, что не менялось. `force` — игнорировать его и читать всё заново.
    static func scan(root: URL, old: FileNode?, force: Bool, progress: ScanProgress) -> FileNode {
        let name = root.path == "/" ? "Macintosh HD" : nil
        let node = FileNode(url: root, name: name, isDir: true, id: force ? UUID() : (old?.id ?? UUID()))
        progress.setRoot(node)
        let ctx = ScanCtx(progress)
        let base = force ? nil : old
        ctx.queue.addOperation { process(node, old: base, ctx: ctx) }
        ctx.queue.waitUntilAllOperationsAreFinished()
        finalize(node)
        return node
    }

    private static func finalize(_ root: FileNode) {
        var stack = [root]
        while let n = stack.popLast() {
            n.children.sort { $0.size > $1.size }
            for c in n.children where c.isDir { stack.append(c) }
        }
    }

    private static func process(_ node: FileNode, old: FileNode?, ctx: ScanCtx) {
        let progress = ctx.progress
        if progress.isCancelled { return }
        let url = node.url
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        node.modified = mtime

        // Быстрый путь: папка не менялась — берём её файлы из прошлого скана, не читая диск.
        if let old, let m = mtime, let om = old.modified, m == om, ctx.now - old.scannedAt < trust {
            node.scannedAt = old.scannedAt
            var bytes: Int64 = 0
            var files = 0
            var pending: [(FileNode, FileNode)] = []
            for c in old.children {
                if c.isDir {
                    let n = FileNode(url: c.url, name: c.name, isDir: true, id: c.id)
                    progress.attach(n, to: node)
                    pending.append((n, c))
                } else {
                    let n = FileNode(url: c.url, name: c.name, isDir: false, size: c.size, fileCount: c.fileCount,
                                     isAggregate: c.isAggregate, modified: c.modified, id: c.id)
                    progress.attach(n, to: node)
                    bytes += c.size
                    files += c.fileCount
                }
            }
            progress.grow(node, bytes: bytes, files: files)
            progress.add(files: files, bytes: bytes, path: url.path)
            progress.countDir(reused: true)
            for (n, c) in pending { ctx.queue.addOperation { process(n, old: c, ctx: ctx) } }
            return
        }

        // Полное чтение папки.
        progress.countDir(reused: false)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []) else {
            progress.addDenied()
            node.scannedAt = 0          // нет доступа — в следующий раз попробуем снова
            return
        }
        node.scannedAt = ctx.now

        var oldDirs: [String: FileNode] = [:]
        if let old { for c in old.children where c.isDir { oldDirs[c.name] = c } }

        var pending: [(FileNode, FileNode?)] = []
        var fileBytes: Int64 = 0
        var fileN = 0
        var smallBytes: Int64 = 0
        var smallN = 0
        for u in items {
            guard let v = try? u.resourceValues(forKeys: keySet) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                var up = u.path
                if up.count > 1 && up.hasSuffix("/") { up.removeLast() }   // у служебных папок путь приходит как "/.nofollow/"
                if skip.contains(up) || isCloudPlaceholderDir(up) { continue }
                let d = FileNode(url: u, isDir: true, id: oldDirs[u.lastPathComponent]?.id ?? UUID())
                progress.attach(d, to: node)
                pending.append((d, oldDirs[u.lastPathComponent]))
            } else {
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                fileBytes += s
                fileN += 1
                if s >= bigFile {
                    let f = FileNode(url: u, isDir: false, size: s, fileCount: 1, modified: v.contentModificationDate)
                    progress.attach(f, to: node)
                } else {
                    smallBytes += s
                    smallN += 1
                }
            }
        }
        if smallN > 0 {
            let agg = FileNode(url: url, name: "\(fmtCount(smallN)) мелких файлов", isDir: false,
                               size: smallBytes, fileCount: smallN, isAggregate: true)
            progress.attach(agg, to: node)
        }
        progress.grow(node, bytes: fileBytes, files: fileN)
        progress.add(files: fileN, bytes: fileBytes, path: url.path)
        for (d, o) in pending { ctx.queue.addOperation { process(d, old: o, ctx: ctx) } }
    }
}
