import Foundation

/// 解釋一個 Codex 續作計畫為什麼能或不能自動送出，以及使用者可以怎麼做。
///
/// 自動送出只依官方資料授權（見 `CodexQuotaObservations.bind`）。官方 `TurnError` 只回報 `usageLimitExceeded`，
/// 沒有說明是哪個額度桶擋下；`normalModelSlug` 只是額度別名的模型描述。帳戶只有一般 `codex` 桶（slug 為 null）時，
/// 官方資料無法證明中止 turn 的模型屬於該桶，因此不自動送出；這裡只提供「看起來可以手動繼續」的提示與診斷。
public struct CodexAutomationDiagnosis: Equatable, Sendable {
    public enum Check: Equatable, Sendable { case ok, missing, unknown }

    public struct Item: Equatable, Sendable {
        public var label: String
        public var check: Check
        public var detail: String?
    }

    public var items: [Item]
    /// 目前帳戶與中止時觀察到的相同、後端明確允許一般用量、相關額度桶的對應週期存在且未滿、已過預計重設時間。
    /// 這只是提示使用者可以手動繼續，不是自動送出的授權，也不保證不會使用 credits 等付費用量。
    public var looksReadyForManualContinue: Bool

    /// 提示用的候選桶：模型專屬桶；沒有時只接受官方唯一的一般 `codex` 桶（slug 為 null）。
    /// 一般桶是否適用此模型無法由官方資料證實，因此只用於提示，不作自動送出的授權。
    static func candidateBucket(_ snapshot: UsageSnapshot, model: String) -> LimitBucket? {
        if let specific = snapshot.quotaBucket(forModel: model) { return specific }
        let general = (snapshot.buckets ?? []).filter {
            $0.limitID == UsageSnapshot.generalCodexLimitID && ($0.modelSlug == nil || $0.modelSlug?.isEmpty == true)
        }
        return general.count == 1 ? general[0] : nil
    }

    public static func diagnose(_ plan: ResumePlan, live: UsageSnapshot?, now: Date) -> CodexAutomationDiagnosis {
        guard plan.provider == .codex, let context = plan.codex else {
            return CodexAutomationDiagnosis(items: [], looksReadyForManualContinue: false)
        }
        var items: [Item] = []
        items.append(Item(label: L10n.token("官方 turn 回報額度中止（usageLimitExceeded）"),
                          check: context.verifiedLimitFailure ? .ok : .missing, detail: nil))
        items.append(Item(label: L10n.token("中止 turn 的模型（rollout turn_context）"),
                          check: context.modelAtBlock?.isEmpty == false ? .ok : .missing, detail: context.modelAtBlock))
        let usable = live.flatMap { $0.provider == .codex && $0.source == .codexAppServer && !$0.isStale(now: now) ? $0 : nil }
        let liveHash = usable?.accountID.flatMap { $0.isEmpty ? nil : AccountHash.of($0) }
        let accountCheck: Check
        if liveHash == nil { accountCheck = .missing }
        else if let atDetection = context.accountHashAtDetection { accountCheck = atDetection == liveHash ? .ok : .missing }
        else { accountCheck = .unknown }
        items.append(Item(label: L10n.token("目前 Codex 帳戶與偵測中止時相同（Vibe Meter 觀察）"), check: accountCheck,
                          detail: accountCheck == .missing && liveHash != nil ? L10n.token("帳戶已變更") : nil))
        let permission: Check = switch usable?.usageAllowed { case true?: .ok; case false?: .missing; case nil: .unknown }
        items.append(Item(label: L10n.token("後端允許一般用量（ordinaryUsageAllowed）"), check: permission,
                          detail: usable?.usageAllowed == nil ? L10n.token("未提供") : nil))
        let bucketCheck: Check
        var bucketDetail: String?
        if let model = context.modelAtBlock, let usable {
            if usable.quotaBucket(forModel: model) != nil { bucketCheck = .ok }
            else if (usable.buckets ?? []).allSatisfy({ $0.modelSlug == nil || $0.modelSlug?.isEmpty == true }) {
                bucketCheck = .missing
                bucketDetail = L10n.token("只有一般額度桶，官方未標示它適用哪個模型（normalModelSlug 為 null）")
            } else { bucketCheck = .missing }
        } else { bucketCheck = .unknown }
        items.append(Item(label: L10n.token("官方額度桶能對應到中止 turn 的模型"), check: bucketCheck, detail: bucketDetail))
        let authorized = context.sessionAuthorization != nil
        items.append(Item(label: L10n.token("中止時段同帳戶的明確官方拒絕觀察"), check: authorized ? .ok : .missing,
                          detail: authorized ? nil : context.evidenceGap.map { L10n.display($0) }))

        // 協助提示只看「與中止相關」的額度桶與週期：必須實際存在、未滿、有未來的重設時間；空資料或缺窗口不算恢復。
        var allClear = false
        if let snapshot = usable, let model = context.modelAtBlock, !model.isEmpty,
           let bucket = candidateBucket(snapshot, model: model) {
            let relevant = bucket.windows.filter { $0.kind == .fiveHour || $0.kind == .weekly }
            allClear = snapshot.usageAllowed == true && snapshot.limitReachedType == nil && snapshot.spendControlReached != true
                && bucket.limitReachedType == nil && bucket.spendControlReached != true
                && relevant.contains { $0.kind == plan.blockedWindow }
                && relevant.allSatisfy { window in
                    window.usedPercent < 100 && (window.resetsAt.map { $0 > snapshot.observedAt } ?? false)
                }
                && snapshot.observedAt >= (plan.expectedResetAt ?? plan.createdAt)
        }
        let ready = allClear && accountCheck == .ok && context.verifiedLimitFailure && context.anchorTurnID != nil
        return CodexAutomationDiagnosis(items: items, looksReadyForManualContinue: ready)
    }
}
