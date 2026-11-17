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
        Window("Vibe Meter · Demo", id: "demo") {
            MenuContentView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
        VibeMeterStatusMenu(model: model)
    }
}

struct VibeMeterApp: App {
    @State private var model: AppModel

    @MainActor init() {
        let model = AppModel()
        #if canImport(Sparkle)
        if !model.dryRun, let installer = SparkleInstaller(
            status: { [weak model] in model?.updateInstallStatus = $0 },
            setCommitted: { [weak model] in model?.updateInstallCommitted = $0 }
        ) {
            model.startAutomaticInstall = installer.start
            model.cancelAutomaticInstall = installer.cancel
        }
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene { VibeMeterStatusMenu(model: model) }
}

struct VibeMeterStatusMenu: Scene {
    let model: AppModel

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model, statusMenu: true)
        } label: {
            MenuBarLabel(display: model.menuBarDisplay, selection: model.menuBarSelection, language: model.language,
                         waiting: model.visiblePlans.filter { !$0.state.isFinished }.count,
                         keepingAwake: model.isKeepingAwake, demo: model.demo)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    var display: MenuBarDisplay
    var selection: MenuBarSelection
    /// 語言切換時讓標籤重新繪製。
    var language: AppLanguage
    var waiting: Int
    var keepingAwake: Bool
    var demo: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image())
            // 不可用時顯示「—」，不顯示假的 0%，也不改顯示其他 agent／週期。
            Text(demo ? "Demo" : display.menuBarText).monospacedDigit()
            if waiting > 0 { Image(systemName: "arrow.triangle.2.circlepath") }
            if keepingAwake { Image(systemName: "cup.and.saucer.fill") }
        }
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        if demo { return "Vibe Meter Demo" }
        switch display {
        case .remaining(let r, _, _): return tr("Vibe Meter，{0}剩餘 {1}", selection.label + " ", ZhFormat.percent(r))
        case .unavailable(let why): return tr("Vibe Meter，{0}：{1}", selection.label, why.explanation)
        }
    }
}
