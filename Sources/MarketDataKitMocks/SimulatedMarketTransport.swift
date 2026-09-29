//
// Copyright (c) 2026 Enjel Hutasoit
//

import Foundation
import MarketDataKit

/// A fake exchange feed for the demo app and for tests: a snapshot on
/// connect, then an endless random-walk of per-symbol deltas with correct
/// sequence numbers. Unlike FakeMarketEventSource (a finite scripted
/// replay), this one runs live and can be sabotaged on demand:
///
/// - injectSequenceGap(): the next tick skips a sequence number.
/// - injectDuplicate(): the next tick is delivered twice.
/// - setSilent(true): the socket stays open but stops sending.
/// - dropConnection(): the "server" closes the stream.
/// - sendSnapshot(): pushes a fresh snapshot (what a resync would do).
///
/// A plain class guarded by a lock rather than an actor, for the same
/// reason as FakeTransport: connect() must store its continuation
/// synchronously so disconnect()/dropConnection() can never race against
/// a deferred async store. The lock makes the generator task and the
/// control methods safe against each other.
public final class SimulatedMarketTransport: MarketDataTransport, @unchecked Sendable {
    private let configuration: Configuration
    private let lock = NSLock()
    private var continuation: AsyncStream<MarketEvent>.Continuation?
    private var duplicatePending = false
    private var gapPending = false
    private var generator: Task<Void, Never>?
    private var prices: [String: Int] = [:]
    private var sequences: [String: UInt64] = [:]
    private var silent = false

    public struct Configuration: Sendable {
        public var symbols: [String]
        public var ticksPerBatch: Int
        public var batchInterval: Duration
        
        /// Defaults produce roughly 500 ticks per second across 30 symbols.
        public init(
            symbols: [String] = SimulatedMarketTransport.defaultSymbols,
            ticksPerBatch: Int = 10,
            batchInterval: Duration = .milliseconds(Int64(20))
        ) {
            self.symbols = symbols
            self.ticksPerBatch = ticksPerBatch
            self.batchInterval = batchInterval
        }
    }
    
    public static let defaultSymbols: [String] = [
        "BBCA", "BBRI", "BMRI", "BBNI", "TLKM", "ASII", "UNVR", "ICBP", "INDF", "GOTO",
        "ADRO", "PTBA", "ANTM", "MDKA", "AMRT", "CPIN", "KLBF", "SMGR", "INKP", "TPIA",
        "BRPT", "PGAS", "EXCL", "ISAT", "JSMR", "MAPI", "ACES", "ERAA", "HRUM", "ITMG"
    ]
    
    /// "S0001", "S0002", ... for load tests with thousands of instruments.
    public static func syntheticSymbols(count: Int) -> [String] {
        (1...max(1, count)).map { String(format: "S%04d", $0) }
    }
        
    public init(configuration: Configuration = Configuration()) {
        precondition(!configuration.symbols.isEmpty, "SimulatedMarketTransport needs at least one symbol")
        precondition(configuration.ticksPerBatch > 0, "ticksPerBatch must be positive")
        self.configuration = configuration
        
        var seeded: [String: Int] = [:]
        for (index, symbol) in configuration.symbols.enumerated() {
            seeded[symbol] = 1000 + (index * 373) % 9000
        }
        self.prices = seeded
    }
    
    // MARK: - MarketDataTransport
    
    public func connect() -> AsyncStream<MarketEvent> {
        AsyncStream { continuation in
            let snapshot: [InstrumentTick] = lock.withLock {
                generator?.cancel()
                self.continuation = continuation
                // A fresh connection is a healthy one: sabotage flags
                // from the previous connection do not carry over.
                silent = false
                gapPending = false
                duplicatePending = false
                return makeSnapshotLocked()
            }
            continuation.yield(.snapshot(snapshot))
            
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runGenerator()
            }
            lock.withLock { generator = task }
        }
    }
    
    public func disconnect() async {
        dropConnection()
    }
    
    // MARK: - Sabotage controls
    
    public func injectSequenceGap() {
        lock.withLock { gapPending = true }
    }
    
    public func injectDuplicate() {
        lock.withLock { duplicatePending = true }
    }
    
    public func setSilent(_ isSilent: Bool) {
        lock.withLock { silent = isSilent }
    }
    
    /// Simulates the server closing the connection.
    public func dropConnection() {
        let closing: AsyncStream<MarketEvent>.Continuation? = lock.withLock {
            generator?.cancel()
            generator = nil
            let current = continuation
            continuation = nil
            return current
        }
        closing?.finish()
    }
    
    /// Pushes a fresh snapshot with current sequence numbers. This is
    /// what the server would answer to a resync request.
    public func sendSnapshot() {
        let pair: (AsyncStream<MarketEvent>.Continuation?, [InstrumentTick]) = lock.withLock {
            (continuation, makeSnapshotLocked())
        }
        pair.0?.yield(.snapshot(pair.1))
    }
    
    // MARK: - Generator
    
    private func runGenerator() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: configuration.batchInterval)
            if Task.isCancelled { break }
            
            let batch = nextBatch()
            for event in batch.events {
                batch.continuation?.yield(event)
            }
        }
    }
    
    private func nextBatch() -> (events: [MarketEvent], continuation: AsyncStream<MarketEvent>.Continuation?) {
        lock.withLock { () -> (events: [MarketEvent], continuation: AsyncStream<MarketEvent>.Continuation?) in
            guard !silent, continuation != nil else {
                return ([], continuation)
            }
            
            var events: [MarketEvent] = []
            for _ in 0..<configuration.ticksPerBatch {
                let tick = makeTickLocked()
                events.append(.delta(tick))
                if duplicatePending {
                    duplicatePending = false
                    events.append(.delta(tick))
                }
            }
            return (events, continuation)
        }
    }
    
    // MARK: - State (call only while holding the lock)
    
    private func makeTickLocked() -> InstrumentTick {
        let symbol = configuration.symbols[Int.random(in: 0..<configuration.symbols.count)]
        
        let step = Int.random(in: -2...2) * 5
        let price = Swift.max(50, (prices[symbol] ?? 1000) + step)
        prices[symbol] = price
        
        var next = (sequences[symbol] ?? 0) + 1
        if gapPending {
            next += 1
            gapPending = false
        }
        sequences[symbol] = next
        
        return InstrumentTick(
            symbol: symbol,
            price: Decimal(price),
            volume: Int.random(in: 1...50) * 100,
            sequence: next,
            receivedAt: Date()
        )
    }
    
    private func makeSnapshotLocked() -> [InstrumentTick] {
        configuration.symbols.map { symbol in
            InstrumentTick(
                symbol: symbol,
                price: Decimal(prices[symbol] ?? 1000),
                volume: 0,
                sequence: sequences[symbol] ?? 0,
                receivedAt: Date()
            )
        }
    }
}
