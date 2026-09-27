import SwiftUI

/// What the activity cell shows: the state of every live session, reduced to
/// the one thing worth knowing at a glance.
struct ActivitySummary: Equatable {
    enum State: Equatable {
        case working
        case waiting
        case success
        case idle
    }

    let state: State
    let sessions: [AgentSession]
    /// Requests lined up behind the one running — a local runtime's queue.
    /// Zero for every cloud agent, which has no such line to report.
    let queued: Int
    /// What the tooltip's header says while this is going on, where a local
    /// runtime names the phase. Nil leaves the header to the session's name.
    let note: String?

    /// Nil when nothing is running — the cell disappears rather than sitting
    /// there saying nothing.
    init?(sessions: [AgentSession], queued: Int = 0, note: String? = nil) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
        self.queued = max(0, queued)
        self.note = note
        // Anything blocked on you outranks anything merely busy: it is the only
        // state where the notch is asking for something.
        if sessions.contains(where: { $0.state == .waiting }) {
            state = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            state = .working
        } else if sessions.contains(where: { $0.state == .success }) {
            state = .success
        } else {
            state = .idle
        }
    }

    /// One short word, for the tooltip.
    var label: String {
        switch state {
        case .working: return L10n.t("working")
        case .waiting: return L10n.t("waiting")
        case .success: return L10n.t("complete")
        case .idle:    return L10n.t("idle")
        }
    }

    /// Green working, yellow idle, red blocked — a traffic light, by owner
    /// request (2026-09-27), because these rings carry the Local agent panes and
    /// the state of those panes is read at a glance from across the room.
    ///
    /// Upstream drew working in neutral white on purpose: the indicator sits
    /// inside a ring whose own colour is the usage scale, built from these very
    /// three, so a coloured indicator can be misread as part of that scale. That
    /// is a real cost and it is accepted here rather than denied — the reading it
    /// buys is the one this fork exists for. Reverting is this function alone.
    var color: Color {
        switch state {
        case .working: return Palette.ample
        case .waiting: return Palette.critical
        case .success: return Palette.ample
        case .idle:    return Palette.watch
        }
    }

    var waitingSessions: [AgentSession] { sessions.filter { $0.state == .waiting } }
}
