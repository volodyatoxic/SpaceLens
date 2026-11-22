import SwiftUI
import AppKit

@main
struct SpaceLensApp: App {
    @StateObject private var app = AppState()

    init() { signal(SIGPIPE, SIG_IGN) }

    var body: some Scene {
        WindowGroup("Space Lens") {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.ai)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    app.ai.detect()
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--scan"), i + 1 < args.count, app.root == nil, !app.scanning {
                        app.scan(URL(fileURLWithPath: args[i + 1]), force: args.contains("--force"))
                    } else {
                        app.restoreLast()   // открываем последнее место из сохранённого индекса — без повторного скана
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
    }
}
