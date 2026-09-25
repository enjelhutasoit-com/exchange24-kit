//
// Copyright (c) 2026 Enjel Hutasoit
//

import MarketDataKit

/// Deterministic fault injection applied to a canonical event sequence.
/// Randomized injection (seeded RNG) makes test failures unreproducible;
/// indexing by position instead makes every failure re-runnable exactly.
public struct FaultScript: Sendable {
    public var dropIndices: Set<Int>
    public var duplicateIndices: Set<Int>
    public var reorderPairs: [(Int, Int)]
    
    public static let none = FaultScript()
    
    public init(
        dropIndices: Set<Int> = [],
        duplicateIndices: Set<Int> = [],
        reorderPairs: [(Int, Int)] = []
    ) {
        self.dropIndices = dropIndices
        self.duplicateIndices = duplicateIndices
        self.reorderPairs = reorderPairs
    }
}

/// A fake "server" that replays a canonical MarketEvent sequence,
/// optionally corrupted by a FaultScript. Drives MarketDataKit's future
/// merge/reconnect logic in tests and the demo app without a real socket.
public struct FakeMarketEventSource: Sendable {
    private let canonicalEvents: [MarketEvent]
    private let faults: FaultScript
    
    public init(
        canonicalEvents: [MarketEvent],
        faults: FaultScript = .none
    ) {
        self.canonicalEvents = canonicalEvents
        self.faults = faults
    }
    
    /// Eager, synchronous corrupted sequence — for merge-engine unit
    /// tests that don't need real async timing.
    public func corruptedSequence() -> [MarketEvent] {
        var indexed = Array(canonicalEvents.enumerated())
        
        for (from, to) in faults.reorderPairs
        where indexed.indices.contains(from) && indexed.indices.contains(to) {
            indexed.swapAt(from, to)
        }
        
        return indexed
            .filter { !faults.dropIndices.contains($0.offset) }
            .flatMap { faults.duplicateIndices.contains($0.offset) ? [$0.element, $0.element] : [$0.element] }
    }
    
    /// Async replay, one event per `interval` — simulates wire timing for
    /// connection-manager and UI-conflation tests.
    public func stream(interval: Duration = .milliseconds(10)) -> AsyncStream<MarketEvent> {
        let events = corruptedSequence()
        return AsyncStream { continuation in
            let task = Task {
                for event in events {
                    try? await Task.sleep(for: interval)
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
