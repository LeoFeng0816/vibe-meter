import Foundation

/// 使用者明確選擇的「一般額度重設後 30 秒嘗試一次」（Codex）。
///
/// 身分與時間證據與官方路徑相同（`CodexQuotaObservations` v4 帳本：中止前已確認同帳戶、官方 `completedAt`、
/// 非 null 的一般用量許可、中止前後有界時間內觀察到額度用盡與官方重設時間）。唯一放寬的是額度對應：
/// 沒有任何模型專屬桶時，接受官方唯一的一般 `codex` 桶（`normalModelSlug` 為 null）。
/// 到期後以新鮮、同帳戶、許可非 null 的官方回應嘗試一次。這只代表一般週期已到重設時間，不證明原模型額度已恢復；
/// 可能再次中止，也可能使用已啟用的 credits。授權只存在記憶體，每次由帳本重建；計畫檔內容無法自行授權。
public enum CodexTimedResumePolicy {
    /// 重設時間後的緩衝（使用者指定）。
    public static let buffer: TimeInterval = 30
    /// 有效重設後超過這段時間仍未送出（例如長時間睡眠或關機），不再視為同一次中止的續作。
    public static let lateLimit: TimeInterval = 24 * 3600
    /// 延期上限：有效重設最多晚於原重設這麼久（週額度的長度）。
    public static let maxDeferral: TimeInterval = 7 * 86400

    /// Codex 公開錯誤中代表工作區花費上限或 credits 用盡的類型：屬費用障礙，不是一般週期用盡。
    public static let costBarrierTypes: Set<String> = [
        "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached",
        "workspace_owner_credits_depleted", "workspace_member_credits_depleted",
    ]

    /// 官方唯一的一般 `codex` 額度桶（ID 明確為 `codex`、沒有模型別名）。缺少、重複或 ID 不明時回傳 nil。
    public static func generalBucket(_ snapshot: UsageSnapshot) -> LimitBucket? {
        let general = (snapshot.buckets ?? []).filter {
            $0.limitID == UsageSnapshot.generalCodexLimitID && ($0.modelSlug == nil || $0.modelSlug?.isEmpty == true)
        }
        return general.count == 1 ? general[0] : nil
    }

    /// 回報同一個模型別名的桶數。0 才能改用一般桶；1 走官方路徑；2 以上是官方對應歧義，一律不送。
    public static func modelBucketCount(_ snapshot: UsageSnapshot, model: String) -> Int {
        (snapshot.buckets ?? []).filter { $0.modelSlug == model }.count
    }

    /// 明確的費用障礙（spend control、工作區花費上限、工作區 credits 用盡）。
    public static func costBarrier(_ snapshot: UsageSnapshot) -> Bool {
        if snapshot.spendControlReached == true || snapshot.limitReachedType.map(costBarrierTypes.contains) == true { return true }
        return (snapshot.buckets ?? []).contains {
            $0.spendControlReached == true || $0.limitReachedType.map(costBarrierTypes.contains) == true
        }
    }

    /// 合法延期：晚於原重設、最多晚 `maxDeferral`（含）。延期決定、持久化與證據保留共用這個規則。
    public static func isValidDeferral(_ authorization: CodexSessionAuthorization, to reset: Date) -> Bool {
        reset > authorization.resetsAt && reset.timeIntervalSince(authorization.resetsAt) <= maxDeferral
    }

    /// 證據需保留到的時間：有效重設＋送出期限。
    public static func witnessRetention(effectiveReset: Date) -> Date { effectiveReset.addingTimeInterval(lateLimit) }

    /// 同一個一般桶裡，比目前有效重設更晚、且在合理範圍內的已滿週期重設時間（官方延期）。
    static func laterReset(_ bucket: LimitBucket, after effective: Date, now: Date) -> Date? {
        bucket.windows.filter { ($0.kind == .fiveHour || $0.kind == .weekly) && $0.usedPercent >= 100 }
            .compactMap { window -> Date? in
                guard let reset = window.resetsAt, reset.timeIntervalSince1970.isFinite, reset > effective, reset > now else { return nil }
                let length: TimeInterval = window.kind == .weekly ? 7 * 86400 : 5 * 3600
                return reset.timeIntervalSince(now) <= length ? reset : nil
            }.max()
    }

    /// 回應是否為「同一帳戶、許可非 null、官方即時、時間合理」：只有這種回應能用來延期或送出。
    static func verified(_ authorization: CodexSessionAuthorization, _ snapshot: UsageSnapshot, now: Date) -> Bool {
        snapshot.provider == .codex && snapshot.source == .codexAppServer && !snapshot.isStale(now: now)
            && snapshot.usageAllowed != nil && authorization.matches(accountID: snapshot.accountID)
    }

    /// 有效重設：原 witness 的官方重設，或之後已核對、持久化的較晚重設（只能延後，不能提前）。
    public static func effectiveReset(_ authorization: CodexSessionAuthorization, deferredTo: Date?) -> Date {
        guard let deferredTo, isValidDeferral(authorization, to: deferredTo) else { return authorization.resetsAt }
        return deferredTo
    }

    public enum Evaluation: Equatable, Sendable {
        case notDue(Date)
        case due
        /// 已核對的同帳戶回應提供較晚的官方重設：持久化並改到新時間＋30 秒。
        case `defer`(Date)
        /// 暫不送出（例如帳戶未驗證、等待連線），保留計畫。
        case wait(String)
        /// 不送出，轉為待確認。
        case stop(String)
    }

    /// 以最近一次官方即時資料判斷是否到時。先驗證帳戶與非 null 許可，才採用回應中的較晚重設。
    public static func evaluate(_ authorization: CodexSessionAuthorization, deferredTo: Date?, live: UsageSnapshot?,
                                now: Date) -> Evaluation {
        let effective = effectiveReset(authorization, deferredTo: deferredTo)
        let due = effective.addingTimeInterval(buffer)
        if now > effective.addingTimeInterval(lateLimit) {
            return .stop(L10n.token("已過重設時間超過 24 小時，未自動送出；可手動繼續"))
        }
        guard let live, live.provider == .codex, live.source == .codexAppServer, !live.isStale(now: now) else {
            return now >= due ? .wait(L10n.token("等待連線：需要新的 Codex 官方資料才能檢查")) : .notDue(due)
        }
        if let account = live.accountID, !account.isEmpty, !authorization.matches(accountID: account) {
            return .stop(L10n.token("目前 Codex 帳戶與中止時不同，不送出"))
        }
        // 明確的費用障礙：不採用延期也不送出（等它消失後的新回應）。
        if costBarrier(live) { return .wait(L10n.token("Codex 回報費用控制或工作區上限已達，不送出")) }
        // 只有已驗證的回應（同帳戶、許可非 null）才能改期；未知登入帶來的較晚時間不採用。
        if verified(authorization, live, now: now), let bucket = generalBucket(live),
           let later = laterReset(bucket, after: effective, now: now) {
            // 超過合法延期上限：轉待確認，不持久化也不反覆重排。
            return isValidDeferral(authorization, to: later)
                ? .defer(later) : .stop(L10n.token("Codex 回報的重設時間超過原重設 7 天，未自動送出；可手動繼續"))
        }
        guard now >= due else { return .notDue(due) }
        if live.usageAllowed == nil { return .wait(L10n.token("Codex 未驗證目前登入（一般用量許可為 null），暫不送出")) }
        if costBarrier(live) { return .wait(L10n.token("Codex 回報費用控制或工作區上限已達，不送出")) }
        return .due
    }

    public enum PreflightOutcome: Equatable, Sendable {
        /// 可以送出；附上要顯示的風險說明。
        case send(note: String)
        /// 已核對的較晚官方重設：延期，不送出。
        case `defer`(Date)
        /// 暫不送出，保留計畫稍後再檢查。
        case retry(String)
        /// 不送出，轉為待確認。
        case stop(String)
    }

    /// 送出前以剛讀取的官方資料最後檢查。回應必須是到期後取得的新鮮官方資料、同帳戶、許可非 null。
    /// 一般桶仍 100% 但沒有較晚的有效重設（缺重設或仍是舊時間）時，依使用者授權仍嘗試一次（不宣稱已恢復）。
    public static func preflight(_ authorization: CodexSessionAuthorization, deferredTo: Date?, snapshot: UsageSnapshot,
                                 now: Date) -> PreflightOutcome {
        let effective = effectiveReset(authorization, deferredTo: deferredTo)
        let due = effective.addingTimeInterval(buffer)
        guard snapshot.provider == .codex, snapshot.source == .codexAppServer else {
            return .retry(L10n.token("需要 Codex app-server 的即時官方資料，暫不送出"))
        }
        guard !snapshot.isStale(now: now), snapshot.observedAt <= now.addingTimeInterval(5) else {
            return .retry(L10n.token("Codex 官方資料不是最新的，暫不送出"))
        }
        guard snapshot.observedAt >= due else { return .retry(L10n.token("尚未到重設時間＋30 秒")) }
        guard let account = snapshot.accountID, !account.isEmpty else { return .retry(L10n.token("Codex 未回報目前帳戶，暫不送出")) }
        guard authorization.matches(accountID: account) else { return .stop(L10n.token("目前 Codex 帳戶與中止時不同，不送出")) }
        // 官方在帳戶或使用者與目前登入不符時把許可設為 null，但可能仍回舊 accountId：null 不能確認同一登入。
        guard let allowed = snapshot.usageAllowed else {
            return .retry(L10n.token("Codex 未驗證目前登入（一般用量許可為 null），暫不送出"))
        }
        if costBarrier(snapshot) { return .retry(L10n.token("Codex 回報費用控制或工作區上限已達，不送出")) }
        switch modelBucketCount(snapshot, model: authorization.model) {
        case 0: break
        case 1: return .stop(L10n.token("官方已回報此模型的專屬額度桶，改由官方恢復判斷，不以一般額度送出"))
        default: return .stop(L10n.token("官方回報多個同模型額度桶，對應不明，不送出"))
        }
        guard let bucket = generalBucket(snapshot) else { return .retry(L10n.token("找不到官方唯一的一般 codex 額度桶，暫不送出")) }
        if let later = laterReset(bucket, after: effective, now: now) {
            return isValidDeferral(authorization, to: later)
                ? .defer(later) : .stop(L10n.token("Codex 回報的重設時間超過原重設 7 天，未自動送出；可手動繼續"))
        }
        let stillFull = bucket.windows.contains { ($0.kind == .fiveHour || $0.kind == .weekly) && $0.usedPercent >= 100 }
        if stillFull {
            return .send(note: L10n.token("已過一般額度重設時間 30 秒，但 Codex 仍回報已滿且沒有較晚的重設：依設定嘗試一次，可能再次中止或使用已啟用的付費用量"))
        }
        return .send(note: allowed
            ? L10n.token("已過一般額度重設時間 30 秒，依設定嘗試一次；不是官方確認原模型額度已恢復，也可能使用已啟用的付費用量")
            : L10n.token("依一般額度重設時間嘗試一次，但 Codex 仍回報一般用量未允許：可能再次中止或使用已啟用的付費用量"))
    }
}

/// 一般額度定時嘗試的工作階段層級記錄（純邏輯）。持久化與跨程序原子性見 `CodexTimedSessionStore`。
public struct CodexTimedDispatchLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var anchorTurnID: String
        public var effectiveReset: Date
        public var dispatchedAt: Date
        /// 使用者之後對這個工作階段明確按下「手動繼續」。官方 turn 沒有可信的來源標記：
        /// 進行中或已完成的 turn 都可能來自自己排入的提示，不能據此解除防付費重試。
        public var userConfirmedAt: Date?
    }

    public private(set) var entry: Entry?

    public init(entry: Entry? = nil) { self.entry = entry }

    static let format = 1
    private enum CodingKeys: String, CodingKey { case version, entry }

    public enum SchemaError: Error, Equatable { case version, missingEntry, invalidEntry }

    /// 既存檔案必須是可辨識的格式且含有效 entry；`{}`、`{"entry":null}`、未知形狀或版本一律拒絕（fail closed）。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decodeIfPresent(Int.self, forKey: .version) == Self.format else { throw SchemaError.version }
        guard let entry = try values.decodeIfPresent(Entry.self, forKey: .entry) else { throw SchemaError.missingEntry }
        guard !entry.anchorTurnID.isEmpty, entry.effectiveReset.timeIntervalSince1970.isFinite,
              entry.dispatchedAt.timeIntervalSince1970.isFinite,
              entry.userConfirmedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= entry.dispatchedAt }) ?? true else {
            throw SchemaError.invalidEntry
        }
        self.entry = entry
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.format, forKey: .version)
        try values.encode(entry, forKey: .entry)
    }

    /// 新的中止不自動嘗試：仍屬已嘗試的週期，或嘗試之後使用者尚未明確手動確認。
    public func blocks(resetsAt: Date) -> Bool {
        guard let entry else { return false }
        return resetsAt <= entry.effectiveReset || entry.userConfirmedAt == nil
    }

    /// 送出前保留：同一錨點或被擋下時拒絕，成功才記錄（不論之後結果）。
    public mutating func reserve(anchorTurnID: String, effectiveReset: Date, now: Date) -> Bool {
        if let entry, entry.anchorTurnID == anchorTurnID { return false }
        guard !blocks(resetsAt: effectiveReset) else { return false }
        entry = Entry(anchorTurnID: anchorTurnID, effectiveReset: effectiveReset, dispatchedAt: now, userConfirmedAt: nil)
        return true
    }

    /// 使用者明確手動繼續這個工作階段（在自動嘗試之後）。之後新週期的中止才會再評估自動嘗試。
    /// `date` 必須是手動送出「開始」的時間：只有晚於目前保留的手動操作才解除，較早開始、較晚完成的手動送出不會解除之後的自動保留。
    public mutating func markUserConfirmed(at date: Date) {
        guard var current = entry, date >= current.dispatchedAt else { return }
        current.userConfirmedAt = date
        entry = current
    }
}

/// 每個工作階段一個檔案；讀取→判斷→寫入在 `flock` 內完成，多個 App 程序與重啟後一致。
/// 只有檔案確實不存在才視為沒有記錄；存在但無法讀取或解碼一律 fail closed（擋下）。
public struct CodexTimedSessionStore: Sendable {
    public let directory: URL

    public enum StoreError: Error, Equatable { case unreadable, corrupt }

    public init(directory: URL) { self.directory = directory }

    private func file(_ sessionID: String) -> URL {
        directory.appendingPathComponent(AccountHash.of("session|" + sessionID.lowercased()) + ".json")
    }

    func load(_ url: URL) throws -> CodexTimedDispatchLedger {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .init()
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .init()
        } catch {
            throw StoreError.unreadable
        }
        guard let ledger = try? VibeMeterJSON.decoder.decode(CodexTimedDispatchLedger.self, from: data) else { throw StoreError.corrupt }
        return ledger
    }

    private func transaction<T>(_ sessionID: String, _ body: (inout CodexTimedDispatchLedger) -> T) throws -> T {
        let url = file(sessionID)
        return try BridgeLock.withLock(at: directory.appendingPathComponent(".lock")) {
            var ledger = try load(url)
            let before = ledger
            let result = body(&ledger)
            if ledger != before { try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(ledger), to: url) }
            return result
        }
    }

    /// 偵測時的唯讀判斷（最終決定在 `reserve`）。記錄無法讀取時視為擋下。
    public func blocks(sessionID: String, resetsAt: Date) -> Bool {
        guard let ledger = try? load(file(sessionID)) else { return true }
        return ledger.blocks(resetsAt: resetsAt)
    }

    /// 送出前在跨程序鎖內原子保留。無法讀取、解碼或寫入時視為不可送。
    public func reserve(sessionID: String, anchorTurnID: String, effectiveReset: Date, now: Date) -> Bool {
        (try? transaction(sessionID) { $0.reserve(anchorTurnID: anchorTurnID, effectiveReset: effectiveReset, now: now) }) ?? false
    }

    /// 使用者明確手動繼續後記錄（失敗則維持擋下）。
    public func markUserConfirmed(sessionID: String, at date: Date) {
        _ = try? transaction(sessionID) { $0.markUserConfirmed(at: date) }
    }

    public func entry(sessionID: String) -> CodexTimedDispatchLedger.Entry? { (try? load(file(sessionID)))?.entry }
}
