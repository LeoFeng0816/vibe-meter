import Foundation

/// Google Antigravity CLI's documented statusLine JSON. Only the product and quota fields are decoded.
public struct AntigravityBridgeStore: Sendable {
    public let paths: VibeMeterPaths
    public init(paths: VibeMeterPaths = .default) { self.paths = paths }

    private struct Input: Decodable {
        struct Bucket: Decodable {
            var remaining_fraction: Double?
            var reset_time: String?
            var disabled: Bool?
        }
        var product: String?
        var quota: [String: Bucket]?
    }

    @discardableResult
    public func recordStatusLine(_ data: Data, now: Date = Date()) throws -> UsageSnapshot? {
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.product == "antigravity", let quota = input.quota else { return nil }
        let windows = quota.keys.sorted().compactMap { id -> UsageWindow? in
            guard id.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil,
                  let bucket = quota[id], bucket.disabled != true,
                  let fraction = bucket.remaining_fraction, (0...1).contains(fraction) else { return nil }
            // Google's example names gemini-weekly explicitly. Unknown bucket IDs retain their identity.
            let kind: WindowKind = id == "gemini-weekly" ? .weekly : .named(id)
            return UsageWindow(kind: kind, usedPercent: (1 - fraction) * 100, resetsAt: bucket.reset_time.flatMap(ISO8601.parse))
        }
        guard !windows.isEmpty else { return nil }
        let current = latestSnapshot()
        guard current?.windows != windows, current.map({ $0.observedAt < now }) ?? true else { return current }
        let snapshot = UsageSnapshot(provider: .antigravity, windows: windows, observedAt: now, source: .antigravityStatusLine)
        try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(snapshot), to: paths.antigravitySnapshot)
        return snapshot
    }

    public func latestSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: paths.antigravitySnapshot),
              let snapshot = try? VibeMeterJSON.decoder.decode(UsageSnapshot.self, from: data),
              snapshot.provider == .antigravity, snapshot.source == .antigravityStatusLine else { return nil }
        return snapshot
    }

    public static func configurationSnippet(bridge: URL) -> String? {
        let settings: [String: Any] = ["statusLine": [
            "type": "command", "command": "\(ShellQuote.quote(bridge.path)) antigravity-statusline",
            "stack_with_default": true,
        ]]
        guard let json = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: json, as: UTF8.self)
    }
}
