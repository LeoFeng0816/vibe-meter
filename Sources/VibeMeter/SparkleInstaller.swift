#if canImport(Sparkle)
import Foundation
import Sparkle
import VibeMeterCore

@MainActor
final class SparkleInstaller: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    private struct Request {
        let release: ReleaseInfo
        let authorized: () -> Bool
    }

    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    private var started = false
    private var request: Request?
    private var cancellation: (() -> Void)?
    private var receivedBytes: UInt64 = 0
    private let status: (String?) -> Void
    private let setCommitted: (Bool) -> Void

    init?(status: @escaping (String?) -> Void, setCommitted: @escaping (Bool) -> Void) {
        let bundle = Bundle.main
        let path = bundle.bundleURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        guard UpdateTrust.trustedPublicKeys.count == 1,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String == UpdateSource.signedAppcast.absoluteString,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              path.pathExtension == "app",
              (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              FileManager.default.isWritableFile(atPath: path.deletingLastPathComponent().path),
              (try? path.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == false else { return nil }
        self.status = status
        self.setCommitted = setCommitted
    }

    func start(_ release: ReleaseInfo, authorized: @escaping () -> Bool) -> Bool {
        guard request == nil, !updater.sessionInProgress, authorized(),
              let asset = release.installationArchive, let bytes = asset.size, bytes > 0,
              UpdateSource.matchesInstallation(release, archive: asset.url, displayVersion: release.version.description, bytes: UInt64(bytes))
        else { return false }
        if !started {
            do { try updater.start() } catch {
                status(L10n.token("簽章更新未安裝（Sparkle {0}）", [String((error as NSError).code)]))
                return false
            }
            // AppModel owns the schedule and requires fresh GitHub release metadata for each installation.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            started = true
        }
        request = Request(release: release, authorized: authorized)
        status(L10n.token("正在下載及驗證發布者簽章"))
        updater.checkForUpdates()
        return true
    }

    func cancel() {
        let cancel = cancellation
        cancellation = nil
        cancel?()
    }

    private func permits(_ item: SUAppcastItem) -> Bool {
        guard let request, request.authorized(), !item.isInformationOnlyUpdate, !item.isDeltaUpdate,
              item.installationType == "application", item.signingValidationStatus == .succeeded else { return false }
        return UpdateSource.matchesInstallation(request.release, archive: item.fileURL,
                                                displayVersion: item.displayVersionString, bytes: item.contentLength)
    }

    func feedURLString(for updater: SPUUpdater) -> String? { UpdateSource.signedAppcast.absoluteString }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard permits(item) else { throw CocoaError(.fileReadCorruptFile) }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with urlRequest: NSMutableURLRequest) {
        guard permits(item), let asset = request?.release.installationArchive else { urlRequest.url = nil; return }
        // The bundled downloader consumes and removes these fields before making a network request.
        urlRequest.setValue(asset.sha256, forHTTPHeaderField: "X-Vibe-Meter-Archive-SHA256")
        urlRequest.setValue(asset.size.map(String.init), forHTTPHeaderField: "X-Vibe-Meter-Archive-Size")
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Sparkle 2.10.0 calls this immediately before dispatching stage 2 to its installer.
        guard request?.authorized() == true else { return false }
        setCommitted(true)
        status(L10n.token("已驗證更新，正在安裝及重新啟動"))
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { report(error) }
        setCommitted(false)
        request = nil
        cancellation = nil
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        reply(permits(appcastItem) ? .install : .skip)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report(error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        report(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        receivedBytes = 0
        guard request?.authorized() == true else { cancellation(); return }
        self.cancellation = cancellation
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if let size = request?.release.installationArchive?.size, expectedContentLength > UInt64(size) { cancel() }
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = receivedBytes.addingReportingOverflow(length)
        guard !overflow, let size = request?.release.installationArchive?.size, total <= UInt64(size) else { cancel(); return }
        receivedBytes = total
    }
    func showDownloadDidStartExtractingUpdate() { cancellation = nil }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard request?.authorized() == true else { reply(.skip); return }
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { cancellation = nil }

    private func report(_ error: Error) {
        status(L10n.token("簽章更新未安裝（Sparkle {0}）", [String((error as NSError).code)]))
    }
}
#endif
