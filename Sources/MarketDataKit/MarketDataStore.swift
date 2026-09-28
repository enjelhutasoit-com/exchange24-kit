//
// Copyright (c) 2026 Enjel Hutasoit
//

/// Single owner of live market state. Every event goes through
/// MergeEngine (correctness), then changed ticks go into a
/// ConflationBuffer (smoothness), and the UI receives batches on a fixed
/// interval instead of one update per message.
///
/// An actor, because state is written from the ingest path and read by
/// the flush loop concurrently; the actor serializes both without locks.
public actor MarketDataStore {
    private var state: [String: InstrumentTick] = [:]
    private var buffer = ConflationBuffer()
    
    /// True after a sequence gap was detected, until the next snapshot is
    /// applied. The owner (later: ConnectionManager wiring) reacts by
    /// requesting a fresh snapshot. The store only reports, never fetches.
    public private(set) var needsResync = false
    
    public init() {}
    
    /// Applies one event. Only events that actually changed state reach
    /// the conflation buffer; duplicates, stale ticks and gapped ticks
    /// never produce a UI update.
    @discardableResult
    public func ingest(_ event: MarketEvent) -> MergeOutcome {
        let result = MergeEngine.apply(event, to: state)
        state = result.state
        
        switch result.outcome {
        case .appliedSnapshot:
            if case .snapshot(let ticks) = event {
                for tick in ticks { buffer.insert(tick) }
            }
            needsResync = false
        case .appliedDelta:
            if case .delta(let tick) = event {
                buffer.insert(tick)
            }
        case .gapDetected:
            needsResync = true
        case .duplicateIgnored, .staleIgnored, .ignoredConnectionEvent:
            break
        }
        
        return result.outcome
    }
    
    /// Full current state, independent of what has been flushed to UI.
    public func currentState() -> [String: InstrumentTick] {
        state
    }

    /// How many ticks conflation has absorbed so far.
    public func conflatedUpdateCount() -> Int {
        buffer.conflatedCount
    }

    /// Drains pending ticks (one per symbol, sorted by symbol).
    public func flush() -> [InstrumentTick] {
        buffer.drain()
    }
    
    /// Emits a batch every `interval`, skipping intervals with nothing
    /// pending. The caller MUST keep the returned stream alive and
    /// consume it: dropping it deallocates the stream, which fires
    /// onTermination and cancels the flush loop.
    public func updates(every interval: Duration) -> AsyncStream<[InstrumentTick]> {
        AsyncStream { continuation in
            let task = Task { await self.runFlushLoop(every: interval, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runFlushLoop(
        every interval: Duration,
        into continuation: AsyncStream<[InstrumentTick]>.Continuation
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            let batch = flush()
            if !batch.isEmpty {
                continuation.yield(batch)
            }
        }
        continuation.finish()
    }
}
