import Foundation
import Testing
@testable import VibeMeterCore

@Suite struct AgentPreferencesTests {
    func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "vibemeter-test-prefs-\(UUID())")) }

    @Test func defaultsToAllAgentsAndPersistsChoice() throws {
        let d = try defaults()
        var prefs = AgentPreferences.load(from: d)
        #expect(prefs.ordered == [.claudeCode, .codex, .cursor, .antigravity])
        prefs.set(.cursor, enabled: false)
        prefs.set(.antigravity, enabled: false)
        prefs.save(to: d)
        let reloaded = AgentPreferences.load(from: d)
        #expect(reloaded.ordered == [.claudeCode, .codex])
        #expect(!reloaded.isEnabled(.cursor))
    }

    @Test func emptySelectionIsKeptAndUnknownValuesIgnored() throws {
        let d = try defaults()
        AgentPreferences(enabled: []).save(to: d)
        #expect(AgentPreferences.load(from: d).enabled.isEmpty)
        d.set(["codex", "future-agent"], forKey: AgentPreferences.key)
        #expect(AgentPreferences.load(from: d).ordered == [.codex])
    }

    @Test func collectorSkipsDisabledAgents() async {
        let collector = UsageCollector(codexStore: CodexLocalStore(codexHome: URL(fileURLWithPath: "/nonexistent")),
                                       claudeStore: ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir())),
                                       claudeInstaller: ClaudeSettingsInstaller(settingsURL: URL(fileURLWithPath: "/nonexistent/settings.json"),
                                                                                paths: VibeMeterPaths(root: TestSupport.tempDir())),
                                       codexBinary: nil)
        #expect(await collector.collect([.cursor]).map(\.provider) == [.cursor])
        #expect(await collector.collect([]).isEmpty)
        #expect(await collector.collect([.antigravity, .claudeCode]).map(\.provider) == [.claudeCode, .antigravity])
    }
}
