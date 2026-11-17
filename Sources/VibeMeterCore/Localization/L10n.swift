import Foundation

/// 介面語言。保存於 UserDefaults `appLanguage`；預設繁體中文。
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en

    public static let defaultsKey = "appLanguage"

    public var id: String { rawValue }

    /// 以該語言自身的寫法顯示（選單中不翻譯語言名稱）。
    public var nativeName: String {
        switch self {
        case .zhHant: "繁體中文"
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    public var locale: Locale {
        switch self {
        case .zhHant: Locale(identifier: "zh_Hant_TW")
        case .zhHans: Locale(identifier: "zh_Hans_CN")
        case .en: Locale(identifier: "en_US")
        }
    }

    public static func load(from defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .zhHant
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// 簡單、可測試的在地化：原始碼以繁體中文作為 key，`L10nTable` 提供英文（與需要時的簡體人工譯文）。
/// 簡體未列人工譯文時，先套用詞彙對照，再以 ICU `Hant-Hans` 轉換字形。
///
/// 會被保存的字串（例如計畫的「待確認原因」）若含參數，使用 `token(_:_:)` 保存，顯示時再以 `display(_:)` 依目前語言組字。
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: AppLanguage = .zhHant

    public static var current: AppLanguage {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    /// 以 `{0}`、`{1}` 標記參數位置。
    public static func t(_ key: String, _ args: [String], in language: AppLanguage? = nil) -> String {
        fill(template(key, in: language ?? current), args)
    }

    public static func template(_ key: String, in language: AppLanguage) -> String {
        switch language {
        case .zhHant: return key
        case .en: return L10nTable.entries[key]?.en ?? key
        case .zhHans: return L10nTable.entries[key]?.hans ?? simplify(key)
        }
    }

    static func fill(_ template: String, _ args: [String]) -> String {
        var out = template
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "{\(i)}", with: a) }
        return out
    }

    // MARK: 可保存的字串

    private static let tokenStart = "\u{1}"
    private static let tokenSep = "\u{1F}"

    /// 產生可保存、之後可依語言重新組字的字串。
    public static func token(_ key: String, _ args: [String] = []) -> String {
        tokenStart + ([key] + args).joined(separator: tokenSep)
    }

    /// 顯示保存的字串：token 依目前語言組字；舊版的純繁中字串若在表中也會翻譯；其他（例如系統錯誤訊息）原樣顯示。
    public static func display(_ stored: String, in language: AppLanguage? = nil) -> String {
        let lang = language ?? current
        if stored.hasPrefix(tokenStart) {
            let parts = stored.dropFirst(tokenStart.count).components(separatedBy: tokenSep)
            guard let key = parts.first else { return stored }
            // 參數本身也可能是 token 或表中的字串
            return t(key, parts.dropFirst().map { display($0, in: lang) }, in: lang)
        }
        if lang == .zhHant || L10nTable.entries[stored] == nil { return stored }
        return template(stored, in: lang)
    }

    // MARK: 簡體

    /// 繁體與簡體常用詞不同時的對照（先於字形轉換套用）。
    static let hansVocabulary: [(String, String)] = [
        ("儲存庫", "仓库"), ("「文件」", "「文稿」"), ("下載檔", "下载文件"), ("闔上筆電", "合上笔记本"), ("筆電", "笔记本"),
        ("重設", "重置"), ("紀錄", "记录"), ("資訊", "信息"), ("圖示", "图标"), ("逾時", "超时"), ("即時", "实时"),
        ("門檻", "阈值"), ("遠端", "远程"), ("連線", "连接"), ("回傳", "返回"), ("實作", "实现"), ("建置", "构建"),
        ("訊號", "信号"), ("捲動", "滚动"), ("選單", "菜单"), ("開啟", "打开"), ("送出", "发送"), ("閒置", "空闲"),
        ("工作階段", "会话"), ("選單列", "菜单栏"), ("狀態列", "状态栏"), ("資料夾", "文件夹"), ("檔案", "文件"),
        ("資料", "数据"), ("設定", "设置"), ("預設", "默认"), ("螢幕", "屏幕"), ("顯示器", "显示器"),
        ("終端機", "终端"), ("程式", "程序"), ("訊息", "消息"), ("網路", "网络"), ("帳戶", "账户"), ("帳號", "账号"),
        ("視窗", "窗口"), ("介面", "界面"), ("使用者", "用户"), ("支援", "支持"), ("載入", "加载"), ("執行", "运行"),
        ("佇列", "队列"), ("伺服器", "服务器"), ("雜湊", "哈希"), ("金鑰", "密钥"), ("憑證", "证书"), ("範例", "示例"),
        ("示範", "演示"), ("登入", "登录"), ("登出", "退出登录"), ("重新整理", "刷新"), ("簽章", "签名"),
        ("公證", "公证"), ("下載", "下载"), ("儲存", "保存"), ("物件", "对象"), ("最佳化", "优化"), ("連結", "链接"),
        ("點選", "点击"), ("按一下", "点击"), ("通知中心", "通知中心"), ("休眠", "休眠"), ("品質", "质量"),
        ("預覽", "预览"), ("偵測", "检测"), ("探測", "探测"), ("回報", "回报"), ("離線", "离线"), ("線上", "在线"),
    ]

    static func simplify(_ s: String) -> String {
        var out = s
        for (hant, hans) in hansVocabulary { out = out.replacingOccurrences(of: hant, with: hans) }
        return out.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? out
    }
}

/// 全域簡寫：`tr(key, args...)`，key 為繁體中文、以 `{0}` 標記參數。
public func tr(_ key: String, _ args: String...) -> String { L10n.t(key, args) }
