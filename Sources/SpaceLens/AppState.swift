import SwiftUI
import AppKit

struct ReviewRequest: Identifiable {
    let id = UUID()
    let nodes: [FileNode]
}

struct TrashRecord {
    let node: FileNode
    let parent: FileNode
    let original: URL
    let trashed: URL?
}

struct TrashBatch {
    var records: [TrashRecord]
    var bytes: Int64
    var failures: [String]
}

enum Palette {
    /// (hex, название)
    static let swatches: [String] = ["8E919A", "0A84FF", "5E5CE6", "BF5AF2", "FF375F", "FF9F0A", "30D158", "30B0C7"]
    static let defaultFolder = "8E919A"
    static let defaultFile = "0A84FF"
}

@MainActor
final class AppState: ObservableObject {
    /// Данные моложе этого считаем актуальными и вообще не сканируем.
    static let freshWindow: TimeInterval = 3600

    @Published var root: FileNode?
    @Published var current: FileNode?
    @Published var selected: FileNode?
    @Published var scanning = false      // строим карту с нуля — она растёт на глазах
    @Published var refreshing = false    // показан сохранённый индекс, идёт дообновление
    @Published var scanFiles = 0
    @Published var scanBytes: Int64 = 0
    @Published var scanPath = ""
    @Published var scanDenied = 0
    @Published var deniedAfterScan = 0
    @Published var review: ReviewRequest?
    @Published var lastTrash: TrashBatch?
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published var scanRoot: URL?
    @Published var lastSync: Date?
    @Published var syncNote = ""
    @Published var saving = false

    // настройки
    let order = TileOrder()
    @Published var nested: Bool { didSet { UserDefaults.standard.set(nested, forKey: "nested") } }
    @Published var folderHex: String { didSet { UserDefaults.standard.set(folderHex, forKey: "folderHex") } }
    @Published var fileHex: String { didSet { UserDefaults.standard.set(fileHex, forKey: "fileHex") } }

    let ai = AIState()
    private var progress: ScanProgress?
    private var pollTask: Task<Void, Never>?
    private var memCache: [String: Cache.Loaded] = [:]

    init() {
        let d = UserDefaults.standard
        nested = d.object(forKey: "nested") as? Bool ?? true
        folderHex = d.string(forKey: "folderHex") ?? Palette.defaultFolder
        fileHex = d.string(forKey: "fileHex") ?? Palette.defaultFile
        ai.app = self
        refreshDisk(URL(fileURLWithPath: "/"))
    }

    var folderColor: Color { Color(hex: folderHex) }
    var fileColor: Color { Color(hex: fileHex) }
    var busy: Bool { scanning || refreshing || saving }

    // MARK: сканирование

    /// Открывает место: берёт сохранённый индекс; если он старше часа — дообновляет только изменившееся.
    /// `force` — выбросить индекс и просканировать всё заново.
    func scan(_ url: URL, force: Bool = false) {
        progress?.cancel()
        pollTask?.cancel()
        let prog = ScanProgress()
        progress = prog
        scanRoot = url
        UserDefaults.standard.set(url.path, forKey: "lastRoot")
        root = nil; current = nil; selected = nil; lastTrash = nil
        scanFiles = 0; scanBytes = 0; scanPath = force ? "" : "Загружаю индекс…"; scanDenied = 0
        scanning = true; refreshing = false
        syncNote = ""
        ai.reset()
        refreshDisk(url)

        let path = url.path
        Task { [weak self] in
            var loaded: Cache.Loaded?
            if !force {
                if let m = self?.memCache[path] { loaded = m }
                else { loaded = await Task.detached(priority: .userInitiated) { Cache.load(path) }.value }
            }
            guard let self, self.progress === prog else { return }
            if let l = loaded {
                self.memCache[path] = l
                self.root = l.tree
                self.current = l.tree
                self.lastSync = l.date
                self.syncNote = Self.note(read: l.read, reused: l.reused)
                self.scanning = false
                if Date().timeIntervalSince(l.date) < Self.freshWindow { return }   // данные свежие — работы нет
                self.refreshing = true
                self.run(url, prog: prog, old: l.tree, force: false, live: false)
            } else {
                self.lastSync = nil
                self.run(url, prog: prog, old: nil, force: true, live: true)
            }
        }
    }

    /// Кнопка «синхронизировать»: всё заново, индекс игнорируется.
    func rescan() { if let u = scanRoot { scan(u, force: true) } }

    func restoreLast() {
        guard root == nil, !scanning, let p = UserDefaults.standard.string(forKey: "lastRoot"),
              FileManager.default.fileExists(atPath: p) else { return }
        scan(URL(fileURLWithPath: p))
    }

    private static func note(read: Int, reused: Int) -> String {
        let total = read + reused
        guard total > 0 else { return "" }
        return "Папок: \(fmtCount(total)) · пересканировано \(fmtCount(read)), из индекса \(fmtCount(reused))"
    }

    private func run(_ url: URL, prog: ScanProgress, old: FileNode?, force: Bool, live: Bool) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = prog.snapshot()
                self.scanFiles = s.files; self.scanBytes = s.bytes
                self.scanPath = s.path; self.scanDenied = s.denied
                if live, let snap = prog.liveSnapshot() {
                    self.order.stamp += 1
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.84)) { self.current = snap }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let wasRefresh = old != nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let tree = DiskScanner.scan(root: url, old: old, force: force, progress: prog)
            await MainActor.run { self?.finish(url: url, prog: prog, tree: tree, wasRefresh: wasRefresh) }
        }
    }

    private func finish(url: URL, prog: ScanProgress, tree: FileNode, wasRefresh: Bool) {
        guard progress === prog else { return }
        pollTask?.cancel()
        scanning = false; refreshing = false
        if prog.isCancelled { return }
        let s = prog.snapshot()
        deniedAfterScan = s.denied
        let prevPath = current?.path, selPath = selected?.path

        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
            root = tree
            current = tree
        }
        if wasRefresh {
            if let p = prevPath, let n = node(forPath: p), n.isDir { current = n }
            if let sp = selPath { selected = node(forPath: sp) }
        }

        let date = Date()
        lastSync = date
        syncNote = Self.note(read: s.read, reused: s.reused)
        let loaded = Cache.Loaded(tree: tree, date: date, read: s.read, reused: s.reused)
        memCache[url.path] = loaded
        saving = true
        Task.detached(priority: .utility) { [weak self] in
            Cache.save(tree, rootPath: url.path, date: date, read: s.read, reused: s.reused)
            await MainActor.run { self?.saving = false }
        }
    }

    func cancelScan() {
        progress?.cancel()
        pollTask?.cancel()
        let hadData = root != nil
        scanning = false; refreshing = false
        if !hadData { current = nil; scanRoot = nil }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Сканировать"
        p.message = "Выберите папку или диск для анализа"
        if p.runModal() == .OK, let u = p.url { scan(u) }
    }

    func refreshDisk(_ url: URL) {
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    // MARK: навигация

    var crumbs: [FileNode] {
        guard let c = current else { return [] }
        return c.ancestors + [c]
    }

    func zoom(to node: FileNode) {
        guard node.isDir, !node.isAggregate, !scanning else { return }
        ai.active = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            current = node
            selected = nil
        }
    }

    func up() {
        if let p = current?.parent { zoom(to: p) }
    }

    func select(_ n: FileNode) { selected = n }

    /// Двойной клик: в папку — зайти, файл — показать в Finder.
    func activate(_ n: FileNode) {
        if n.isDir && !n.children.isEmpty { zoom(to: n) } else { reveal(n) }
    }

    func focus(_ n: FileNode) {
        ai.active = false
        if let p = n.parent {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { current = p }
        }
        selected = n
    }

    // MARK: ИИ-режим

    func toggleAI() {
        if ai.active { ai.active = false; return }
        guard root != nil, !busy else { return }
        ai.active = true
        selected = nil
        if ai.isReady && !(ai.finished && ai.scopeID == current?.id) && !ai.running { ai.analyze() }
    }

    // MARK: Finder

    func reveal(_ n: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([n.url])
    }
    func openItem(_ n: FileNode) { NSWorkspace.shared.open(n.url) }
    func copyPath(_ n: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.path, forType: .string)
    }
    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    // MARK: цвета

    func fill(for n: FileNode) -> Color {
        if n.isAggregate { return fileColor.shade(0.28) }
        return n.isDir ? folderColor : fileColor
    }

    // MARK: удаление (только через Корзину)

    func canTrash(_ n: FileNode) -> Bool {
        !busy && n !== root && n.parent != nil && Safety.shared.verdict(for: n).canTrash
    }

    func requestTrash(_ nodes: [FileNode]) {
        // убираем вложенные: если выбрана и папка, и файл внутри неё — оставляем папку
        let uniq = nodes.filter { n in !nodes.contains { $0 !== n && n.isDescendant(of: $0) } }
        review = ReviewRequest(nodes: uniq)
    }

    func performTrash(_ nodes: [FileNode]) async {
        let items: [(FileNode, FileNode?)] = nodes.map { ($0, $0.parent) }
        let results = await Task.detached { () -> [(TrashRecord?, String?)] in
            var out: [(TrashRecord?, String?)] = []
            for (n, parent) in items {
                // Повторная проверка в момент удаления — не доверяем состоянию интерфейса.
                let v = Safety.shared.verdict(for: n)
                guard let parent, !n.isAggregate, v.canTrash else {
                    out.append((nil, "\(n.name): защищено правилами безопасности")); continue
                }
                guard FileManager.default.fileExists(atPath: n.url.path) else {
                    out.append((nil, "\(n.name): элемент уже не существует")); continue
                }
                do {
                    var res: NSURL?
                    try FileManager.default.trashItem(at: n.url, resultingItemURL: &res)
                    out.append((TrashRecord(node: n, parent: parent, original: n.url, trashed: res as URL?), nil))
                } catch {
                    out.append((nil, "\(n.name): \(error.localizedDescription)"))
                }
            }
            return out
        }.value

        var batch = TrashBatch(records: [], bytes: 0, failures: [])
        for (rec, err) in results {
            if let err { batch.failures.append(err) }
            if let rec { batch.records.append(rec); batch.bytes += rec.node.size; detach(rec.node) }
        }
        if let s = selected, batch.records.contains(where: { $0.node === s || s.isDescendant(of: $0.node) }) { selected = nil }
        lastTrash = batch
        if !batch.records.isEmpty, let r = scanRoot { Cache.markStale(r.path) }
        refreshDisk(scanRoot ?? URL(fileURLWithPath: "/"))
        objectWillChange.send()
    }

    private func detach(_ node: FileNode) {
        guard let parent = node.parent else { return }
        if let c = current, c === node || c.isDescendant(of: node) {
            current = parent
        }
        parent.children.removeAll { $0 === node }
        adjust(parent, size: -node.size, files: -node.fileCount)
    }

    private func adjust(_ start: FileNode?, size: Int64, files: Int) {
        var p = start
        while let x = p {
            x.size += size; x.fileCount += files
            x.children.sort { $0.size > $1.size }
            p = x.parent
        }
    }

    func undoLastTrash() {
        guard let batch = lastTrash else { return }
        var failed: [String] = []
        for rec in batch.records {
            guard let t = rec.trashed else { failed.append(rec.node.name); continue }
            do {
                try FileManager.default.moveItem(at: t, to: rec.original)
                rec.node.parent = rec.parent
                rec.parent.children.append(rec.node)
                adjust(rec.parent, size: rec.node.size, files: rec.node.fileCount)
            } catch { failed.append(rec.node.name) }
        }
        lastTrash = failed.isEmpty ? nil : TrashBatch(records: [], bytes: 0, failures: ["Не удалось вернуть: " + failed.joined(separator: ", ")])
        refreshDisk(scanRoot ?? URL(fileURLWithPath: "/"))
        objectWillChange.send()
    }

    // MARK: поиск узла по пути (для ИИ)

    func node(forPath path: String) -> FileNode? {
        guard let root else { return nil }
        let rp = root.path
        if path == rp { return root }
        let base = rp == "/" ? "/" : rp + "/"
        guard path.hasPrefix(base) else { return nil }
        var n = root
        for c in path.dropFirst(base.count).split(separator: "/") {
            guard let next = n.children.first(where: { $0.url.lastPathComponent == c && !$0.isAggregate }) else { return nil }
            n = next
        }
        return n
    }
}
