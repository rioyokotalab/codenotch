import XCTest
@testable import Codenotch

/// The mapping, which is the part that can break when upstream moves. The
/// transport is the indicator's already-accepted `ssh` invocation and the timer
/// is a timer; neither earns a test that would have to be maintained through
/// every upstream merge.
final class LocalPaneMonitorTests: XCTestCase {
    private func reading(_ states: [String: String],
                         schema: Int = 1,
                         host: String = "local",
                         reason: String = "accepted") -> LocalPaneReading {
        LocalPaneReading(
            schema: schema,
            host: host,
            reason: reason,
            agents: states.mapValues { LocalPaneReading.Agent(state: $0) }
        )
    }

    private func full(_ states: [String: String], reason: String = "accepted")
        -> LocalPaneReading {
        reading(states, reason: reason)
    }

    func testDecodesTheReadersOwnPayload() throws {
        // Byte-for-byte what `harness local-agent-status --json` prints.
        let json = Data("""
        {"agents":{"claude":{"state":"active"},"codex1":{"state":"idle"},\
        "codex2":{"state":"active"}},"host":"local","reason":"accepted","schema":1}
        """.utf8)
        let decoded = try JSONDecoder().decode(LocalPaneReading.self, from: json)
        XCTAssertEqual(decoded.schema, 1)
        XCTAssertEqual(decoded.host, "local")
        XCTAssertEqual(decoded.reason, "accepted")
        XCTAssertEqual(decoded.agents["codex1"]?.state, "idle")
        XCTAssertEqual(decoded.agents["codex2"]?.state, "active")
        XCTAssertEqual(decoded.agents["claude"]?.state, "active")
    }

    func testActiveIsBusyAndIdleIsIdle() {
        let resolved = LocalPaneMonitor.states(from: full([
            "codex1": "active", "codex2": "idle", "claude": "active",
        ]))
        XCTAssertEqual(resolved[.codex1]?.state, .busy)
        XCTAssertEqual(resolved[.codex2]?.state, .idle)
        XCTAssertEqual(resolved[.claude]?.state, .busy)
        XCTAssertNil(resolved[.codex1]?.waitingFor)
        XCTAssertNil(resolved[.codex2]?.waitingFor)
    }

    func testDisconnectedAndErrorBecomeWaitingCarryingTheReason() {
        let resolved = LocalPaneMonitor.states(from: full([
            "codex1": "disconnected", "codex2": "error", "claude": "idle",
        ], reason: "session-unavailable"))
        XCTAssertEqual(resolved[.codex1]?.state, .waiting)
        XCTAssertEqual(resolved[.codex2]?.state, .waiting)
        XCTAssertEqual(resolved[.claude]?.state, .idle)
        XCTAssertEqual(resolved[.codex1]?.waitingFor,
                       "Pane missing — session-unavailable")
        XCTAssertEqual(resolved[.codex2]?.waitingFor,
                       "Pane in error — session-unavailable")
    }

    func testUnreachableLocalIsWaitingOnEveryPaneNotIdle() {
        let resolved = LocalPaneMonitor.states(from: nil)
        XCTAssertEqual(resolved.count, LocalPaneRole.allCases.count)
        for role in LocalPaneRole.allCases {
            XCTAssertEqual(resolved[role]?.state, .waiting, role.rawValue)
            XCTAssertEqual(resolved[role]?.waitingFor,
                           "Pane missing — local unreachable", role.rawValue)
        }
    }

    func testAPayloadOutsideTheContractIsAnErrorRatherThanAnAnswer() {
        let wrongSchema = reading(
            ["codex1": "idle", "codex2": "idle", "claude": "idle"], schema: 2
        )
        let wrongHost = reading(
            ["codex1": "idle", "codex2": "idle", "claude": "idle"], host: "office"
        )
        let missingRole = full(["codex1": "idle", "claude": "idle"])
        for (name, payload) in [("schema", wrongSchema), ("host", wrongHost),
                                ("role", missingRole)] {
            let resolved = LocalPaneMonitor.states(from: payload)
            for role in LocalPaneRole.allCases {
                XCTAssertEqual(resolved[role]?.state, .waiting, "\(name)/\(role.rawValue)")
                XCTAssertEqual(resolved[role]?.waitingFor,
                               "Pane in error — unexpected reader payload",
                               "\(name)/\(role.rawValue)")
            }
        }
    }

    func testAnUnknownWordIsNeverReportedAsIdle() {
        let resolved = LocalPaneMonitor.states(from: full([
            "codex1": "banana", "codex2": "idle", "claude": "idle",
        ]))
        XCTAssertEqual(resolved[.codex1]?.state, .waiting)
    }

    func testEachPaneLandsOnItsAccountsRingByDefault() {
        let defaults = UserDefaults.standard
        let keys = LocalPaneRole.allCases.map { "localPaneProviderFor.\($0.rawValue)" }
        for key in keys { defaults.removeObject(forKey: key) }
        XCTAssertEqual(LocalPaneRole.codex1.providerID, "codex-1")
        XCTAssertEqual(LocalPaneRole.codex2.providerID, "codex-2")
        XCTAssertEqual(LocalPaneRole.claude.providerID, "claude")
    }

    func testTheRingMappingCanBeRedirectedWithoutARebuild() {
        let key = "localPaneProviderFor.codex1"
        UserDefaults.standard.set("codex", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertEqual(LocalPaneRole.codex1.providerID, "codex")
        XCTAssertEqual(LocalPaneRole.codex2.providerID, "codex-2")
    }
}
