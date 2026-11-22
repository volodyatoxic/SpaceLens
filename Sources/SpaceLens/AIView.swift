import SwiftUI

/// Выбор агента: CLI, найденные на этом Mac, или API-ключ. Используется в настройках и в окне ИИ-режима.
struct AgentPicker: View {
    @EnvironmentObject var ai: AIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(AgentKind.allCases) { k in
                        Button {
                            ai.agent = k
                        } label: {
                            Text(k.title + (ready(k) ? " ✓" : (k.isCLI ? " — не найден" : " — нужен ключ")))
                        }
                    }
                } label: {
                    Label(ai.agent.title, systemImage: ai.agent.symbol)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Text(ai.agent.isCLI ? (ai.detected[ai.agent] != nil ? "найден на этом Mac" : "не найден") : (ai.hasKey[ai.agent] == true ? "ключ в связке ключей" : ""))
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Button { ai.detect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Найти CLI заново")
            }
            if !ai.agent.isCLI {
                if ai.hasKey[ai.agent] == true {
                    Button("Удалить ключ") { ai.deleteKey() }.buttonStyle(.plain).foregroundStyle(.red)
                        .font(.system(size: 12, design: .rounded))
                } else {
                    HStack {
                        SecureField("Вставьте API-ключ", text: $ai.apiKeyInput).textFieldStyle(.roundedBorder)
                        Button("Сохранить") { ai.saveKey() }.buttonStyle(PillButton()).fixedSize().disabled(ai.apiKeyInput.isEmpty)
                    }
                }
            }
        }
        .padding(12).card(14)
    }

    private func ready(_ k: AgentKind) -> Bool { k.isCLI ? ai.detected[k] != nil : (ai.hasKey[k] ?? false) }
}

/// Содержимое главного окна в ИИ-режиме: карта только из того, что агент советует удалить.
struct AIMapView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ai: AIState

    var body: some View {
        if ai.running {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Агент разбирает «\(app.current?.name ?? "")»… \(ai.elapsed) с")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("Он видит только пути и размеры и ничего не удаляет.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                Button("Стоп") { ai.cancel() }.buttonStyle(PillButton(tint: .red)).frame(width: 120)
            }
        } else if ai.finished, ai.scopeID == app.current?.id {
            results
        } else {
            launch
        }
    }

    private var launch: some View {
        VStack(spacing: 14) {
            SettingsIcon(symbol: "sparkles", color: .purple, size: 64)
            Text("Рекомендации ИИ").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Агент подсветит красным то, что можно удалить, и жёлтым — то, что стоит проверить.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            AgentPicker().frame(width: 420)
            if let e = ai.error {
                Text(e).font(.system(size: 12, design: .rounded)).foregroundStyle(.red)
                    .padding(10).frame(width: 420, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.1)))
            }
            Button { ai.analyze() } label: { Label("Проанализировать", systemImage: "sparkles") }
                .buttonStyle(PillButton(tint: .purple, prominent: true)).frame(width: 240)
                .disabled(!ai.isReady)
        }
        .padding(24)
    }

    private var results: some View {
        let list = ai.listed
        let reds = list.filter { $0.effective == .safe }
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    if !ai.summary.isEmpty {
                        Text(ai.summary).font(.system(size: 12.5, design: .rounded)).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        legend(Color(red: 0.95, green: 0.27, blue: 0.27), "можно удалить")
                        legend(Color(red: 0.96, green: 0.70, blue: 0.08), "с осторожностью")
                        Text("значок ✨ на плитке — почему").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 10)
                Button { app.requestTrash(reds.map(\.node)) } label: {
                    Label("Красные в Корзину (\(reds.count)) · \(fmtSize(reds.reduce(0) { $0 + $1.node.size }))", systemImage: "trash")
                }
                .buttonStyle(PillButton(tint: .red, prominent: true)).fixedSize().disabled(reds.isEmpty)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.system(size: 34))
                    Text("Агент не нашёл здесь ничего, что стоило бы удалить").font(.system(.body, design: .rounded))
                    Button("Проанализировать ещё раз") { ai.analyze() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let placed = Treemap.squarify(list.map(\.node), in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6))
                    ZStack(alignment: .topLeading) {
                        ForEach(placed, id: \.0.id) { n, r in
                            TileView(tile: Tile(node: n, rect: r, depth: 0, container: false),
                                     baseFill: app.fill(for: n), selected: app.selected?.id == n.id)
                        }
                    }
                }
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 9, height: 9)
            Text(t).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}
