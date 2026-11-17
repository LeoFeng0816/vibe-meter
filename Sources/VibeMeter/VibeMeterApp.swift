import AppKit
import SwiftUI
import VibeMeterCore
import VibeMeterUI

@main
enum VibeMeterLauncher {
    @MainActor static func main() {
        if Bundle.main.object(forInfoDictionaryKey: "VibeMeterDemoOnly") as? Bool == true
            || ProcessInfo.processInfo.environment["VIBEMETER_DEMO"] == "1" {
            VibeMeterDemoApp.main()
        } else {
            VibeMeterApp.main()
        }
    }
}

struct VibeMeterDemoApp: App {
    @State private var model = AppModel.sample(now: Date(), demo: true)

    var body: some Scene {
        Window("Vibe Meter · 示範資料", id: "demo") {
            MenuContentView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }
}

struct VibeMeterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(remaining: model.menuBarRemaining, waiting: model.visiblePlans.filter { !$0.state.isFinished }.count)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    var remaining: Double?
    var waiting: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image())
            if let remaining { Text(ZhFormat.percent(remaining)).monospacedDigit() }
            if waiting > 0 { Image(systemName: "arrow.triangle.2.circlepath") }
        }
        .accessibilityLabel(remaining.map { "Vibe Meter，最低剩餘 \(ZhFormat.percent($0))" } ?? "Vibe Meter")
    }
}
