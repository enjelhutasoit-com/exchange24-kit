//
// Copyright (c) 2026 Enjel Hutasoit
//

/// Holds only the LATEST tick per symbol between UI flushes. When a
/// symbol ticks 50 times before the next flush, the UI needs 1 update,
/// not 50 — the 49 in between are conflated away.
///
/// Arrival order is trusted: MergeEngine has already rejected duplicates,
/// stale ticks, and gaps before anything reaches this buffer, so insert()
/// simply overwrites. That also keeps a fresh snapshot able to replace a
/// pending tick without any sequence comparison getting in the way.
///
/// Value type on purpose: the owner (MarketDataStore, an actor) provides
/// the isolation, so this needs no locks and is trivial to test.
public struct ConflationBuffer: Sendable {
    private var pending: [String: InstrumentTick] = [:]
    /// Total ticks discarded because a newer tick for the same symbol
    /// arrived before the buffer was drained. Useful as an observability
    /// number: how much load is conflation absorbing?
    public private(set) var conflatedCount: Int = 0
    public var isEmpty: Bool { pending.isEmpty }
    public var pendingCount: Int { pending.count }
    
    public init() {}
    
    public mutating func insert(_ tick: InstrumentTick) {
        if pending[tick.symbol] != nil {
            conflatedCount += 1
        }
        pending[tick.symbol] = tick
    }
    
    /// Returns every pending tick (one per symbol) sorted by symbol so
    /// the output order is deterministic, then empties the buffer.
    public mutating func drain() -> [InstrumentTick] {
        let batch = pending.values.sorted { $0.symbol < $1.symbol }
        pending.removeAll(keepingCapacity: true)
        return batch
    }
}
