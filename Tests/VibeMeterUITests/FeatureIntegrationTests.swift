import CryptoKit
import Foundation
import Testing
import VibeMeterCore
@testable import VibeMeterUI

@MainActor
@Suite struct FeatureIntegrationTests {
    private func temporaryPaths() throws -> VibeMeterPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VibeMeterPaths(root: root)
    }

    private func release(for file: URL) throws -> ReleaseInfo {
        let digest = try UpdateChecker.sha256Hex(of: file)
        let bytes = try Data(contentsOf: file).count
        let base = "https://github.com/LeoFeng0816/vibe-meter/releases"
        return try UpdateChecker.parse(Data("""
        {"tag_name":"v0.1.2","draft":false,"prerelease":false,"html_url":"\(base)/tag/v0.1.2","assets":[
            {"name":"Vibe-Meter-0.1.2.dmg","browser_download_url":"\(base)/download/v0.1.2/Vibe-Meter-0.1.2.dmg","digest":"sha256:\(digest)","size":\(bytes)},
            {"name":"Vibe-Meter-0.1.2.dmg.sig","browser_download_url":"\(base)/download/v0.1.2/Vibe-Meter-0.1.2.dmg.sig"}
        ]}
        """.utf8))
    }

    @Test func realDryRunInitializationBlocksSideEffectsWithEnabledStoredPreferences() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let suite = "vibemeter-dry-run-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        KeepAwakeSettings(mode: .until(Date().addingTimeInterval(600)), preventDisplaySleep: true).save(to: defaults)
        UpdateSettings(autoCheck: true, autoDownload: true, autoInstall: true).save(to: defaults)
        let model = AppModel(dryRun: true, defaults: defaults, paths: paths)
        let file = paths.root.appendingPathComponent("fixture")
        try Data("dmg".utf8).write(to: file)
        let info = try release(for: file)
        var externalCalls = 0
        model.updateResult = .available(info)
        model.startAutomaticInstall = { _, _ in externalCalls += 1; return true }
        await model.checkForUpdates(automatic: true, fetch: { _ in
            externalCalls += 1
            throw URLError(.cannotConnectToHost)
        })
        await model.downloadUpdate(info, automatic: true, fetch: { _ in externalCalls += 1; return file })
        model.setKeepAwake(.whileAgentsWork)
        await model.updateKeepAwake(activityProbe: { externalCalls += 1; return .working(count: 1) })
        let notifier = Notifier(readStatus: { externalCalls += 1; return .authorized },
                                deliver: { _, _, _ in externalCalls += 1 })
        await model.deliverAlerts(using: notifier)
        #expect(model.keepAwakeTask == nil && model.updateTask == nil && model.claudeBridgeTask == nil)
        #expect(!model.isKeepingAwake && !model.updateSettings.autoCheck)
        #expect(model.keepAwake.mode == .off && model.collector.codexBinary == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("Updates").path))
        #expect(defaults.bool(forKey: UpdateSettings.autoCheckKey))
        #expect(externalCalls == 0)
    }

    @Test func bridgeColdStartAndAtomicChangesReflectImmediatelyAndManualRefreshReadsFile() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let suite = "vibemeter-bridge-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(dryRun: true, defaults: defaults, paths: paths,
                             claudeSettingsURL: paths.root.appendingPathComponent("settings.json"))
        model.refreshClaudeBridge()
        #expect(model.latestClaudeSnapshot == nil)

        let store = ClaudeBridgeStore(paths: paths)
        let watch = BridgeDirectoryWatcher(directory: paths.claudeDir) { model.refreshClaudeBridge() }
        defer { watch.stop() }
        func write(_ used: Int) throws {
            try store.recordStatusLine(Data("""
            {"session_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","cost":{"total_api_duration_ms":\(used)},"rate_limits":{"five_hour":{"used_percentage":\(used)}}}
            """.utf8))
        }
        func saw(_ used: Double) async -> Bool {
            for _ in 0..<80 {
                if model.latestClaudeSnapshot?.window(.fiveHour)?.usedPercent == used { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }

        try write(20)
        #expect(await saw(20))
        try write(35)
        #expect(await saw(35))
        watch.stop()
        try write(47)
        model.refreshClaudeBridge()
        #expect(model.latestClaudeSnapshot?.window(.fiveHour)?.usedPercent == 47)
    }

    @Test func deniedAndFailedNotificationsCanBeRetriedWithoutDuplicatingDelivery() async {
        let model = AppModel(preview: ())
        let now = Date()
        model.now = now
        let snapshot = UsageSnapshot(provider: .codex, windows: [
            UsageWindow(kind: .fiveHour, usedPercent: 95, resetsAt: now.addingTimeInterval(600)),
        ], observedAt: now, source: .codexAppServer)
        model.reports = [ProviderReport(provider: .codex, state: .available(snapshot))]
        let permission = FakeNotificationPermission()
        var sent = 0
        let pause = Pause<Bool>()
        let notifier = Notifier(readStatus: { permission.status }, deliver: { _, _, _ in
            sent += 1
            if sent == 1 { throw CocoaError(.featureUnsupported) }
            _ = await pause.suspend()
        })

        await model.deliverAlerts(using: notifier, now: now)
        #expect(model.firedAlerts.isEmpty && sent == 0)
        permission.status = .authorized
        await model.deliverAlerts(using: notifier, now: now)
        #expect(model.firedAlerts.isEmpty && sent == 1)

        let delivery = Task { await model.deliverAlerts(using: notifier, now: now) }
        guard await pause.waitUntilSuspended() else {
            Issue.record("notification was not delivered")
            pause.release(with: false)
            return
        }
        await model.deliverAlerts(using: notifier, now: now)
        #expect(sent == 2)
        pause.release(with: true)
        await delivery.value
        await model.deliverAlerts(using: notifier, now: now)
        #expect(sent == 2 && model.firedAlerts.count == 1)
    }

    @Test func keepAwakeTimerExpiresAndObsoleteAgentProbeCannotReacquire() async {
        let model = AppModel(preview: ())
        let now = Date()
        model.setKeepAwake(.until(now.addingTimeInterval(10)))
        #expect(model.isKeepingAwake)
        await model.updateKeepAwake(now: now.addingTimeInterval(10), activityProbe: { .idle })
        #expect(!model.isKeepingAwake && model.keepAwake.mode == .off)

        model.setKeepAwake(.whileAgentsWork)
        let pause = Pause<AgentActivity>()
        let probe = Task { await model.updateKeepAwake(activityProbe: { await pause.suspend() }) }
        guard await pause.waitUntilSuspended() else {
            Issue.record("activity probe was not entered")
            pause.release(with: .idle)
            return
        }
        model.setKeepAwake(.off)
        pause.release(with: .working(count: 1))
        await probe.value
        #expect(!model.isKeepingAwake && model.keepAwakeReason == .off)
    }

    @Test func corruptAndUnsignedDownloadsPreservePreviousFile() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(preview: (), fixturePaths: paths)
        let good = paths.root.appendingPathComponent("good")
        let bad = paths.root.appendingPathComponent("bad")
        try Data("good".utf8).write(to: good)
        try Data("oops".utf8).write(to: bad)
        let info = try release(for: good)
        model.updateResult = .available(info)
        let dest = paths.root.appendingPathComponent("Updates/0.1.2/Vibe-Meter-0.1.2.dmg")
        try paths.ensure(dest.deletingLastPathComponent())
        try Data("previous".utf8).write(to: dest)

        await model.downloadUpdate(info, automatic: false, fetch: { _ in bad })
        #expect(try Data(contentsOf: dest) == Data("previous".utf8))
        #expect(model.updateDownload == .failed(UpdateError.digestMismatch.message))

        let key = Curve25519.Signing.PrivateKey()
        let keys = [key.publicKey.rawRepresentation.base64EncodedString()]
        await model.downloadUpdate(info, automatic: false, fetch: { _ in good },
                                   fetchSignature: { _ in Data("invalid".utf8) }, publicKeys: keys)
        #expect(try Data(contentsOf: dest) == Data("previous".utf8))
        #expect(model.updateDownload == .failed(UpdateError.signatureInvalid.message))

        let digest = try UpdateChecker.sha256Hex(of: good)
        let signature = try key.signature(for: Data(digest.utf8)).base64EncodedString()
        await model.downloadUpdate(info, automatic: false, fetch: { _ in good },
                                   fetchSignature: { _ in Data(signature.utf8) }, publicKeys: keys)
        #expect(try Data(contentsOf: dest) == Data("good".utf8))
        #expect(model.updateDownload == .downloaded(file: dest, version: "0.1.2", sha256: digest,
                                                     digestVerified: true, publisherVerified: true))
    }

    @Test func downloadIsSingleFlightAndSettingsRevocationPreventsReplacement() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(preview: (), fixturePaths: paths)
        model.updateSettings.autoDownload = true
        let file = paths.root.appendingPathComponent("fixture")
        try Data("dmg".utf8).write(to: file)
        let info = try release(for: file)
        model.updateResult = .available(info)
        let pause = Pause<URL>()
        let download = Task {
            await model.downloadUpdate(info, automatic: true, fetch: { _ in await pause.suspend() })
        }
        guard await pause.waitUntilSuspended() else {
            Issue.record("download was not started")
            pause.release(with: file)
            return
        }
        await model.downloadUpdate(info, automatic: true, fetch: { _ in Issue.record("duplicate fetch"); return file })
        model.updateSettings.autoDownload = false
        model.updateSettings.autoDownload = true
        pause.release(with: file)
        await download.value
        #expect(model.updateDownload == .idle)
        #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("Updates").path))
    }
}

@MainActor
private final class FakeNotificationPermission {
    var status = NotificationStatus.denied
}
