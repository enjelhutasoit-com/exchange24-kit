//
// Copyright (c) 2026 Enjel Hutasoit
//

/// Result of feeding one event into MergeEngine: the new state, plus
/// what actually happened. Callers (ConnectionManager, tests, UI) decide
/// what to do with each outcome — MergeEngine itself never does I/O,
/// never sleeps, never talks to a socket. Pure function, in and out.
public enum MergeOutcome: Sendable, Equatable {
    case appliedSnapshot(count: Int)
    case appliedDelta(symbol: String)
    case duplicateIgnored(symbol: String, sequence: UInt64)
    case staleIgnored(symbol: String, sequence: UInt64)
    case gapDetected(symbol: String, expected: UInt64, got: UInt64)
    case ignoredConnectionEvent
}

public struct MergeResult: Sendable, Equatable {
    public let state: [String: InstrumentTick]
    public let outcome: MergeOutcome
}

/// Merges snapshot/delta MarketEvents into a per-symbol state dictionary,
/// using each instrument's sequence number to tell correct delivery apart
/// from duplicates, stale/out-of-order messages, and gaps.
///
/// This is intentionally a pure, stateless function over an explicit
/// state dictionary — not an actor holding its own state — so every
/// case (gap, duplicate, reorder) is a plain input/output pair a test
/// can assert on directly, with zero timing or concurrency involved.
public enum MergeEngine {
    /// Applies one event to `state` and returns the resulting state plus
    /// what happened. Never mutates `state` in place — always returns a
    /// new dictionary, so callers can compare before/after directly.
    public static func apply(_ event: MarketEvent, to state: [String: InstrumentTick]) -> MergeResult {
        switch event {
        case .snapshot(let ticks):
            return applySnapshot(ticks, to: state)
        case .delta(let tick):
            return applyDelta(tick, to: state)
        case .connectionStateChanged:
            // Not this engine's concern — ConnectionManager's separate
            // connectionStates() stream already carries this.
            return MergeResult(state: state, outcome: .ignoredConnectionEvent)
        }
    }
    
    private static func applySnapshot(_ ticks: [InstrumentTick], to state: [String: InstrumentTick]) -> MergeResult {
        var newState = state
        for tick in ticks {
            newState[tick.symbol] = tick
        }
        return MergeResult(state: newState, outcome: .appliedSnapshot(count: ticks.count))
    }
    
    private static func applyDelta(_ tick: InstrumentTick, to state: [String: InstrumentTick]) -> MergeResult {
        guard let existing = state[tick.symbol] else {
            var newState = state
            newState[tick.symbol] = tick
            return MergeResult(state: newState, outcome: .appliedDelta(symbol: tick.symbol))
        }
        
        if tick.sequence == existing.sequence + 1 {
            var newState = state
            newState[tick.symbol] = tick
            return MergeResult(state: newState, outcome: .appliedDelta(symbol: tick.symbol))
        }
        
        if tick.sequence == existing.sequence {
            return MergeResult(state: state, outcome: .duplicateIgnored(symbol: tick.symbol, sequence: tick.sequence))
        }
        
        if tick.sequence < existing.sequence {
            return MergeResult(state: state, outcome: .staleIgnored(symbol: tick.symbol, sequence: tick.sequence))
        }
        
        return MergeResult(
            state: state,
            outcome: .gapDetected(symbol: tick.symbol, expected: existing.sequence + 1, got: tick.sequence)
        )
    }
}
