import Foundation

/// The reader's answer, verbatim. `harness local-agent-status --json` on the
/// Local host emits exactly this and nothing else.
struct LocalPaneReading: Decodable, Equatable {
    struct Agent: Decodable, Equatable {
        let state: String
    }

    let schema: Int
    let host: String
    let reason: String
    let agents: [String: Agent]
}

/// One pane on Local, and the ring its rows belong on.
enum LocalPaneRole: String, CaseIterable {
    case codex1
    case codex2
    case claude

    /// The ring this pane's session joins.
    ///
    /// A pane is a login of one account, and a ring is one account's limits, so
    /// the pairing is by account rather than by machine: Local's `codex1` pane
    /// and this Mac's `codex-1` ring are the same ChatGPT account seen from two
    /// hosts. `codex-1` is discoverable only because `~/.codex-1` links to
    /// `~/.codex1` — see Har-556 — so the mapping is overridable without a
    /// rebuild for the day that naming changes.
    var providerID: String {
        let override = UserDefaults.standard.string(
            forKey: "localPaneProviderFor.\(rawValue)"
        )
        if let override, !override.isEmpty { return override }
        switch self {
        case .codex1: return "codex-1"
        case .codex2: return "codex-2"
        case .claude: return "claude"
        }
    }

    /// Named for the pane, not the tool: the point of the row is that this work
    /// is happening somewhere other than here.
    var label: String {
        switch self {
        case .codex1: return "Codex1 on Local"
        case .codex2: return "Codex2 on Local"
        case .claude: return "Claude on Local"
        }
    }
}

/// What Local's three agent panes are doing, shown on the rings of the accounts
/// they belong to.
///
/// Those panes run on the Linux host behind the `local` SSH alias, not on this
/// Mac, so none of the file-watching monitors can see them. The reader on that
/// host answers with one of four words per pane — `active`, `idle`,
/// `disconnected`, `error` — and a `reason`. Pane text, prompts, task names and
/// transcripts never cross, and this adds no traffic beyond that one call.
///
/// Rows arrive as *supplemental* sessions rather than through
/// `AgentActivityMonitor`, because one of those belongs to exactly one provider
/// and these three rows belong to three.
///
/// `disconnected` and `error` are reported as `waiting` carrying their reason.
/// Both describe the transport rather than the conversation, and
/// `AgentSession.State` has no case for "I cannot reach the host"; adding one
/// would reach into every switch in the display code for no gain, because
/// `waiting` already means the one thing that matters here — this needs you.
@MainActor
final class LocalPaneMonitor {
    /// Set false with
    /// `defaults write com.vinz.codenotch localPaneMonitorEnabled -bool false`
    /// on a Mac that has no business reaching Local.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "localPaneMonitorEnabled") as? Bool ?? true
    }

    private let onActivity: (String, [AgentSession]) -> Void
    private let interval: TimeInterval
    private let query: () -> LocalPaneReading?
    private var timer: Timer?
    private var fetching = false
    /// When each pane entered the state it is in. Kept so a row's age is the age
    /// of the *state*, not the age of the last poll.
    private var entered: [LocalPaneRole: (state: AgentSession.State, since: Date)] = [:]

    init(interval: TimeInterval = 5,
         query: @escaping () -> LocalPaneReading? = LocalPaneMonitor.queryLocal,
         onActivity: @escaping (String, [AgentSession]) -> Void) {
        self.interval = interval
        self.query = query
        self.onActivity = onActivity
    }

    func start() {
        guard Self.isEnabled, timer == nil else { return }
        // Built rather than scheduled, then added in `.common`: a scheduled
        // timer lands in `.default` only, and this has to keep firing while the
        // tooltip that shows these very rows is holding a tracking run loop.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for role in LocalPaneRole.allCases { onActivity(role.providerID, []) }
        entered.removeAll()
    }

    private func refresh() {
        guard !fetching else { return }
        fetching = true
        let query = self.query
        Task.detached(priority: .utility) {
            let reading = query()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching = false
                self.apply(reading)
            }
        }
    }

    private func apply(_ reading: LocalPaneReading?) {
        let resolved = Self.states(from: reading)
        Log.sessions.debug("local panes: \(Self.summary(resolved), privacy: .public)")
        let now = Date()
        for role in LocalPaneRole.allCases {
            guard let outcome = resolved[role] else { continue }
            let since: Date
            if let previous = entered[role], previous.state == outcome.state {
                since = previous.since
            } else {
                since = now
                entered[role] = (outcome.state, now)
            }
            let session = AgentSession(
                id: "local-pane-\(role.rawValue)",
                name: role.label,
                detail: outcome.detail,
                state: outcome.state,
                waitingFor: outcome.waitingFor,
                since: since
            )
            onActivity(role.providerID, [session])
        }
    }

    // MARK: - Mapping

    /// Isolation note: the mapping below is `nonisolated` on purpose. It reads
    /// no instance state, and forcing a caller onto the main actor to check a
    /// lookup table would only make the tests test the hop.
    struct Outcome: Equatable {
        let state: AgentSession.State
        let detail: String
        let waitingFor: String?
    }

    /// The whole mapping, free of SSH and of the clock, so it can be tested.
    ///
    /// A nil reading is this Mac's own failure to reach Local, which the retired
    /// indicator also reported as `disconnected` for every pane. A reading whose
    /// schema, host or role set is not the one expected is an `error`: answering
    /// from a payload that is not the contract would be worse than saying so.
    nonisolated static func states(from reading: LocalPaneReading?)
        -> [LocalPaneRole: Outcome] {
        guard let reading else {
            return outcomes(word: "disconnected", reason: "local unreachable")
        }
        guard reading.schema == 1, reading.host == "local",
              LocalPaneRole.allCases.allSatisfy({ reading.agents[$0.rawValue] != nil })
        else {
            return outcomes(word: "error", reason: "unexpected reader payload")
        }
        var resolved: [LocalPaneRole: Outcome] = [:]
        for role in LocalPaneRole.allCases {
            resolved[role] = outcome(
                word: reading.agents[role.rawValue]!.state,
                reason: reading.reason
            )
        }
        return resolved
    }

    nonisolated private static func outcomes(word: String, reason: String)
        -> [LocalPaneRole: Outcome] {
        let shared = outcome(word: word, reason: reason)
        return Dictionary(uniqueKeysWithValues: LocalPaneRole.allCases.map { ($0, shared) })
    }

    nonisolated private static func outcome(word: String, reason: String) -> Outcome {
        switch word {
        case "active":
            return Outcome(state: .busy, detail: "Local", waitingFor: nil)
        case "idle":
            return Outcome(state: .idle, detail: "Local", waitingFor: nil)
        case "disconnected":
            return Outcome(state: .waiting, detail: "Local",
                           waitingFor: "Pane missing — \(reason)")
        default:
            // Every other word, the reader's `error` included: an unknown state
            // is not an idle one, and saying "idle" about a pane nobody has
            // looked at is the one answer that could cost work.
            return Outcome(state: .waiting, detail: "Local",
                           waitingFor: "Pane in error — \(reason)")
        }
    }

    nonisolated private static func summary(_ resolved: [LocalPaneRole: Outcome]) -> String {
        LocalPaneRole.allCases.compactMap { role in
            resolved[role].map { "\(role.rawValue)=\($0.state)" }
        }.joined(separator: " ")
    }

    // MARK: - Transport

    /// One `ssh` call, batch mode, no forwarding, no reused control socket, and
    /// the owner's own Ed25519 identity with its passphrase taken from the login
    /// keychain so this does not need an interactive terminal's forwarded agent.
    /// Lifted from the indicator this replaces, whose configuration was already
    /// accepted.
    nonisolated static func queryLocal() -> LocalPaneReading? {
        let identity = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/id_ed25519").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "LogLevel=ERROR",
            "-o", "UseKeychain=yes",
            "-o", "IdentitiesOnly=yes",
            "-i", identity,
            "local", "harness", "local-agent-status", "--json",
        ]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + 6) == .timedOut {
            process.terminate()
            return nil
        }
        guard let data = try? output.fileHandleForReading.readToEnd(),
              data.count <= 16 * 1024
        else { return nil }
        return try? JSONDecoder().decode(LocalPaneReading.self, from: data)
    }
}
