import CryptoKit
import Foundation

/// 帳戶 id 只以雜湊保存與比較（不寫入原始值到帳本）。
public enum AccountHash {
    public static func of(_ accountID: String) -> String {
        SHA256.hash(data: Data("vibemeter-account|\(accountID)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// 自動是預設模式。手動限定模式只允許使用者選定的 Codex 帳戶、工作階段和模型。
public struct CodexContinuationSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case automatic, scoped }

    public struct Scope: Codable, Hashable, Sendable {
        public let sessionID: String
        public let accountHash: String
        public let model: String

        public init(sessionID: String, accountID: String, model: String) {
            self.sessionID = sessionID.lowercased()
            accountHash = AccountHash.of(accountID)
            self.model = model
        }

        func matches(sessionID: String, accountHash: String, model: String) -> Bool {
            self.sessionID == sessionID.lowercased() && self.accountHash == accountHash && self.model == model
        }
    }

    public var mode: Mode = .automatic
    public var scope: Scope?
    public init(mode: Mode = .automatic, scope: Scope? = nil) {
        self.mode = mode
        self.scope = scope
    }

    public func permits(_ authorization: CodexSessionAuthorization) -> Bool {
        mode == .automatic || scope?.matches(sessionID: authorization.sessionID, accountHash: authorization.accountHash,
                                              model: authorization.model) == true
    }
}

/// 本次送出的記憶體授權。由官方觀察、目前政策和工作階段重建，計畫檔不能直接授權。
public struct CodexSessionAuthorization: Hashable, Sendable {
    public enum Basis: String, Hashable, Sendable {
        /// 官方模型專屬額度桶的明確拒絕與恢復許可。
        case modelBucket
        /// 使用者選擇：官方唯一一般 `codex` 桶的用盡觀察，重設後 30 秒嘗試一次（不證明原模型恢復）。
        case generalBucketTimed
    }

    public let basis: Basis
    public let sessionID: String
    public let turnID: String
    public let accountHash: String
    public let model: String
    /// 中止 turn 的模型對應的官方額度桶（保留 metered ID 與模型別名）。
    public let quotaKey: String
    public let observedAt: Date
    public let window: WindowKind
    public let resetsAt: Date

    public func matches(accountID: String?) -> Bool {
        accountID.map { !$0.isEmpty && AccountHash.of($0) == accountHash } == true
    }
}

/// 保存 app-server 確實回報的拒絕及用量週期。這是同一時段的觀察，不能證明個別 turn 的歷史帳戶。
///
/// Coalesce consecutive samples of the same denial so a weekly block remains valid after restart.
public struct CodexQuotaObservations: Codable, Sendable {
    private struct Denial: Codable, Hashable, Sendable {
        let quotaKey: String
        let firstObservedAt: Date
        let precedingConfirmedAt: Date?
        var lastObservedAt: Date
        let window: WindowKind
        let resetsAt: Date
        /// 已核對的官方延期把這份證據保留到較晚的有效重設之後（只會延長，不會改變證據本身）。
        var retainUntil: Date? = nil

        func expired(at now: Date, grace: TimeInterval) -> Bool {
            now > max(resetsAt.addingTimeInterval(grace), retainUntil ?? .distantPast)
        }
    }

    // Discard v2 data, which could have mistaken a nullable permission for a denial.
    // v4 增加一般桶用盡觀察；v3 資料丟棄重建。
    private static let format = 4
    private let version = Self.format
    private var accountHash: String?
    private var accountSince: Date?
    private var lastObservation: Date?
    private var lastConfirmedAt: Date?
    private var denials: [Denial] = []
    /// 一般 `codex` 桶已滿的觀察（許可為非 null 的 true 或 false；null 不記錄）。只供使用者選擇的定時嘗試。
    private var exhaustions: [Denial] = []
    private enum CodingKeys: String, CodingKey { case version, accountHash, accountSince, lastObservation, lastConfirmedAt, denials, exhaustions }

    private static let nearStop: TimeInterval = 2 * 60
    private static let mergeGap: TimeInterval = 90
    private static let resetGrace: TimeInterval = 12 * 3600

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.format else { return }
        accountHash = try values.decodeIfPresent(String.self, forKey: .accountHash)
        accountSince = try values.decodeIfPresent(Date.self, forKey: .accountSince)
        lastObservation = try values.decodeIfPresent(Date.self, forKey: .lastObservation)
        lastConfirmedAt = try values.decodeIfPresent(Date.self, forKey: .lastConfirmedAt)
        denials = Array(try values.decode([Denial].self, forKey: .denials).suffix(256))
        exhaustions = Array(try values.decodeIfPresent([Denial].self, forKey: .exhaustions)?.suffix(256) ?? [])
    }

    public var denialCount: Int { denials.count }

    public mutating func observe(_ snapshot: UsageSnapshot, now: Date) {
        guard snapshot.provider == .codex, snapshot.source == .codexAppServer, !snapshot.isStale(now: now),
              lastObservation.map({ snapshot.observedAt > $0 }) ?? true else { return }
        let previousObservation = lastObservation
        lastObservation = snapshot.observedAt
        let current = snapshot.accountID.flatMap { $0.isEmpty ? nil : AccountHash.of($0) }
        if current != accountHash {
            accountHash = current
            accountSince = nil
            lastConfirmedAt = nil
            denials = []
            exhaustions = []
        }
        denials.removeAll { $0.expired(at: now, grace: Self.resetGrace) || $0.lastObservedAt > now }
        exhaustions.removeAll { $0.expired(at: now, grace: Self.resetGrace) || $0.lastObservedAt > now }
        guard current != nil, let allowed = snapshot.usageAllowed else {
            accountSince = nil
            lastConfirmedAt = nil
            denials = []
            exhaustions = []
            return
        }
        if accountSince == nil { accountSince = snapshot.observedAt }
        let precedingConfirmedAt = lastConfirmedAt
        lastConfirmedAt = snapshot.observedAt
        // 明確費用障礙（spend control、工作區花費上限、credits 用盡）時不記錄任何中止證據：之後障礙消失也不能用這段資料授權。
        let costBlocked = CodexTimedResumePolicy.costBarrier(snapshot)
        if !costBlocked, let general = CodexTimedResumePolicy.generalBucket(snapshot) {
            Self.record(general, into: &exhaustions, snapshot: snapshot, previousObservation: previousObservation,
                        precedingConfirmedAt: precedingConfirmedAt)
        }
        guard !allowed, !costBlocked else { return }

        for bucket in snapshot.buckets ?? [] where bucket.spendControlReached != true {
            for window in bucket.windows where window.kind == .fiveHour || window.kind == .weekly {
                let duration: TimeInterval = window.kind == .weekly ? 7 * 86400 : 5 * 3600
                guard window.usedPercent >= 100, let reset = window.resetsAt, reset > snapshot.observedAt,
                      reset.timeIntervalSince(snapshot.observedAt) <= duration else { continue }
                if let index = denials.lastIndex(where: {
                    $0.quotaKey == bucket.quotaKey && $0.window == window.kind && $0.resetsAt == reset &&
                    $0.lastObservedAt == previousObservation &&
                    snapshot.observedAt.timeIntervalSince($0.lastObservedAt) <= Self.mergeGap
                }) {
                    denials[index].lastObservedAt = snapshot.observedAt
                } else {
                    denials.append(Denial(quotaKey: bucket.quotaKey, firstObservedAt: snapshot.observedAt,
                                          precedingConfirmedAt: precedingConfirmedAt, lastObservedAt: snapshot.observedAt, window: window.kind, resetsAt: reset))
                }
            }
        }
        denials = Array(denials.suffix(256))
    }

    private static func record(_ bucket: LimitBucket, into list: inout [Denial], snapshot: UsageSnapshot,
                               previousObservation: Date?, precedingConfirmedAt: Date?) {
        for window in bucket.windows where window.kind == .fiveHour || window.kind == .weekly {
            let duration: TimeInterval = window.kind == .weekly ? 7 * 86400 : 5 * 3600
            guard window.usedPercent >= 100, let reset = window.resetsAt, reset > snapshot.observedAt,
                  reset.timeIntervalSince(snapshot.observedAt) <= duration else { continue }
            if let index = list.lastIndex(where: {
                $0.quotaKey == bucket.quotaKey && $0.window == window.kind && $0.resetsAt == reset &&
                $0.lastObservedAt == previousObservation &&
                snapshot.observedAt.timeIntervalSince($0.lastObservedAt) <= Self.mergeGap
            }) {
                list[index].lastObservedAt = snapshot.observedAt
            } else {
                list.append(Denial(quotaKey: bucket.quotaKey, firstObservedAt: snapshot.observedAt,
                                   precedingConfirmedAt: precedingConfirmedAt, lastObservedAt: snapshot.observedAt,
                                   window: window.kind, resetsAt: reset))
            }
        }
        list = Array(list.suffix(256))
    }

    /// 已核對的官方延期：把定時嘗試的原證據保留到新的有效重設之後（帳戶切換或 null 許可仍會清除整個帳本）。
    public mutating func extendWitness(_ authorization: CodexSessionAuthorization, until: Date) {
        // 與延期規則一致：最多保留到「最晚合法延期＋送出期限」。
        let maximum = CodexTimedResumePolicy.witnessRetention(
            effectiveReset: authorization.resetsAt.addingTimeInterval(CodexTimedResumePolicy.maxDeferral))
        guard authorization.basis == .generalBucketTimed, authorization.accountHash == accountHash, until <= maximum else { return }
        for i in exhaustions.indices where exhaustions[i].quotaKey == authorization.quotaKey &&
            exhaustions[i].firstObservedAt == authorization.observedAt && exhaustions[i].window == authorization.window &&
            exhaustions[i].resetsAt == authorization.resetsAt {
            exhaustions[i].retainUntil = max(exhaustions[i].retainUntil ?? .distantPast, until)
        }
    }

    public func authorizes(_ authorization: CodexSessionAuthorization) -> Bool {
        guard authorization.accountHash == accountHash else { return false }
        let source = authorization.basis == .generalBucketTimed ? exhaustions : denials
        return source.contains { $0.quotaKey == authorization.quotaKey && $0.firstObservedAt == authorization.observedAt &&
            $0.window == authorization.window && $0.resetsAt == authorization.resetsAt }
    }

    public enum BindingGap: Equatable, Sendable {
        case noGeneralBucket, noExhaustionNearStop
        case noModel, noLiveAccount, noLivePermission, noStopTime, noAccountAtStop, accountChanged, noQuotaMapping, noDenialInBlockWindow, notPermittedByScope
    }

    /// 使用者選擇的一般額度定時嘗試：身分、時間與觀察邊界與 `bind` 完全相同，只把額度對應放寬為官方唯一的一般 `codex` 桶，
    /// 證據改用一般桶的用盡觀察（許可非 null）。模型專屬桶存在時不適用（走官方路徑）。
    func bindTimed(sessionID: String, turn: CodexTurnSummary, model: String?, snapshot: UsageSnapshot?,
                   now: Date, settings: CodexContinuationSettings) -> Result<CodexSessionAuthorization, BindingGapError> {
        bind(sessionID: sessionID, turn: turn, model: model, snapshot: snapshot, now: now, settings: settings, basis: .generalBucketTimed)
    }

    func bind(sessionID: String, turn: CodexTurnSummary, model: String?, snapshot: UsageSnapshot?,
              now: Date, settings: CodexContinuationSettings,
              basis: CodexSessionAuthorization.Basis = .modelBucket) -> Result<CodexSessionAuthorization, BindingGapError> {
        guard turn.isUsageLimitFailure, let stopped = turn.completedAt, stopped <= now,
              turn.startedAt.map({ $0 <= stopped }) ?? true else { return .failure(.init(.noStopTime)) }
        guard let model, !model.isEmpty else { return .failure(.init(.noModel)) }
        guard let snapshot, snapshot.provider == .codex, snapshot.source == .codexAppServer, !snapshot.isStale(now: now),
              let current = snapshot.accountID, !current.isEmpty else { return .failure(.init(.noLiveAccount)) }
        guard snapshot.usageAllowed != nil else { return .failure(.init(.noLivePermission)) }
        guard let accountHash, accountHash == AccountHash.of(current) else { return .failure(.init(.accountChanged)) }
        guard let accountSince, accountSince <= stopped else { return .failure(.init(.noAccountAtStop)) }
        let bucket: LimitBucket
        switch basis {
        case .modelBucket:
            guard let specific = snapshot.quotaBucket(forModel: model) else { return .failure(.init(.noQuotaMapping)) }
            bucket = specific
        case .generalBucketTimed:
            guard CodexTimedResumePolicy.modelBucketCount(snapshot, model: model) == 0,
                  let general = CodexTimedResumePolicy.generalBucket(snapshot) else {
                return .failure(.init(.noGeneralBucket))
            }
            bucket = general
        }
        let evidence = basis == .generalBucketTimed ? exhaustions : denials
        let candidates = evidence.filter {
            $0.quotaKey == bucket.quotaKey && $0.resetsAt > stopped &&
            $0.firstObservedAt <= stopped.addingTimeInterval(Self.nearStop) &&
            ($0.firstObservedAt <= stopped || $0.precedingConfirmedAt.map {
                $0 <= stopped && stopped.timeIntervalSince($0) <= Self.nearStop
            } == true) &&
            $0.lastObservedAt >= stopped.addingTimeInterval(-Self.nearStop) &&
            $0.firstObservedAt <= snapshot.observedAt && !$0.expired(at: now, grace: Self.resetGrace)
        }
        guard let denial = candidates.max(by: { $0.resetsAt < $1.resetsAt }) else {
            return .failure(.init(basis == .generalBucketTimed ? .noExhaustionNearStop : .noDenialInBlockWindow))
        }
        let authorization = CodexSessionAuthorization(basis: basis, sessionID: sessionID.lowercased(), turnID: turn.id,
                                                      accountHash: accountHash, model: model, quotaKey: bucket.quotaKey,
                                                      observedAt: denial.firstObservedAt, window: denial.window, resetsAt: denial.resetsAt)
        return settings.permits(authorization) ? .success(authorization) : .failure(.init(.notPermittedByScope))
    }

    public struct BindingGapError: Error, Equatable, Sendable {
        public let gap: BindingGap
        init(_ gap: BindingGap) { self.gap = gap }

        /// 顯示給使用者的原因與可操作的恢復方式。
        public var reason: String {
            switch gap {
            case .noGeneralBucket: L10n.token("找不到官方唯一的一般 codex 額度桶，不能定時嘗試")
            case .noExhaustionNearStop:
                L10n.token("Vibe Meter 未在中止前後觀察到同帳戶的一般額度用盡與重設時間（可能當時未執行），不能定時嘗試；可手動繼續")
            case .noModel: L10n.token("官方 rollout 沒有這個中止 turn 的模型，無法對應額度")
            case .noLiveAccount: L10n.token("目前沒有可用的 Codex 即時帳戶資料，暫不自動繼續")
            case .noLivePermission: L10n.token("Codex 未提供一般用量許可，暫不送出")
            case .noStopTime: L10n.token("Codex 未回報可信的額度中止時間，可手動繼續")
            case .noAccountAtStop: L10n.token("Vibe Meter 在中止後才確認目前的 Codex 帳戶，可手動繼續")
            case .accountChanged: L10n.token("目前 Codex 帳戶與中止時段觀察到的帳戶不同，不自動繼續")
            case .noQuotaMapping: L10n.token("官方額度資料無法唯一對應這個模型的額度桶")
            case .noDenialInBlockWindow:
                L10n.token("Vibe Meter 未在中止前後觀察到同帳戶的明確官方拒絕，可手動繼續")
            case .notPermittedByScope: L10n.token("不在手動限定的續作範圍內")
            }
        }
    }
}

/// 一個被中止的 Codex turn 能取得的官方證據。
///
/// AGENTS.md 要求以官方訊號確認「中止當下」的帳戶。目前 Codex 的官方資料沒有逐 turn 的帳戶：
/// - `session_meta.creator_account_id` 只代表建立 thread 的帳戶，不代表執行該 turn 的帳戶；
/// - Vibe Meter 自己在中止前後觀察到同一帳戶，也無法排除期間 A→B→A 切換。
/// 因此 `officialAccountAtBlock` 目前沒有任何來源會填入，`verified` 一律為 false（fail closed），計畫保持「待確認」。
/// 未來若官方提供同一 turn 的帳戶證據，填入此欄位即可，其餘條件（模型、目前帳戶一致）仍需全部成立。
public struct CodexBlockEvidence: Equatable, Sendable {
    /// rollout `turn_context`（同一 turn_id）記錄的模型。
    public var turnModel: String?
    /// rollout `session_meta.creator_account_id` 的雜湊（只作顯示參考，**不作為**中止時帳戶的證據）。
    public var creatorAccountHash: String?
    /// 官方記錄的「中止 turn 執行時」帳戶。目前沒有官方來源，固定為 nil。
    public var officialAccountAtBlock: String?
    /// 目前 app-server 回報的帳戶（原始值，只保存在本機計畫檔，用於恢復時比對）。
    public var liveAccountID: String?

    public init(turnModel: String?, creatorAccountHash: String?, officialAccountAtBlock: String? = nil, liveAccountID: String?) {
        self.turnModel = turnModel
        self.creatorAccountHash = creatorAccountHash
        self.officialAccountAtBlock = officialAccountAtBlock
        self.liveAccountID = liveAccountID
    }

    /// 所有證據一致時才算「已確認中止時的帳戶與模型」。
    public var verified: Bool { failureReason == nil }

    public var failureReason: String? {
        guard let official = officialAccountAtBlock, !official.isEmpty else {
            return L10n.token("官方紀錄沒有中止當下的帳戶（只有建立者與前後觀察，無法排除期間切換帳戶），不自動送出")
        }
        guard let turnModel, !turnModel.isEmpty else { return L10n.token("官方紀錄沒有這個 turn 的模型") }
        guard let live = liveAccountID, !live.isEmpty else { return L10n.token("沒有 Codex 即時帳戶資料") }
        guard official == live else { return L10n.token("目前登入的 Codex 帳戶與中止時不同") }
        return nil
    }

    public func context(anchorTurnID: String) -> CodexResumeContext {
        var context = CodexResumeContext(accountID: verified ? officialAccountAtBlock : nil, anchorTurnID: anchorTurnID,
                                         verifiedLimitFailure: true, modelAtBlock: turnModel, evidenceGap: failureReason)
        context.verifiedAccountAndModelAtBlock = verified
        return context
    }
}

extension CodexLocalStore {
    /// rollout 中 `turn_context` 記錄的該 turn 模型（官方寫入）。
    public func turnModel(sessionID: String, turnID: String, now: Date = Date()) -> String? {
        guard let url = rolloutFile(for: sessionID, now: now) else { return nil }
        return Self.turnModel(in: url, turnID: turnID)
    }

    static func turnModel(in url: URL, turnID: String) -> String? {
        struct Line: Decodable {
            struct Payload: Decodable { var turn_id: String?; var model: String? }
            var type: String
            var payload: Payload?
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var model: String?
        var buffer = Data()
        let needle = Data(turnID.utf8)
        func consume(_ lineData: Data) {
            guard lineData.range(of: needle) != nil, lineData.range(of: Data("\"turn_context\"".utf8)) != nil,
                  let line = try? JSONDecoder().decode(Line.self, from: lineData),
                  line.type == "turn_context", line.payload?.turn_id == turnID, let m = line.payload?.model, !m.isEmpty else { return }
            model = m  // 以最後一筆為準
        }
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                consume(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { consume(buffer) }
        return model
    }

    /// `session_meta.creator_account_id` 的雜湊（官方寫入；建立 thread 的帳戶）。
    public func creatorAccountHash(sessionID: String, now: Date = Date()) -> String? {
        struct Meta: Decodable {
            struct Payload: Decodable { var id: String; var creator_account_id: String? }
            var type: String
            var payload: Payload
        }
        guard let url = rolloutFile(for: sessionID, now: now), let first = FileTail.firstLine(of: url),
              let meta = try? JSONDecoder().decode(Meta.self, from: Data(first.utf8)), meta.type == "session_meta",
              meta.payload.id.lowercased() == sessionID.lowercased(), let creator = meta.payload.creator_account_id else { return nil }
        return AccountHash.of(creator)
    }
}
