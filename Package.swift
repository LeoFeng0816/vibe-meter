// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeMeter",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeMeter", targets: ["VibeMeter"]),
        .executable(name: "vibemeter-bridge", targets: ["vibemeter-bridge"]),
        .executable(name: "vibemeter-preview", targets: ["vibemeter-preview"]),
        .library(name: "VibeMeterCore", targets: ["VibeMeterCore"]),
    ],
    targets: [
        // 純邏輯：資料模型、各服務讀取器、提醒、自動繼續狀態機。不依賴 AppKit/SwiftUI，方便測試。
        .target(name: "VibeMeterCore"),
        // 選單介面與 App 狀態（App 與預覽渲染器共用同一套畫面）。
        .target(name: "VibeMeterUI", dependencies: ["VibeMeterCore"]),
        // 選單列 App（SwiftUI MenuBarExtra）。
        .executableTarget(name: "VibeMeter", dependencies: ["VibeMeterCore", "VibeMeterUI"]),
        // 給 Claude Code statusLine / StopFailure hook 呼叫的小工具。
        .executableTarget(name: "vibemeter-bridge", dependencies: ["VibeMeterCore"]),
        // 以真實 SwiftUI 畫面＋範例資料輸出介面預覽 PNG（不是螢幕截圖）。
        .executableTarget(name: "vibemeter-preview", dependencies: ["VibeMeterCore", "VibeMeterUI"]),
        .testTarget(name: "VibeMeterCoreTests", dependencies: ["VibeMeterCore"]),
        .testTarget(name: "VibeMeterUITests", dependencies: ["VibeMeterCore", "VibeMeterUI"]),
    ]
)
