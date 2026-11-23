import SwiftUI

struct Tile: Identifiable {
    var id: UUID { node.id }
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let container: Bool
}

enum Treemap {
    static func layout(_ root: FileNode, in rect: CGRect, nested: Bool) -> [Tile] {
        var out: [Tile] = []
        place(root.children, in: rect, depth: 0, nested: nested, out: &out)
        return out
    }

    private static func place(_ nodes: [FileNode], in rect: CGRect, depth: Int, nested: Bool, out: inout [Tile]) {
        guard rect.width > 8, rect.height > 8, out.count < 700 else { return }
        let total = nodes.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return }
        let area = Double(rect.width * rect.height)
        let minArea: Double = depth == 0 ? 800 : 1000
        var kept = nodes.filter { Double($0.size) / total * area >= minArea }
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
                place(n.children, in: inner, depth: depth + 1, nested: nested, out: &out)
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

struct TileView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState
    let tile: Tile
    let baseFill: Color
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let mark = ai.marks[tile.node.id]
        let fill = mark?.color ?? baseFill
        let r = tile.rect.insetBy(dx: 1.5, dy: 1.5)
        let radius = min(tile.depth == 0 ? 16.0 : (tile.depth == 1 ? 11.0 : 8.0), min(r.width, r.height) / 4)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            if tile.container {
                shape.fill(fill.opacity(0.20))
                shape.strokeBorder(fill.opacity(0.55), lineWidth: 1)
                HStack(spacing: 6) {
                    Text(tile.node.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(fmtSize(tile.node.size)).opacity(0.75)
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.9))
                .padding(.horizontal, 10).padding(.top, 7)
            } else {
                shape.fill(LinearGradient(colors: [fill.shade(0.02), fill.shade(0.30)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                if r.width >= 52 && r.height >= 30 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.node.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(r.height > 64 ? 2 : 1)
                        Text(fmtSize(tile.node.size))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .padding(8)
                }
                if let img = IconCache.real(for: tile.node), r.width >= 64, r.height >= 52 {
                    let side = min(max(min(r.width, r.height) * 0.42, 24), 72)
                    Image(nsImage: img)
                        .resizable().interpolation(.high).scaledToFit()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                } else if r.width >= 110 && r.height >= 84 {
                    Image(systemName: FileKind.of(tile.node).symbol)
                        .font(.system(size: min(min(r.width, r.height) * 0.26, 64), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
            }
            if selected {
                shape.strokeBorder(.white, lineWidth: 2.5).shadow(color: fill.opacity(0.9), radius: 8)
            }
            if let m = mark, r.width >= 44, r.height >= 30 {
                AIBadge(s: m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .frame(width: max(r.width, 1), height: max(r.height, 1))
        .brightness(hover && !tile.container ? 0.07 : 0)
        .contentShape(shape)
        .onHover { hover = $0 }
        .offset(x: r.minX, y: r.minY)
        .animation(.easeOut(duration: 0.3), value: tile.rect)
        .help("\(tile.node.path)\n\(fmtSize(tile.node.size))")
        .onTapGesture(count: 2) { app.activate(tile.node) }
        .onTapGesture { app.select(tile.node) }
        .contextMenu { NodeMenu(node: tile.node) }
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
                let tiles = Treemap.layout(cur, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6), nested: app.nested)
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
