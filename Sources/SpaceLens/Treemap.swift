import SwiftUI

struct Tile: Identifiable {
    var id: UUID { node.id }
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let container: Bool
}

/// Порядок плиток, который меняется плавно. Пока идёт синхронизация, плитка может сдвинуться только на соседнее место
/// за один такт (и только если сосед заметно меньше её) — поэтому всё переезжает как в пазле, без пересечения траекторий.
/// Новые плитки встают на место по текущему размеру, а когда синхронизация закончилась, порядок досортировывается.
final class TileOrder {
    private var rootID: UUID?
    private var lists: [UUID: [UUID]] = [:]
    private var stamps: [UUID: Int] = [:]
    var stamp = 0

    func begin(root: UUID) {
        if rootID != root { rootID = root; lists = [:]; stamps = [:] }
    }

    func arrange(_ parent: UUID, _ nodes: [FileNode], settled: Bool) -> [FileNode] {
        if settled {
            let s = nodes.sorted { $0.size > $1.size }
            lists[parent] = s.map(\.id)
            return s
        }
        var byID: [UUID: FileNode] = [:]
        for n in nodes { byID[n.id] = n }
        var ids = (lists[parent] ?? []).filter { byID[$0] != nil }
        let known = Set(ids)
        for n in nodes.sorted(by: { $0.size > $1.size }) where !known.contains(n.id) {
            let i = ids.firstIndex { (byID[$0]?.size ?? 0) < n.size } ?? ids.count
            ids.insert(n.id, at: i)
        }
        if stamps[parent] != stamp {
            stamps[parent] = stamp
            for parity in 0..<2 {
                var i = parity
                while i + 1 < ids.count {
                    if let a = byID[ids[i]], let b = byID[ids[i + 1]], Double(b.size) > Double(a.size) * 1.15 { ids.swapAt(i, i + 1) }
                    i += 2
                }
            }
        }
        lists[parent] = ids
        return ids.compactMap { byID[$0] }
    }
}

enum Treemap {
    static func layout(_ root: FileNode, in rect: CGRect, nested: Bool, order: TileOrder, settled: Bool) -> [Tile] {
        var out: [Tile] = []
        order.begin(root: root.id)
        place(root.children, parent: root.id, in: rect, depth: 0, nested: nested, order: order, settled: settled, out: &out)
        return out
    }

    /// Плитка меньше этой площади (pt²) не вместит даже мелкую подпись — такие элементы сливаются в одну плитку «ещё N».
    private static let labelArea = 1800.0

    private static func place(_ unordered: [FileNode], parent: UUID, in rect: CGRect, depth: Int, nested: Bool,
                              order: TileOrder, settled: Bool, out: inout [Tile]) {
        guard rect.width > 8, rect.height > 8, out.count < 700 else { return }
        let nodes = order.arrange(parent, unordered, settled: settled)
        let total = nodes.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return }
        let area = Double(rect.width * rect.height)
        func share(_ n: FileNode) -> Double { Double(n.size) / total * area }

        var big = nodes.filter { share($0) >= labelArea }
        var small = nodes.filter { share($0) < labelArea }
        if small.count == 1 {
            if share(small[0]) >= 800 { big.append(small[0]) }
            small = []
        }
        var kept = big
        if small.count >= 2 {
            let sum = small.reduce(Int64(0)) { $0 + $1.size }
            if Double(sum) / total * area >= 900 {
                let g = FileNode(url: small[0].parent?.url ?? small[0].url, name: "ещё \(fmtCount(small.count))",
                                 isDir: false, size: sum, fileCount: small.reduce(0) { $0 + $1.fileCount },
                                 isAggregate: true, id: small[0].id)
                g.children = small
                kept.insert(g, at: kept.firstIndex { $0.size < g.size } ?? kept.count)
            }
        }
        var placed = squarify(kept, in: rect)
        // Убираем «щепки»: плитки тоньше 22 pt и пересчитываем раскладку без них.
        for _ in 0..<4 {
            let thin = Set(placed.filter { min($0.1.width, $0.1.height) < 22 }.map { $0.0.id })
            if thin.isEmpty || thin.count == kept.count { break }
            kept = kept.filter { !thin.contains($0.id) }
            placed = squarify(kept, in: rect)
        }
        for (n, r) in placed {
            let nest = nested && depth < 2 && n.isDir && !n.children.isEmpty && r.width >= 124 && r.height >= 88
            out.append(Tile(node: n, rect: r, depth: depth, container: nest))
            if nest {
                let inner = CGRect(x: r.minX + 7, y: r.minY + 28, width: r.width - 14, height: r.height - 35)
                place(n.children, parent: n.id, in: inner, depth: depth + 1, nested: nested, order: order, settled: settled, out: &out)
            }
        }
    }

    static func squarify(_ nodes: [FileNode], in rect: CGRect) -> [(FileNode, CGRect)] {
        let total = nodes.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        let areas = nodes.map { Double($0.size) * scale }
        var res: [(FileNode, CGRect)] = []
        var r = rect
        var i = 0
        while i < nodes.count, r.width > 0.5, r.height > 0.5 {
            let side = Double(min(r.width, r.height))
            var j = i
            var sum = 0.0
            var best = Double.infinity
            while j < nodes.count {
                let s2 = sum + areas[j]
                let w = max(side * side * areas[i] / (s2 * s2), (s2 * s2) / (side * side * areas[j]))
                if w > best { break }
                best = w; sum = s2; j += 1
            }
            if r.width >= r.height {
                let colW = CGFloat(sum) / r.height
                var y = r.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / colW
                    res.append((nodes[k], CGRect(x: r.minX, y: y, width: colW, height: h)))
                    y += h
                }
                r = CGRect(x: r.minX + colW, y: r.minY, width: max(0, r.width - colW), height: r.height)
            } else {
                let rowH = CGFloat(sum) / r.width
                var x = r.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / rowH
                    res.append((nodes[k], CGRect(x: x, y: r.minY, width: w, height: rowH)))
                    x += w
                }
                r = CGRect(x: r.minX, y: r.minY + rowH, width: r.width, height: max(0, r.height - rowH))
            }
            i = j
        }
        return res
    }
}

/// Подбор однострочной подписи: шрифт растёт с размером плитки, а когда текста много — сначала уменьшаем шрифт
/// (до 7 pt), потом сокращаем размер («8,94 GB» → «8.9G»), потом имя («Visual Studio Code.app» → «Visual Stu…»).
enum TileLabel {
    struct Result { var name: String; var size: String?; var font: CGFloat }

    private static func nsFont(_ s: CGFloat) -> NSFont {
        let f = NSFont.systemFont(ofSize: s, weight: .semibold)
        return f.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: s) } ?? f
    }
    static func width(_ t: String, _ s: CGFloat) -> CGFloat {
        ceil((t as NSString).size(withAttributes: [.font: nsFont(s)]).width * 1.09)
    }

    static func shortName(_ n: String) -> String {
        var t = n
        for suf in [".app", ".localized"] where t.lowercased().hasSuffix(suf) && t.count > suf.count + 1 { t.removeLast(suf.count) }
        return t
    }

    static func compact(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1e9 { return d >= 99.95e9 ? String(format: "%.0fG", d / 1e9) : String(format: "%.1fG", d / 1e9) }
        if d >= 1e6 { return String(format: "%.0fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.0fK", d / 1e3) }
        return "\(b)B"
    }

    private static func truncated(_ t: String, to w: CGFloat, font: CGFloat) -> String? {
        if width(t, font) <= w { return t }
        var lo = 0, hi = t.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if width(String(t.prefix(mid)) + "…", font) <= w { lo = mid } else { hi = mid - 1 }
        }
        return lo >= 2 ? String(t.prefix(lo)).trimmingCharacters(in: .whitespaces) + "…" : nil
    }

    /// `base` — желаемый размер шрифта по размеру плитки; `avail` — ширина под текст; `height` — высота под строку.
    static func fit(name: String, bytes: Int64, avail: CGFloat, height: CGFloat, pad: CGFloat, base: CGFloat) -> Result? {
        let gap: CGFloat = 6
        let nm = shortName(name), full = fmtSize(bytes), comp = compact(bytes)
        var fonts: [CGFloat] = []
        for k in [1.0, 0.88, 0.78, 0.0] as [CGFloat] {
            let f = k == 0 ? 7 : max(7, base * k)
            if !fonts.contains(f) { fonts.append(f) }
        }
        let viable = fonts.filter { $0 * 1.3 + pad * 1.2 <= height }
        guard let smallest = viable.last else { return nil }
        for f in viable {
            for sz in [full, comp] where width(nm, f) + gap + width(sz, f) <= avail {
                return Result(name: nm, size: sz, font: f)
            }
        }
        let f = smallest
        let room = avail - gap - width(comp, f)
        if room > 0, let t = truncated(nm, to: room, font: f), t.count >= 3 { return Result(name: t, size: comp, font: f) }
        if let t = truncated(nm, to: avail, font: f) { return Result(name: t, size: nil, font: f) }
        if width(comp, f) <= avail { return Result(name: "", size: comp, font: f) }
        return nil
    }
}

struct TileView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState
    let tile: Tile
    let baseFill: Color
    let selected: Bool
    @State private var hover = false
    @State private var showGroup = false

    private var isGroup: Bool { tile.node.isAggregate && !tile.node.children.isEmpty }

    var body: some View {
        let mark = ai.marks[tile.node.id]
        let fill = mark?.color ?? baseFill
        let r = tile.rect.insetBy(dx: 1.5, dy: 1.5)
        let radius = min(tile.depth == 0 ? 16.0 : (tile.depth == 1 ? 11.0 : 8.0), min(r.width, r.height) / 4)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let minSide = min(r.width, r.height)
        let base = min(12, max(7, 5.5 + 0.065 * minSide))
        let pad = min(8, max(3, base * 0.7))
        let badge = mark != nil && r.width >= 44 && r.height >= 30
        ZStack(alignment: .topLeading) {
            if tile.container {
                shape.fill(fill.opacity(0.20))
                shape.strokeBorder(fill.opacity(0.55), lineWidth: 1)
                let hp: CGFloat = 10
                if let L = TileLabel.fit(name: tile.node.name, bytes: tile.node.size,
                                         avail: r.width - 2 * hp - (badge ? 28 : 0), height: 28, pad: 7,
                                         base: min(11.5, base)) {
                    labelRow(L, width: r.width - 2 * hp - (badge ? 28 : 0))
                        .foregroundStyle(.primary.opacity(0.9))
                        .padding(.leading, hp).padding(.top, 7)
                }
            } else {
                if isGroup {
                    shape.fill(Color.white.opacity(hover ? 0.12 : 0.07))
                    shape.strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    shape.fill(LinearGradient(colors: [fill.shade(0.02), fill.shade(0.30)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                    shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                }
                let avail = r.width - 2 * pad - (badge ? 28 : 0)
                let L = TileLabel.fit(name: tile.node.name, bytes: tile.node.size, avail: avail,
                                      height: r.height, pad: pad, base: base)
                if let L {
                    labelRow(L, width: avail)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .padding(.leading, pad).padding(.top, pad)
                }
                // Иконка — только если не залезает на текст: ей достаётся место под строкой подписи.
                let band = L.map { pad + $0.font * 1.3 + 4 } ?? 0
                let side = min(max(minSide * 0.42, 24), 72, r.height - band - 8, r.width - 16)
                if isGroup {
                    if side >= 26 {
                        Image(systemName: "square.grid.3x3.fill")
                            .font(.system(size: min(side * 0.7, 40), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.22))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(10)
                    }
                } else if let img = IconCache.real(for: tile.node), side >= 20 {
                    Image(nsImage: img)
                        .resizable().interpolation(.high).scaledToFit()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                } else if side >= 30 && r.width >= 110 && r.height >= 84 {
                    Image(systemName: FileKind.of(tile.node).symbol)
                        .font(.system(size: min(minSide * 0.26, 64, side), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
            }
            if selected {
                shape.strokeBorder(.white, lineWidth: 2.5).shadow(color: fill.opacity(0.9), radius: 8)
            }
            if let m = mark, badge {
                AIBadge(s: m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .frame(width: max(r.width, 1), height: max(r.height, 1))
        .brightness(hover && !tile.container && !isGroup ? 0.07 : 0)
        .contentShape(shape)
        .onHover { hover = $0 }
        .help(isGroup ? groupHelp : "\(tile.node.path)\n\(fmtSize(tile.node.size))")
        .onTapGesture(count: 2) { if !isGroup { app.activate(tile.node) } }
        .onTapGesture { if isGroup { showGroup.toggle() } else { app.select(tile.node) } }
        .contextMenu { if !isGroup { NodeMenu(node: tile.node) } }
        .popover(isPresented: $showGroup, arrowEdge: .bottom) { GroupList(group: tile.node, close: { showGroup = false }) }
        .popover(isPresented: detailBinding, arrowEdge: .bottom) { DetailCard(node: tile.node, onClose: { app.selected = nil }) }
        .offset(x: r.minX, y: r.minY)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var detailBinding: Binding<Bool> {
        Binding(get: { selected && !isGroup },
                set: { if !$0, app.selected?.id == tile.node.id { app.selected = nil } })
    }

    private var groupHelp: String {
        let items = tile.node.children.prefix(12).map { "\($0.name) — \(fmtSize($0.size))" }.joined(separator: "\n")
        let more = tile.node.children.count > 12 ? "\n…и ещё \(tile.node.children.count - 12)" : ""
        return "Мелкие элементы: \(fmtSize(tile.node.size))\n" + items + more
    }

    @ViewBuilder
    private func labelRow(_ L: TileLabel.Result, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            if !L.name.isEmpty { Text(L.name).lineLimit(1) }
            if let sz = L.size {
                if !L.name.isEmpty { Spacer(minLength: 0) }
                Text(sz).lineLimit(1).opacity(0.78)
            }
        }
        .font(.system(size: L.font, weight: .semibold, design: .rounded))
        .minimumScaleFactor(0.9)
        .frame(width: max(width, 1), alignment: .leading)
    }
}

/// Список мелких элементов, которые не поместились на карте отдельными плитками.
struct GroupList: View {
    @EnvironmentObject var app: AppState
    let group: FileNode
    let close: () -> Void
    @State private var picked: FileNode?

    var body: some View {
        if let n = picked {
            VStack(alignment: .leading, spacing: 0) {
                Button { picked = nil } label: {
                    Label("Мелкие элементы", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding([.top, .leading], 12)
                DetailCard(node: n, onClose: close)
            }
        } else { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Мелкие элементы · \(group.children.count)").font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer(minLength: 16)
                Text(fmtSize(group.size)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(group.children.prefix(80)) { n in
                        Button { picked = n } label: {
                            HStack(spacing: 8) {
                                Image(systemName: n.isDir ? "folder.fill" : "doc.fill").foregroundStyle(.secondary).frame(width: 14)
                                Text(n.name).lineLimit(1)
                                Spacer(minLength: 12)
                                Text(fmtSize(n.size)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, design: .rounded))
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)
            if group.children.count > 80 {
                Text("…и ещё \(group.children.count - 80)").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 330)
    }
}

struct NodeMenu: View {
    @EnvironmentObject var app: AppState
    let node: FileNode
    var body: some View {
        let v = Safety.shared.verdict(for: node)
        if node.isDir && !node.isAggregate && !node.children.isEmpty {
            Button("Открыть внутри приложения") { app.zoom(to: node) }
        }
        Button("Показать в Finder") { app.reveal(node) }
        Button("Открыть") { app.openItem(node) }
        Button("Скопировать путь") { app.copyPath(node) }
        Divider()
        Button("Переместить в Корзину…", role: .destructive) { app.requestTrash([node]) }.disabled(!app.canTrash(node))
        if !v.canTrash { Text("🔒 \(v.category)") }
    }
}

struct TreemapView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            if let cur = app.current {
                let tiles = Treemap.layout(cur, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6), nested: app.nested,
                                           order: app.order, settled: !(app.scanning || app.refreshing))
                ZStack(alignment: .topLeading) {
                    ForEach(tiles) { t in
                        TileView(tile: t, baseFill: app.fill(for: t.node),
                                 selected: app.selected?.id == t.node.id)
                    }
                    if tiles.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.system(size: 34))
                            Text("Здесь нет крупных элементов").font(.system(.body, design: .rounded))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .id(cur.id)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }
}

// MARK: - Значок ИИ на плитке

struct AIBadge: View {
    let s: Suggestion
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(Circle().fill(Color.purple))
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help("Почему ИИ советует удалить")
        .popover(isPresented: $show, arrowEdge: .bottom) { AIHint(s: s) }
    }
}

struct AIHint: View {
    @EnvironmentObject var app: AppState
    let s: Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(s.color).frame(width: 10, height: 10)
                Text(s.label).font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer(minLength: 12)
                Text(fmtSize(s.node.size)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            Text(s.node.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
            Text(s.reason.isEmpty ? "Агент не пояснил причину." : s.reason)
                .font(.system(size: 12.5, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            if !s.recovery.isEmpty && s.recovery.lowercased() != "n/a" {
                Label(s.recovery, systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Всё уходит в Корзину — можно вернуть.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
