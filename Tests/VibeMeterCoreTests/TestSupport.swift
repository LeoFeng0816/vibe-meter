import Foundation
@testable import VibeMeterCore

enum TestSupport {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let sessionA = "0a0a0a0a-1111-4222-8333-944455556666"
    static let sessionB = "0b9f8a6e-1111-4222-8333-944455556666"

    /// 與實際 Codex rollout `token_count` 事件同形狀的資料行。
    static func tokenCountLine(timestamp: String, primaryUsed: Double, secondaryUsed: Double,
                               primaryReset: Int = 1_794_200_383, secondaryReset: Int = 1_794_493_334,
                               reached: String? = nil) -> String {
        let reachedJSON = reached.map { "\"\($0)\"" } ?? "null"
        return """
        {"timestamp":"\(timestamp)","ordinal":893,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\(primaryUsed),"window_minutes":300,"resets_at":\(primaryReset)},"secondary":{"used_percent":\(secondaryUsed),"window_minutes":10080,"resets_at":\(secondaryReset)},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":\(reachedJSON)}}}
        """
    }

    static func sessionMetaLine(id: String, cwd: String) -> String {
        """
        {"timestamp":"2026-11-09T03:42:52.000Z","type":"session_meta","payload":{"session_id":"\(id)","id":"\(id)","timestamp":"2026-11-09T03:42:52.000Z","cwd":"\(cwd)","source":"cli","originator":"codex_cli_rs","cli_version":"0.167.0","base_instructions":{"text":"long..."}}}
        """
    }

    static func snapshot(_ provider: ProviderID = .codex, observedAt: Date, source: DataSource = .codexAppServer,
                         windows: [UsageWindow], reached: String? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: provider, windows: windows, observedAt: observedAt, source: source, limitReachedType: reached)
    }
}
