import AppKit
import SwiftUI
import VibeMeterCore
import VibeMeterUI

// 以「真實的」Vibe Meter SwiftUI 選單畫面＋範例資料輸出 PNG（淺色＋深色）。
// 這不是螢幕截圖：圖片底部會標示「介面預覽」。
// 用法：vibemeter-preview <輸出.png> [App icon PNG]

let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "docs/vibe-meter-preview.png"
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
if args.count > 2, let icon = NSImage(contentsOfFile: args[2]) { app.applicationIconImage = icon }

@MainActor
func render(_ appearance: NSAppearance.Name, expanded: Set<String> = [], maxScroll: CGFloat = 560) -> NSBitmapImageRep {
    let model = AppModel.sample(now: Date())
    model.expandedSections = expanded
    let root = MenuContentView(model: model, maxScrollHeight: maxScroll)
        .background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: appearance)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuContentView.width, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    // 可捲動區域的高度要等量測完成；多跑幾次排版再取尺寸。
    for _ in 0..<4 {
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

@MainActor
func compose(_ panels: [NSBitmapImageRep]) -> Data {
    let scale = CGFloat(panels[0].pixelsWide) / panels[0].size.width
    let gap: CGFloat = 24, pad: CGFloat = 24, caption: CGFloat = 64
    let width = panels.reduce(pad * 2 - gap) { $0 + $1.size.width + gap }
    let height = (panels.map(\.size.height).max() ?? 0) + pad * 2 + caption
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var x = pad
    for panel in panels {
        let maxH = panels.map(\.size.height).max() ?? 0
        let rect = NSRect(x: x, y: caption + pad + (maxH - panel.size.height), width: panel.size.width, height: panel.size.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        panel.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        x += panel.size.width + gap
    }
    let text = "介面預覽（非螢幕截圖）：以 Vibe Meter 真實 SwiftUI 選單畫面＋範例資料渲染。由左至右：淺色預設、深色預設、展開後限制高度（中間區域可捲動，頂部與「結束」固定）、深色完整展開。Claude／Codex 圖示取自本機官方 App；Cursor／Antigravity 取自官方品牌素材頁。"
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1)]
    (text as NSString).draw(in: NSRect(x: pad, y: 12, width: width - pad * 2, height: 44), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    if args.count > 1, args[1] == "--dump-l10n" {
        // 檢查用：列出所有翻譯 key 的簡體與英文結果。
        for key in L10nTable.entries.keys.sorted() {
            print("\(key)\t\(L10n.template(key, in: .zhHans))\t\(L10n.template(key, in: .en))".replacingOccurrences(of: "\n", with: "⏎"))
        }
        exit(0)
    }
    if args.count > 1, args[1] == "--menubar-icon", args.count > 2 {
        // 檢查用：把選單列樣板圖示放大輸出（淺色、深色選單列各一）。
        let img = MenuBarIcon.image(size: 18)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 288, pixelsHigh: 144, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        for (i, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            bg.setFill(); NSRect(x: CGFloat(i) * 144, y: 0, width: 144, height: 144).fill()
            let tinted = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: CGFloat(i) * 144 + 18, y: 18, width: 108, height: 108))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
        exit(0)
    }
    let data = compose([render(.aqua), render(.darkAqua),
                        render(.aqua, expanded: ["auto", "settings"], maxScroll: 420),
                        render(.darkAqua, expanded: ["auto", "sessions", "settings"], maxScroll: 2000)])
    let url = URL(fileURLWithPath: output)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try data.write(to: url)
        print(url.path)
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
}
