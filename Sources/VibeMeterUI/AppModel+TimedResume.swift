import Foundation
import VibeMeterCore

extension AppModel {
    /// 定時嘗試的有效到期時間（原重設或已核對的延期＋30 秒）。
    func timedEffectiveDue(_ plan: ResumePlan) -> Date? {
        guard let auth = plan.codex?.sessionAuthorization, auth.basis == .generalBucketTimed else { return nil }
        return CodexTimedResumePolicy.effectiveReset(auth, deferredTo: plan.codex?.timedDeferredResetAt)
            .addingTimeInterval(CodexTimedResumePolicy.buffer)
    }

    /// 一般額度定時嘗試：到期（有效重設＋30 秒）才標為到期並走正式送出流程；送出前會再以新查詢檢查。
    func runTimedResumes(codexPreflight: Preflight? = nil, codexDelivery: StartDelivery? = nil) async {
        // 被取消的 task 不得佔用引擎（之後的送出前檢查會因取消而失敗並退避）。
        guard !Task.isCancelled else { return }
        refreshDispatchPolicy()
        defer { scheduleTimedResumeCheck() }
        guard !dryRun, !backgroundStopped, !systemAsleep, agentPrefs.isEnabled(.codex), codexTimedResume,
              !timedRunInFlight else { return }
        timedRunInFlight = true
        defer { timedRunInFlight = false }
        let auth = authorization(for: .codex, automatic: true)
        for candidate in planBook.active where candidate.provider == .codex && candidate.state == .waiting {
            guard let plan = planBook.plan(candidate.id), plan.state == .waiting,
                  let timed = plan.codex?.sessionAuthorization, timed.basis == .generalBucketTimed else { continue }
            let now = timedClock()
            if let retryAfter = timedRetryAfter[plan.id], now < retryAfter { continue }
            switch CodexTimedResumePolicy.evaluate(timed, deferredTo: plan.codex?.timedDeferredResetAt, live: liveCodexSnapshot, now: now) {
            case .notDue:
                continue
            case .defer(let reset):
                applyTimedDeferral(plan.id, timed, to: reset)
            case .wait(let reason):
                planBook.setNote(plan.id, reason)
            case .stop(let reason):
                let effects = planBook.apply(.timedStopped(reason, now: Date()), to: plan.id)
                guard let current = planBook.plan(plan.id) else { continue }
                for effect in effects {
                    await handle(effect, for: current, authorization: auth, recoveryRevision: codexPollOutcomeRevision)
                }
            case .due:
                let permitted = autoContinue && codexContinuation.permits(timed) && codexObservations.authorizes(timed)
                // 計畫狀態一律用實際時間；可替換的時鐘只決定「是否到期」。
                let effects = planBook.apply(.timedDue(now: Date(), autoContinue: permitted), to: plan.id)
                guard let current = planBook.plan(plan.id) else { continue }
                for effect in effects {
                    await handle(effect, for: current, authorization: auth, recoveryRevision: codexPollOutcomeRevision,
                                 checkPreflight: codexPreflight, startDelivery: codexDelivery)
                }
            }
        }
        savePlans()
    }

    /// 已核對（同帳戶、許可非 null）的較晚官方重設：持久化到計畫，並延長原證據的保留時間到新重設之後。
    func applyTimedDeferral(_ id: UUID, _ timed: CodexSessionAuthorization, to reset: Date) {
        planBook.deferTimedResume(id, to: reset)
        codexObservations.extendWitness(timed, until: reset.addingTimeInterval(CodexTimedResumePolicy.lateLimit))
        if persists, let data = try? VibeMeterJSON.encoder.encode(codexObservations) {
            defaults.set(data, forKey: Keys.codexObservations)
        }
        timedRetryAfter[id] = nil
        savePlans()
    }

    /// 送出前以新查詢確認：到期後取得的同帳戶官方資料、許可非 null、無費用障礙、對應不歧義；最後讀模型與最新 turn。
    func timedPreflight(_ plan: ResumePlan, _ timed: CodexSessionAuthorization, client: CodexAppServerClient,
                        binary: URL, pollRevision: Int) async -> SessionPreflight {
        guard await ResumeExecutor.supportsQueueResume(binary) else {
            return .unknown(L10n.token("目前的 Codex CLI 不支援喚醒未載入的工作階段"))
        }
        let refreshed: UsageSnapshot
        do {
            let stamp = timedClock()
            refreshed = try await client.readRateLimits(now: { stamp })
        } catch {
            return .retry(L10n.token("送出前無法讀取 Codex 官方資料，稍後再試"))
        }
        observeCodexQuota(refreshed)
        switch CodexTimedResumePolicy.preflight(timed, deferredTo: plan.codex?.timedDeferredResetAt, snapshot: refreshed, now: timedClock()) {
        case .retry(let reason): return .retry(reason)
        case .stop(let reason): return .changed(reason)
        case .defer(let reset):
            pendingTimedDeferrals[plan.id] = reset
            codexObservations.extendWitness(timed, until: reset.addingTimeInterval(CodexTimedResumePolicy.lateLimit))
            return .retry(L10n.token("Codex 回報較晚的重設時間，改在新時間＋30 秒嘗試"))
        case .send(let note): timedDispatchNotes[plan.id] = note
        }
        let model: String?
        let latest: CodexTurnSummary?
        do {
            model = try await client.threadModel(threadID: plan.sessionID)
            latest = try await client.latestTurn(threadID: plan.sessionID)
        } catch {
            timedDispatchNotes[plan.id] = nil
            return .retry(L10n.token("送出前無法讀取 Codex 官方資料，稍後再試"))
        }
        if !acceptsConcurrentPollPublic(for: plan, after: pollRevision) {
            timedDispatchNotes[plan.id] = nil
            return .retry(L10n.token("較新的 Codex 查詢未確認可以送出，等待下次檢查"))
        }
        let result = LaunchDecision.codexPreflight(latest: latest, anchorTurnID: plan.codex?.anchorTurnID, requireLimitFailure: true,
                                                   expectedModel: timed.model, currentModel: .some(model))
        if result != .unchanged { timedDispatchNotes[plan.id] = nil }
        return result
    }

    /// 送出前檢查要求重試後：套用延期，並在 30 秒內不再重試同一計畫（避免反覆啟動 app-server）。
    func timedPreflightRetried(_ id: UUID) {
        if let reset = pendingTimedDeferrals.removeValue(forKey: id), let plan = planBook.plan(id),
           let timed = plan.codex?.sessionAuthorization, timed.basis == .generalBucketTimed {
            applyTimedDeferral(id, timed, to: reset)
        } else {
            timedRetryAfter[id] = timedClock().addingTimeInterval(CodexTimedResumePolicy.buffer)
        }
    }

    /// 只查官方額度再評估到期計畫（不做完整工作階段掃描），用於計時器、喚醒與網路恢復。
    var hasWaitingTimedPlans: Bool {
        planBook.active.contains { $0.state == .waiting && $0.codex?.isTimedAttempt == true }
    }

    func quickTimedCheck() async {
        // 沒有等待中的定時嘗試時不額外啟動 app-server（一般輪詢照常）。
        guard codexTimedResume, agentPrefs.isEnabled(.codex), !systemAsleep, hasWaitingTimedPlans else { return }
        startTimedCheck(poll: true)
        await timedCheckTask?.value
    }

    /// 實際檢查（可選先查額度，再評估到期計畫）。單一執行；執行中的要求只排一次後續。
    /// 這個 task 不會被 `scheduleTimedResumeCheck` 取消，避免自我取消後佔住引擎卻在送出前檢查失敗。
    func startTimedCheck(poll: Bool) {
        guard timedCheckTask == nil else {
            timedCheckPending = true
            return
        }
        timedCheckTask = Task { [weak self] in
            guard let self else { return }
            if poll { await self.requestCodexPoll(reason: .wake) }
            await self.runTimedResumes()
            self.timedCheckTask = nil
            if self.timedCheckPending {
                self.timedCheckPending = false
                self.scheduleTimedResumeCheck()
            }
        }
    }

    /// 依最近官方資料排程：到期或可延期的計畫立即處理；需要新資料者 30 秒後只查額度；其餘在下一個到期時間喚醒。
    /// 只取消仍在睡眠的計時器；計時器醒來時以自己的 ID 清掉 handle，再交給獨立的檢查 task。
    func scheduleTimedResumeCheck() {
        timedTimerTask?.cancel()
        timedTimerTask = nil
        timedTimerID = nil
        guard schedulesTimedTimer, persists, !backgroundStopped, !systemAsleep, codexTimedResume,
              agentPrefs.isEnabled(.codex) else { return }
        let now = timedClock()
        var next: Date?
        var runNow = false
        for plan in planBook.active where plan.state == .waiting {
            guard let timed = plan.codex?.sessionAuthorization, timed.basis == .generalBucketTimed else { continue }
            if let retryAfter = timedRetryAfter[plan.id], retryAfter > now {
                next = min(next ?? retryAfter, retryAfter)
                continue
            }
            switch CodexTimedResumePolicy.evaluate(timed, deferredTo: plan.codex?.timedDeferredResetAt, live: liveCodexSnapshot, now: now) {
            case .notDue(let at): next = min(next ?? at, at)
            case .due, .defer, .stop: runNow = true
            case .wait: next = min(next ?? now.addingTimeInterval(CodexTimedResumePolicy.buffer), now.addingTimeInterval(CodexTimedResumePolicy.buffer))
            }
        }
        if runNow {
            startTimedCheck(poll: false)
            return
        }
        guard let next else { return }
        let delay = max(0.05, next.timeIntervalSince(now) + 0.05)
        let id = UUID()
        timedTimerID = id
        timedTimerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.timedTimerID == id, !Task.isCancelled else { return }
            self.timedTimerTask = nil
            self.timedTimerID = nil
            self.startTimedCheck(poll: true)
        }
    }

    /// 顯示用：定時嘗試的有效時間（官方重設或已核對的延期＋30 秒）。
    public func codexTimedDue(for plan: ResumePlan) -> Date? { timedEffectiveDue(plan) }

    // MARK: 跨程序的工作階段層級記錄（檔案鎖，多個 App 程序與重啟後一致）

    var timedSessionStore: CodexTimedSessionStore {
        CodexTimedSessionStore(directory: paths.root.appendingPathComponent("Codex Timed Sessions"))
    }

    func timedSessionBlockedCheck() -> (String, Date) -> Bool {
        let store = timedSessionStore
        return { store.blocks(sessionID: $0, resetsAt: $1) }
    }


    func postTimedReadyNotice(_ plan: ResumePlan) {
        guard live, persists else { return }
        Task {
            _ = await notifier.post(id: "timed-ready-\(plan.id)", title: tr("已過 Codex 一般額度重設＋30 秒"),
                                    body: tr("「{0}」可確認後手動繼續。這只是一般額度的重設時間，不是官方確認原模型額度已恢復。",
                                             L10n.display(plan.sessionTitle))) { !self.backgroundStopped }
        }
    }
}
