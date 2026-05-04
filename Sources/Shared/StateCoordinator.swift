import Foundation

/// Thread-safe actor owning mutable state and immutable history.
/// Holds the single authoritative copy of TilrState and an append-only history of snapshots.
public actor StateCoordinator: Sendable {
    private var state: TilrState
    private var history: [TilrStateSnapshot] = []

    public init(initialState: TilrState, initialSnapshot: TilrStateSnapshot) {
        self.state = initialState
        self.history = [initialSnapshot]
    }

    /// Get the current state as an immutable snapshot.
    public func snapshot() -> TilrStateSnapshot {
        // Return the most recent snapshot from history.
        guard let latest = history.last else {
            // Fallback (should not happen if initialized correctly).
            return TilrStateSnapshot(command: .custom("fallback"), state: state)
        }
        return latest
    }

    /// Get recent snapshots from history (most recent first).
    public func history(limit: Int = 10) -> [TilrStateSnapshot] {
        Array(history.suffix(limit).reversed())
    }

    /// Record phase: evolve state from execution outcomes, create snapshot, append to history.
    ///
    /// Called after the Execute phase to reflect what actually happened.
    /// Creates a new immutable snapshot and appends to history.
    public func record(plan: String? = nil, outcomes: [ActionOutcome]? = nil, command: Command? = nil) -> TilrStateSnapshot {
        let snapshot = TilrStateSnapshot(
            id: UUID(),
            timestamp: Date(),
            command: command,
            state: state,
            plan: plan,
            outcomes: outcomes
        )
        history.append(snapshot)
        return snapshot
    }

    /// Update mutable state. Called internally by pipeline phases.
    /// Returns the updated state for caller convenience (but authoritative copy is held here).
    public func updateState(_ updates: (inout TilrState) -> Void) -> TilrState {
        updates(&state)
        return state
    }

    /// Convenience: atomically update state and record a snapshot.
    public func updateAndRecord(
        plan: String? = nil,
        outcomes: [ActionOutcome]? = nil,
        command: Command? = nil,
        updates: (inout TilrState) -> Void
    ) -> TilrStateSnapshot {
        updates(&state)
        return record(plan: plan, outcomes: outcomes, command: command)
    }
}
