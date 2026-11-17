import AppKit
import SwiftUI
import VibeMeterCore

/// 各 agent 的官方圖示，依序嘗試：
/// 1. 本機已安裝的官方 App（Claude、Codex；Cursor／Antigravity 若有安裝也會優先使用）。
/// 2. 建置時從官方品牌素材頁下載、驗證過 SHA-256 的圖示（Cursor、Antigravity，見 docs/BRAND-ASSETS.md）。
/// 都沒有時回傳 nil，畫面改顯示明確標示「未取得官方圖示」的字母標記，不用通用符號冒充。
@MainActor
public enum BrandIcons {
    public enum Shape {
        /// 已是 macOS App 圖示外形（含留白與圓角）。
        case appIcon
        /// 滿版方形 App 圖示，顯示時套用平台圓角遮罩。
        case squareTile
        /// 透明背景的標誌，放在中性底板上顯示（標誌本身不變更）。
        case glyph
    }

    public struct Icon {
        public var image: NSImage
        /// 圖示來源（顯示在說明文字中，可供核對）。
        public var source: String
        public var shape: Shape
    }

    struct InstalledCandidate {
        var bundleIDs: [String]
        var appPaths: [String]
        /// App 內附、比 App 圖示更準確的官方產品圖示（相對於 Contents/Resources）。
        var resource: (light: String, dark: String)?
    }

    struct BundledAsset {
        var light: String
        var dark: String
        var source: String
        var shape: Shape
    }

    static func installed(_ provider: ProviderID) -> InstalledCandidate {
        switch provider {
        case .claudeCode:
            // Claude Code 使用 Claude 品牌標誌；來源為 Anthropic 官方 Claude App。
            InstalledCandidate(bundleIDs: ["com.anthropic.claudefordesktop"], appPaths: ["/Applications/Claude.app"], resource: nil)
        case .codex:
            InstalledCandidate(bundleIDs: ["com.openai.codex"], appPaths: ["/Applications/Codex.app", "/Applications/ChatGPT.app"],
                               resource: ("icon-codex-light.png", "icon-codex-dark-color.png"))
        case .cursor:
            InstalledCandidate(bundleIDs: ["com.todesktop.230313mzl4w4u92"], appPaths: ["/Applications/Cursor.app"], resource: nil)
        case .antigravity:
            InstalledCandidate(bundleIDs: ["com.google.antigravity"], appPaths: ["/Applications/Antigravity.app"], resource: nil)
        }
    }

    static func bundled(_ provider: ProviderID) -> BundledAsset? {
        switch provider {
        case .cursor:
            BundledAsset(light: "cursor-light.png", dark: "cursor-dark.png",
                         source: "Cursor 官方品牌資源 cursor.com/brand（App Icon 2.5D）", shape: .squareTile)
        case .antigravity:
            BundledAsset(light: "antigravity.png", dark: "antigravity.png",
                         source: "Google Antigravity 官方媒體素材 antigravity.google/press（Icon – Full Color）", shape: .glyph)
        default:
            nil
        }
    }

    /// App 內 `Contents/Resources/BrandIcons`；預覽渲染器可用 `VIBEMETER_BRAND_DIR` 指定。
    static var bundledDirectories: [URL] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("BrandIcons")) }
        if let env = ProcessInfo.processInfo.environment["VIBEMETER_BRAND_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env))
        }
        return dirs
    }

    private static var cache: [String: Icon?] = [:]

    public static func icon(for provider: ProviderID, dark: Bool) -> Icon? {
        let key = "\(provider.rawValue)-\(dark)"
        if let cached = cache[key] { return cached }
        let icon = loadInstalled(provider, dark: dark) ?? loadBundled(provider, dark: dark)
        cache[key] = icon
        return icon
    }

    static func appURL(_ c: InstalledCandidate) -> (URL, String)? {
        for id in c.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (url, id) }
        }
        for path in c.appPaths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let id = Bundle(url: url)?.bundleIdentifier, c.bundleIDs.contains(id) { return (url, id) }
        }
        return nil
    }

    static func loadInstalled(_ provider: ProviderID, dark: Bool) -> Icon? {
        let c = installed(provider)
        guard let (app, bundleID) = appURL(c) else { return nil }
        if let res = c.resource {
            let file = app.appendingPathComponent("Contents/Resources/\(dark ? res.dark : res.light)")
            if let image = NSImage(contentsOf: file) {
                return Icon(image: image, source: "本機 \(app.lastPathComponent)（\(bundleID)）內附 \(file.lastPathComponent)", shape: .appIcon)
            }
        }
        return Icon(image: NSWorkspace.shared.icon(forFile: app.path),
                    source: "本機 \(app.lastPathComponent)（\(bundleID)）App 圖示", shape: .appIcon)
    }

    static func loadBundled(_ provider: ProviderID, dark: Bool) -> Icon? {
        guard let asset = bundled(provider) else { return nil }
        for dir in bundledDirectories {
            if let image = NSImage(contentsOf: dir.appendingPathComponent(dark ? asset.dark : asset.light)) {
                return Icon(image: image, source: asset.source, shape: asset.shape)
            }
        }
        return nil
    }
}

/// agent 圖示：有官方圖示就顯示；沒有就顯示虛線外框字母標記並說明原因。
public struct AgentIcon: View {
    var provider: ProviderID
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    public init(_ provider: ProviderID, size: CGFloat = 26) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        if let icon = BrandIcons.icon(for: provider, dark: scheme == .dark) {
            iconView(icon)
                .frame(width: size, height: size)
                .help("官方圖示來源：\(icon.source)")
                .accessibilityLabel("\(provider.displayName) 圖示")
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
                .overlay(Text(provider.monogram).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary))
                .help("沒有取得 \(provider.displayName) 的官方圖示；此為文字標記，不是品牌圖示")
                .accessibilityLabel("\(provider.displayName)（未取得官方圖示）")
        }
    }

    @ViewBuilder private func iconView(_ icon: BrandIcons.Icon) -> some View {
        let image = Image(nsImage: icon.image).resizable().interpolation(.high)
        // 以 macOS App 圖示網格為準：內容約佔 80%，圓角約為內容的 22.5%。
        let inner = size * 0.82
        switch icon.shape {
        case .appIcon:
            image
        case .squareTile:
            image.frame(width: inner, height: inner)
                .clipShape(RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
        case .glyph:
            RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.17) : .white)
                .overlay(RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                .frame(width: inner, height: inner)
                .overlay(image.aspectRatio(contentMode: .fit).padding(inner * 0.16))
                .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
        }
    }
}

extension ProviderID {
    var monogram: String {
        switch self {
        case .claudeCode: "CC"
        case .codex: "Cx"
        case .cursor: "Cu"
        case .antigravity: "AG"
        }
    }
}
