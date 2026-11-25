import SwiftUI
import AppKit

// Демо-ролик: «сканирование» выдуманной папки, отрисованное покадрово (без записи экрана).
// Запуск: SpaceLens --render-demo <папка> [--fps 100] [--from 0] [--to 11]
// Кадры — PNG 2624×1640 (16:10). Сборка в видео и motion blur — в demo-video.sh.

enum Demo {
    struct Item { let name: String; let dir: Bool; let gb: Double; let d: Int }

    /// Выдуманная папка «Demo». d — на каком такте элемент впервые «найден».
    static let items: [Item] = [
        Item(name: "Footage", dir: true, gb: 62.4, d: 0),
        Item(name: "Games", dir: true, gb: 38.1, d: 0),
        Item(name: "Photos", dir: true, gb: 27.6, d: 0),
        Item(name: "Archive 2023.zip", dir: false, gb: 9.1, d: 1),
        Item(name: "Music", dir: true, gb: 14.9, d: 1),
        Item(name: "Projects", dir: true, gb: 12.2, d: 0),
        Item(name: "Downloads", dir: true, gb: 9.8, d: 1),
        Item(name: "Showreel.mov", dir: false, gb: 7.6, d: 2),
        Item(name: "Backups", dir: true, gb: 8.4, d: 2),
        Item(name: "Design", dir: true, gb: 6.9, d: 2),
        Item(name: "Documents", dir: true, gb: 5.1, d: 3),
        Item(name: "Ubuntu.iso", dir: false, gb: 4.7, d: 3),
        Item(name: "Library", dir: true, gb: 4.3, d: 3),
        Item(name: "Backup.dmg", dir: false, gb: 3.9, d: 4),
        Item(name: "Podcasts", dir: true, gb: 3.2, d: 4),
        Item(name: "Interview.wav", dir: false, gb: 2.2, d: 5),
        Item(name: "Notes", dir: true, gb: 1.6, d: 5),
        Item(name: "Template.psd", dir: false, gb: 1.4, d: 5),
        Item(name: "Desktop", dir: true, gb: 1.2, d: 6),
        Item(name: "Screenshots", dir: true, gb: 0.9, d: 6),
        Item(name: "Fonts", dir: true, gb: 0.7, d: 6),
        Item(name: "Mail", dir: true, gb: 0.6, d: 7),
        Item(name: "Report.pdf", dir: false, gb: 0.4, d: 7),
    ]
    static let stages = 9                 // такты 0…8; на последнем всё найдено
    static let ids: [UUID] = items.map { _ in UUID() }
    static let rootURL = URL(fileURLWithPath: "/Users/demo/Demo")
    static let rootID = UUID()

    /// Доля найденного для элемента на такте k (-1 — ещё ничего нет).
    static func progress(_ i: Int, _ k: Int) -> Double {
        let d = items[i].d
        if k < d { return 0 }
        if k >= stages - 1 { return 1 }
        let p = Double(k - d + 1) / Double(stages - d) * (1 + 0.14 * sin(Double(i) * 1.9 + Double(k) * 1.3))
        return min(0.97, max(0.02, p))
    }

    /// Дерево на такте k; frac — промежуточное состояние между k и k+1 (для плавных счётчиков).
    static func root(stage k: Int, next: Int? = nil, e: Double = 0) -> FileNode {
        let r = FileNode(url: rootURL, name: "Demo", isDir: true, id: rootID)
        var total: Int64 = 0, files = 0
        for (i, it) in items.enumerated() {
            let a = progress(i, k), b = next.map { progress(i, $0) } ?? a
            let p = a + (b - a) * e
            guard p > 0 else { continue }
            let size = Int64(it.gb * 1e9 * p)
            let n = FileNode(url: rootURL.appendingPathComponent(it.name), name: it.name, isDir: it.dir,
                             size: size, fileCount: it.dir ? Int(size / 470_000) : 1, id: ids[i])
            n.parent = r
            r.children.append(n)
            total += size; files += n.fileCount
        }
        r.size = total; r.fileCount = files
        return r
    }

    static let mapRect = CGRect(x: 6, y: 6, width: 1272, height: 716)

    /// Один TileOrder на все такты (stamp не меняется): порядок существующих плиток замораживается,
    /// новые встают по размеру — плитки не меняются местами, а только растут на месте.
    static func layout(_ k: Int, order: TileOrder) -> [Tile] {
        guard k >= 0 else { return [] }
        return Treemap.layout(root(stage: k), in: mapRect, nested: false, order: order, settled: false)
    }

    // Тайминг: каждую секунду — «такт»; движение 0.62 с с разгоном и торможением, потом пауза.
    static let t0 = 0.45, beat = 1.0, move = 0.62
    static func ease(_ u: Double) -> Double { u * u * u * (u * (u * 6 - 15) + 10) }   // smootherstep

    static func scene(at t: Double) -> (i: Int, e: Double) {
        if t < t0 { return (-1, 0) }
        let i = min(stages - 1, Int((t - t0) / beat))
        let u = min(1, max(0, (t - t0 - Double(i) * beat) / move))
        return (i, ease(u))
    }
}

@MainActor
final class DemoModel: ObservableObject {
    let app: AppState
    @Published var t = 0.0
    private var cache: [Int: [Tile]] = [:]

    init(app: AppState) {
        self.app = app
        let order = TileOrder()
        for k in 0..<Demo.stages { cache[k] = Demo.layout(k, order: order) }
    }

    func layout(_ k: Int) -> [Tile] { cache[k] ?? [] }

    struct Frame { var tiles: [(Tile, Double)]; var pill: Double; var files: Int; var bytes: Int64 }

    func set(_ time: Double) {
        t = time
        let (i, e) = Demo.scene(at: time)
        let root = Demo.root(stage: max(i - 1, -1), next: i, e: e)
        app.root = root; app.current = root
        app.scanning = true
        app.scanRoot = Demo.rootURL
        app.diskTotal = 1_000_000_000_000
        app.diskFree = 412_000_000_000
    }

    func frame() -> Frame {
        let (i, e) = Demo.scene(at: t)
        let prev = layout(i - 1), next = layout(i)
        var out: [(Tile, Double)] = []
        let pm = Dictionary(prev.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let nm = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func copy(_ n: FileNode, size: Int64) -> FileNode {
            let c = FileNode(url: n.url, name: n.name, isDir: n.isDir, size: size, fileCount: n.fileCount,
                             isAggregate: n.isAggregate, id: n.id)
            c.children = n.children
            return c
        }
        func scaled(_ r: CGRect, _ s: Double) -> CGRect {
            let w = r.width * s, h = r.height * s
            return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        }
        for p in prev where nm[p.id] == nil {          // исчезают (слились в группу)
            out.append((Tile(node: p.node, rect: scaled(p.rect, 1 - 0.14 * e), depth: 0, container: false), 1 - e))
        }
        for n in next {
            if let p = pm[n.id] {
                let r = CGRect(x: p.rect.minX + (n.rect.minX - p.rect.minX) * e, y: p.rect.minY + (n.rect.minY - p.rect.minY) * e,
                               width: p.rect.width + (n.rect.width - p.rect.width) * e, height: p.rect.height + (n.rect.height - p.rect.height) * e)
                let sz = p.node.size + Int64(Double(n.node.size - p.node.size) * e)
                out.append((Tile(node: copy(n.node, size: sz), rect: r, depth: 0, container: false), 1))
            } else {                                    // появляются на своём месте
                out.append((Tile(node: copy(n.node, size: Int64(Double(n.node.size) * (0.4 + 0.6 * e))), rect: scaled(n.rect, 0.86 + 0.14 * e),
                                 depth: 0, container: false), e))
            }
        }
        let done = Demo.t0 + Double(Demo.stages - 1) * Demo.beat + Demo.move + 0.25
        let pill = t < done ? 1 : max(0, 1 - (t - done) / 0.35)
        let root = Demo.root(stage: max(i - 1, -1), next: i, e: e)
        return Frame(tiles: out, pill: pill, files: root.fileCount, bytes: root.size)
    }
}

struct DemoSpinner: View {
    let t: Double
    var body: some View {
        Circle().trim(from: 0.08, to: 0.78)
            .stroke(Color.primary.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(t * 520))
    }
}

struct DemoFrame: View {
    @ObservedObject var m: DemoModel
    let app: AppState
    private let folder = Color(hex: Palette.defaultFolder), file = Color(hex: Palette.defaultFile)

    var body: some View {
        let f = m.frame()
        ZStack(alignment: .topLeading) {
            Color(red: 0.235, green: 0.235, blue: 0.245)
            VStack(spacing: 12) {
                TopBar()
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.16))
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
                    ZStack(alignment: .topLeading) {
                        ForEach(f.tiles, id: \.0.id) { t, a in
                            TileView(tile: t, baseFill: t.node.isAggregate ? file.shade(0.28) : (t.node.isDir ? folder : file), selected: false)
                                .opacity(a)
                        }
                    }
                    .frame(width: 1284, height: 728, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .frame(width: 1284, height: 728)
                .overlay(alignment: .top) {
                    HStack(spacing: 10) {
                        DemoSpinner(t: m.t)
                        Text("Сканирую").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        Text("\(fmtCount(f.files)) файлов · \(fmtSize(f.bytes))")
                            .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                        Text("Отмена").foregroundStyle(.red).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color(white: 0.15).opacity(0.96)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .padding(.top, 12)
                    .opacity(f.pill)
                }
            }
            .padding(.top, 34).padding(.bottom, 14).padding(.horizontal, 14)
            HStack(spacing: 8) {
                ForEach([Color(hex: "FF5F57"), Color(hex: "FEBC2E"), Color(hex: "28C840")], id: \.self) { c in
                    Circle().fill(c).frame(width: 13, height: 13)
                }
            }
            .padding(.leading, 10).padding(.top, 10)
        }
        .frame(width: 1312, height: 820)
        .environment(\.colorScheme, .dark)
        .environmentObject(app)
        .environmentObject(app.ai)
        .transaction { $0.animation = nil }
    }
}

@MainActor
enum DemoRenderer {
    static func run(args: [String], app: AppState) async {
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let dir = opt("--render-demo") else { return }
        let fps = Double(opt("--fps") ?? "") ?? 100
        let from = Double(opt("--from") ?? "") ?? 0
        let to = Double(opt("--to") ?? "") ?? 11.2
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let m = DemoModel(app: app)
        let host = NSHostingView(rootView: DemoFrame(m: m, app: app))
        host.frame = NSRect(x: 0, y: 0, width: 1312, height: 820)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderBack(nil)
        for w in NSApp.windows where w !== win { w.orderOut(nil) }

        let n0 = Int(from * fps), n1 = Int(to * fps)
        for n in n0..<n1 {
            m.set(Double(n) / fps)
            try? await Task.sleep(nanoseconds: 22_000_000)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2624, pixelsHigh: 1640, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%05d.png", n)))
            }
            if n % 50 == 0 { print("кадр \(n)/\(n1)"); fflush(stdout) }
        }
        print("готово"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
