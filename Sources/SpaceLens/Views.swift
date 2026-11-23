import SwiftUI
import AppKit

// MARK: - Базовые элементы стиля

extension View {
    func card(_ r: CGFloat = 20) -> some View {
        background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct PillButton: ButtonStyle {
    var tint: Color = .accentColor
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(prominent ? tint : tint.opacity(0.14)))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct IconButton: View {
    let symbol: String
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [color, color.shade(0.28)], startPoint: .top, endPoint: .bottom)))
    }
}

struct FileIcon: View {
    let node: FileNode
    let size: CGFloat
    var body: some View {
        if node.isAggregate {
            SettingsIcon(symbol: "square.stack.3d.up.fill", color: .gray, size: size)
        } else {
            Image(nsImage: IconCache.icon(node.path)).resizable().frame(width: size, height: size)
        }
    }
}

struct RiskChip: View {
    let risk: Risk
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: risk.symbol)
            Text(risk.short)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .foregroundStyle(risk.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(risk.color.opacity(0.15)))
    }
}

// MARK: - Корневой экран

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState

    var body: some View {
        ZStack {
            VisualEffect().ignoresSafeArea()
            VStack(spacing: 12) {
                TopBar()
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.16))
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
                    Group {
                        if app.current == nil {
                            if app.scanning { ScanningView() } else { WelcomeView() }
                        } else if ai.active {
                            AIMapView()
                        } else {
                            TreemapView().allowsHitTesting(!app.scanning)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .overlay(alignment: .top) {
                    if (app.scanning && app.current != nil) || app.refreshing { ProgressPill().padding(.top, 12).transition(.move(edge: .top).combined(with: .opacity)) }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        UndoToast()
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.selected?.id)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.lastTrash == nil)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.scanning || app.refreshing)
            }
            .padding(.top, 0).padding(.bottom, 12).padding(.horizontal, 12)
        }
        .ignoresSafeArea()
        .sheet(item: $app.review) { req in ReviewSheet(nodes: req.nodes) }
    }
}

struct ProgressPill: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(app.refreshing ? "Обновляю индекс" : "Сканирую")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Text("\(fmtCount(app.scanFiles)) файлов · \(fmtSize(app.scanBytes))")
                .font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            Button("Отмена") { app.cancelScan() }
                .buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

// MARK: - Верхняя полоса

struct TopBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState
    @State private var showSettings = false
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        HStack(spacing: 10) {
            // место для светофора окна
            Color.clear.frame(width: 64, height: 1)

            Menu {
                Button("Домашняя папка") { app.scan(home) }
                Button("Весь диск") { app.scan(URL(fileURLWithPath: "/")) }
                Button("Загрузки") { app.scan(home.appendingPathComponent("Downloads")) }
                Button("Библиотека") { app.scan(home.appendingPathComponent("Library")) }
                Divider()
                Button("Выбрать папку…") { app.chooseFolder() }
            } label: {
                Label(app.scanRoot?.lastPathComponent ?? "Выбрать место", systemImage: "folder.fill")
            }
            .menuStyle(.borderlessButton).fixedSize()

            if app.current != nil {
                Button { ai.active ? (ai.active = false) : app.up() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(!ai.active && app.current?.parent == nil)
                Breadcrumbs()
            }
            Spacer(minLength: 8)

            if app.current != nil {
                Text(fmtSize(app.current?.size ?? 0))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if app.root != nil {
                    Button { app.toggleAI() } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ai.active ? Color.white : Color.primary)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(ai.active ? Color.purple : Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain).disabled(app.busy)
                    .help("Рекомендации ИИ: что можно удалить")
                }
                IconButton(symbol: "arrow.triangle.2.circlepath", help: "Синхронизировать заново (полный скан, индекс игнорируется)") { app.rescan() }
                    .disabled(app.scanning)
            }
            IconButton(symbol: "slider.horizontal.3", help: "Настройки") { showSettings.toggle() }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsView() }

            StatusText()
        }
        .frame(height: 32)
    }
}

/// Кольцо «сколько занято» и одно число — сколько свободно. Подробности (и время синхронизации) — во всплывающей подсказке.
struct StatusText: View {
    @EnvironmentObject var app: AppState
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()

    private var used: Double {
        guard app.diskTotal > 0 else { return 0 }
        return min(1, max(0, Double(app.diskTotal - app.diskFree) / Double(app.diskTotal)))
    }
    private var tint: Color { used > 0.92 ? .red : (used > 0.8 ? .orange : Color.accentColor) }

    private var tip: String {
        var s = "Занято \(fmtSize(app.diskTotal - app.diskFree)) из \(fmtSize(app.diskTotal)) (\(Int((used * 100).rounded()))%)\nСвободно \(fmtSize(app.diskFree))"
        if app.scanning || app.refreshing { s += "\nСинхронизация…" }
        else if let d = app.lastSync {
            s += d == .distantPast ? "\nИндекс устарел" : "\nОбновлено " + (Date().timeIntervalSince(d) < 60 ? "только что" : Self.rel.localizedString(for: d, relativeTo: Date()))
        }
        if !app.syncNote.isEmpty { s += "\n" + app.syncNote }
        return s
    }

    var body: some View {
        HStack(spacing: 8) {
            if app.diskTotal > 0 {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                    Circle().trim(from: 0, to: used)
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: used)
                }
                .frame(width: 24, height: 24)
            }
            Text(fmtSize(app.diskFree))
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help(tip)
    }
}

struct Breadcrumbs: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(app.crumbs.enumerated()), id: \.element.id) { i, n in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
                    let last = i == app.crumbs.count - 1 && !ai.active
                    Button { app.zoom(to: n) } label: {
                        Text(n.name)
                            .font(.system(size: 13, weight: last ? .semibold : .medium, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(last ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
                if ai.active {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    Button { ai.active = false } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text("Рекомендации ИИ")
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.purple))
                    }
                    .buttonStyle(.plain).help("Выйти из режима ИИ")
                }
            }
        }
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки").font(.system(size: 16, weight: .bold, design: .rounded))

            Toggle(isOn: $app.nested) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вложенные папки").font(.system(size: 13, weight: .medium, design: .rounded))
                    Text("Выключите — будет виден только текущий каталог")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 10) {
                swatchRow("Папки", selection: $app.folderHex)
                swatchRow("Файлы", selection: $app.fileHex)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("ИИ-агент").font(.system(size: 13, weight: .semibold, design: .rounded))
                AgentPicker()
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func swatchRow(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
            HStack(spacing: 8) {
                ForEach(Palette.swatches, id: \.self) { hex in
                    Button { selection.wrappedValue = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: selection.wrappedValue == hex ? 2.5 : 0))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .scaleEffect(selection.wrappedValue == hex ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Приветствие и сканирование

struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 16) {
            SettingsIcon(symbol: "chart.pie.fill", color: .blue, size: 84)
                .shadow(color: .blue.opacity(0.4), radius: 24, y: 10)
            Text("Куда ушло место?").font(.system(size: 32, weight: .bold, design: .rounded))
            HStack(spacing: 10) {
                Button("Моя папка") { app.scan(FileManager.default.homeDirectoryForCurrentUser) }
                    .buttonStyle(PillButton(prominent: true))
                Button("Выбрать…") { app.chooseFolder() }.buttonStyle(PillButton())
            }
            .frame(width: 320)
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            } label: {
                Text("Для полного скана нужен «Полный доступ к диску»").font(.system(size: 12, design: .rounded))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
    }
}

struct ScanningView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            if app.scanFiles > 0 {
                Text("\(fmtCount(app.scanFiles)) файлов · \(fmtSize(app.scanBytes))")
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Text(app.scanPath).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Button("Отмена") { app.cancelScan() }.buttonStyle(PillButton(tint: .red)).frame(width: 130)
        }
    }
}

// MARK: - Карточка выбранного элемента

/// Карточка выбранного элемента — показывается выпадающей модалкой у самой плитки.
struct DetailCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState
    let node: FileNode
    var onClose: (() -> Void)? = nil

    var body: some View {
        let v = Safety.shared.verdict(for: node)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FileIcon(node: node, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(fmtSize(node.size)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                        RiskChip(risk: v.risk)
                    }
                }
                Spacer(minLength: 0)
            }
            if let m = ai.marks[node.id], !m.reason.isEmpty {
                Text("ИИ: " + m.reason).font(.system(size: 12, design: .rounded)).foregroundStyle(m.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(v.reason).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                IconButton(symbol: "magnifyingglass", help: "Показать в Finder") { app.reveal(node) }
                Spacer(minLength: 0)
                if app.canTrash(node) {
                    Button { onClose?(); app.requestTrash([node]) } label: {
                        Label("В Корзину", systemImage: "trash")
                    }
                    .buttonStyle(PillButton(tint: .red, prominent: true)).fixedSize()
                } else {
                    Label("Удаление заблокировано", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.red)
                        .help("Удаление заблокировано правилами безопасности")
                }
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }
}

struct UndoToast: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let b = app.lastTrash {
            HStack(spacing: 12) {
                Image(systemName: b.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(b.failures.isEmpty ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    if !b.records.isEmpty {
                        Text("В Корзине: \(b.records.count) · \(fmtSize(b.bytes))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Место освободится после очистки Корзины")
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                    }
                    if !b.failures.isEmpty {
                        Text(b.failures.joined(separator: "\n")).font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(.orange).lineLimit(3)
                    }
                }
                if !b.records.isEmpty {
                    Button("Отменить") { app.undoLastTrash() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                Button { withAnimation { app.lastTrash = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Подтверждение удаления

struct ReviewSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let nodes: [FileNode]
    @State private var ack = false
    @State private var working = false

    var body: some View {
        let rows = nodes.map { ($0, Safety.shared.verdict(for: $0)) }
        let ok = rows.filter { $0.1.canTrash && app.canTrash($0.0) }
        let blocked = rows.count - ok.count
        let needAck = ok.contains { $0.1.risk != .safe }
        let total = ok.reduce(Int64(0)) { $0 + $1.0.size }

        VStack(alignment: .leading, spacing: 16) {
            Text("Переместить в Корзину?").font(.system(size: 20, weight: .bold, design: .rounded))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rows, id: \.0.id) { n, v in
                        let skip = !(v.canTrash && app.canTrash(n))
                        HStack(spacing: 10) {
                            FileIcon(node: n, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                                Text(skip ? "Будет пропущено: \(v.reason)" : v.reason)
                                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(fmtSize(n.size)).font(.system(size: 12.5, weight: .medium, design: .rounded))
                                RiskChip(risk: v.risk)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(skip ? 0.02 : 0.05)))
                        .opacity(skip ? 0.55 : 1)
                    }
                }
            }
            .frame(minHeight: 70, maxHeight: 280)

            Label("Навсегда ничего не стирается: всё можно вернуть из Корзины или кнопкой «Отменить».",
                  systemImage: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(.green)
            if blocked > 0 {
                Label("Защищённых элементов будет пропущено: \(blocked).", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(.red)
            }
            if needAck {
                Toggle(isOn: $ack) {
                    Text("Я проверил: программа не может подтвердить, что всё это безопасно удалять.")
                        .font(.system(size: 12.5, design: .rounded))
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: 10) {
                Button("Отмена") { dismiss() }.buttonStyle(PillButton(tint: .gray)).keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task { await app.performTrash(ok.map(\.0)); dismiss() }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("В Корзину · \(fmtSize(total))") }
                }
                .buttonStyle(PillButton(tint: .red, prominent: true))
                .disabled(ok.isEmpty || (needAck && !ack) || working)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
