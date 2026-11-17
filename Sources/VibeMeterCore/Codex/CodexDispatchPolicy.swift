import Darwin
import Foundation

/// Shared by all current Vibe Meter processes using the same data directory.
public struct CodexDispatchPolicy: Codable, Equatable, Sendable {
    public var autoContinue: Bool
    public var codexEnabled: Bool
    public var timedResume: Bool
    public var continuation: CodexContinuationSettings
    public private(set) var revision = UUID()
    public private(set) var agentRevision = UUID()
    private var version = 1
    private var cancellations: [String: Date] = [:]

    public init(autoContinue: Bool, codexEnabled: Bool, timedResume: Bool, continuation: CodexContinuationSettings) {
        self.autoContinue = autoContinue
        self.codexEnabled = codexEnabled
        self.timedResume = timedResume
        self.continuation = continuation
    }

    private static func keys(for plan: ResumePlan) -> [String] {
        let planKey = "plan:" + plan.id.uuidString
        guard let anchor = plan.codex?.anchorTurnID else { return [planKey] }
        return [planKey, "anchor:" + AccountHash.of("\(plan.sessionID.lowercased())|\(anchor)")]
    }

    public func cancelledAt(_ plan: ResumePlan) -> Date? {
        Self.keys(for: plan).compactMap { cancellations[$0] }.min()
    }

    public mutating func cancel(_ plan: ResumePlan, at now: Date) {
        for key in Self.keys(for: plan) where cancellations[key] == nil {
            cancellations[key] = now
        }
    }

    public func permits(_ authorization: CodexSessionAuthorization) -> Bool {
        autoContinue && codexEnabled && continuation.permits(authorization) &&
            (authorization.basis != .generalBucketTimed || timedResume)
    }

    mutating func rotateRevisions(from before: Self) {
        if codexEnabled != before.codexEnabled { agentRevision = UUID() }
        if autoContinue != before.autoContinue || codexEnabled != before.codexEnabled ||
            timedResume != before.timedResume || continuation != before.continuation {
            revision = UUID()
        }
    }

    var isRecognized: Bool { version == 1 }
}

public struct CodexDispatchPolicyStore: Sendable {
    public enum CancellationError: Error { case alreadySubmitted }

    public let directory: URL
    public var claims: CodexDispatchClaims { CodexDispatchClaims(directory: directory.appendingPathComponent("Codex Dispatch Claims")) }
    private var policyFile: URL { directory.appendingPathComponent("codex-dispatch-policy.json") }
    private var initializedFile: URL { directory.appendingPathComponent(".codex-dispatch-policy-initialized") }
    private var lockFile: URL { directory.appendingPathComponent(".codex-dispatch-policy.lock") }

    public init(directory: URL) { self.directory = directory }

    /// Only a missing file permits migration. A damaged file never supplies defaults or authorizes a send.
    public func initialize(_ fallback: CodexDispatchPolicy) throws -> CodexDispatchPolicy {
        try BridgeLock.withLock(at: lockFile) {
            do {
                let policy = try read()
                try markInitialized()
                return policy
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A disappeared policy after migration could have contained revoked settings or cancelled anchors.
                var info = stat()
                guard lstat(initializedFile.path, &info) != 0, errno == ENOENT else { throw error }
                try markInitialized()
                try write(fallback)
                return fallback
            }
        }
    }

    private func markInitialized() throws {
        let fd = open(initializedFile.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd >= 0 {
            close(fd)
            return
        }
        if errno == EEXIST { return }
        throw CocoaError(.fileWriteUnknown)
    }

    public func update(_ change: (inout CodexDispatchPolicy) throws -> Void) throws -> CodexDispatchPolicy {
        try BridgeLock.withLock(at: lockFile) {
            let previous = try read()
            var next = previous
            try change(&next)
            next.rotateRevisions(from: previous)
            if next != previous { try write(next) }
            return next
        }
    }

    public func cancel(_ plan: ResumePlan, at now: Date) throws -> CodexDispatchPolicy {
        try update { policy in
            if let anchor = plan.codex?.anchorTurnID, try claims.contains(sessionID: plan.sessionID, turnID: anchor) {
                throw CancellationError.alreadySubmitted
            }
            policy.cancel(plan, at: now)
        }
    }

    /// Keep the lock until the CLI has synchronously started. Await its result outside the lock.
    public func withPolicy<T>(_ body: (CodexDispatchPolicy) throws -> T) throws -> T {
        try BridgeLock.withLock(at: lockFile) { try body(read()) }
    }

    private func read() throws -> CodexDispatchPolicy {
        let data = try Data(contentsOf: policyFile, options: .uncached)
        let policy = try VibeMeterJSON.decoder.decode(CodexDispatchPolicy.self, from: data)
        guard policy.isRecognized else { throw CocoaError(.fileReadCorruptFile) }
        return policy
    }

    private func write(_ policy: CodexDispatchPolicy) throws {
        let staged = directory.appendingPathComponent(".dispatch-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try VibeMeterJSON.writeAtomically(VibeMeterJSON.encoder.encode(policy), to: staged)
        guard rename(staged.path, policyFile.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
