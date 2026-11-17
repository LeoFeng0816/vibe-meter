// 產生 DMG 視窗背景：標題、從 App 指向「應用程式」的箭頭、拖曳說明與首次開啟提示。
// 用法：swift scripts/make-dmg-background.swift <輸出 1x.png> <輸出 2x.png>
// 版面需與 scripts/dmg-settings.py 的圖示座標一致（視窗 660×420，App 在 x=165、Applications 在 x=495、y=205）。
import AppKit

let width: CGFloat = 660, height: CGFloat = 420

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 背景：與 App icon 一致的深藍到靛藍漸層
    let bg = NSGradient(colors: [NSColor(srgbRed: 0.02, green: 0.04, blue: 0.16, alpha: 1),
                                 NSColor(srgbRed: 0.07, green: 0.10, blue: 0.27, alpha: 1)])!
    bg.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)
    let mint = NSColor(srgbRed: 0.33, green: 0.98, blue: 0.70, alpha: 1)

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: style]
        (s as NSString).draw(in: NSRect(x: 20, y: y, width: width - 40, height: size * 1.6), withAttributes: attrs)
    }

    // 標題（座標原點在左下）
    text("安裝 Vibe Meter", size: 24, weight: .bold, color: .white, y: height - 62)
    text("把左邊的 Vibe Meter 拖到右邊的「應用程式」資料夾", size: 14, weight: .medium,
         color: NSColor(white: 1, alpha: 0.85), y: height - 92)

    // 箭頭：在兩個圖示之間（圖示中心 y=205，從上往下算 → 由下往上為 height-205）
    let cy = height - 205
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 250, y: cy))
    shaft.line(to: NSPoint(x: 400, y: cy))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    mint.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 412, y: cy))
    head.line(to: NSPoint(x: 392, y: cy + 14))
    head.line(to: NSPoint(x: 392, y: cy - 14))
    head.close()
    mint.setFill()
    head.fill()

    // 底部提示：簽章與首次開啟
    text("Drag Vibe Meter to Applications", size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.55), y: 92)
    text("此版本尚未經 Apple 公證。如遭封鎖，可在「系統設定 › 隱私權與安全性」核對後允許。",
         size: 11.5, weight: .regular, color: NSColor(white: 1, alpha: 0.7), y: 52)
    text("開啟後在螢幕上方選單列點量規圖示查看用量。", size: 11.5, weight: .regular, color: NSColor(white: 1, alpha: 0.7), y: 32)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
print("ok")
