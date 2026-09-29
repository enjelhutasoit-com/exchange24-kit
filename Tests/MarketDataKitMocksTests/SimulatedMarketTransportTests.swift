//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKitMocks
import MarketDataKit

final class SimulatedMarketTransportTests: XCTestCase {
    func test_connect_emitsSnapshotFirst_withEverySymbol() async {
        let transport = makeTransport()
        
        let events = await collect(transport.connect(), count: 1)
        await transport.disconnect()
        
        guard case .snapshot(let ticks)? = events.first else {
            return XCTFail("expected a snapshot as the first event")
        }
        XCTAssertEqual(ticks.map(\.symbol), ["BBCA", "BBRI", "TLKM"])
    }
    
    func test_cleanFeed_neverProducesAGap() async {
        let transport = makeTransport()
        
        let events = await collect(transport.connect(), count: 100)
        await transport.disconnect()
        
        XCTAssertEqual(events.count, 100)
        for outcome in outcomes(of: events) {
            if case .gapDetected = outcome { XCTFail("a clean feed must not contain a gap") }
        }
    }
    
    func test_injectedGap_isDetectedByMergeEngine() async {
        let transport = makeTransport()
        let stream = transport.connect()
        transport.injectSequenceGap()
        
        let events = await collect(stream, count: 60)
        await transport.disconnect()
        
        let sawGap = outcomes(of: events).contains { outcome in
            if case .gapDetected = outcome { return true }
            return false
        }
        XCTAssertTrue(sawGap)
    }
    
    func test_injectedDuplicate_isIgnoredByMergeEngine() async {
        let transport = makeTransport()
        let stream = transport.connect()
        transport.injectDuplicate()
        
        let events = await collect(stream, count: 60)
        await transport.disconnect()
        
        let sawDuplicate = outcomes(of: events).contains { outcome in
            if case .duplicateIgnored = outcome { return true }
            return false
        }
        XCTAssertTrue(sawDuplicate)
    }
    
    func test_dropConnection_finishesTheStream() async {
        let transport = makeTransport()
        let stream = transport.connect()
        
        let finished = Task<Bool, Never> {
            for await _ in stream { }
            // Natural end means the server closed it. A cancelled task
            // means the safety net below fired instead.
            return !Task.isCancelled
        }
        let guardTask = Task {
            try? await Task.sleep(for: .milliseconds(Int64(3000)))
            finished.cancel()
        }
        
        transport.dropConnection()
        
        let endedNaturally = await finished.value
        guardTask.cancel()
        XCTAssertTrue(endedNaturally)
    }
    
    func test_reconnect_clearsSabotageFromThePreviousConnection() async {
        let transport = makeTransport()
        transport.setSilent(true)
        
        // A fresh connection is healthy: it must deliver events even
        // though the previous one was left silent.
        let events = await collect(transport.connect(), count: 5)
        await transport.disconnect()
        
        XCTAssertEqual(events.count, 5)
    }
    
    // MARK: - Helpers
    
    private func makeTransport() -> SimulatedMarketTransport {
        let configuration = SimulatedMarketTransport.Configuration(
            symbols: ["BBCA", "BBRI", "TLKM"],
            ticksPerBatch: 5,
            batchInterval: .milliseconds(Int64(5))
        )
        return SimulatedMarketTransport(configuration: configuration)
    }
    
    /// Reads up to `count` events, giving up after `timeoutMs` so a bug
    /// fails the test instead of hanging it.
    private func collect(
        _ stream: AsyncStream<MarketEvent>,
        count: Int,
        timeoutMs: Int64 = 3000
    ) async -> [MarketEvent] {
        let consumer = Task<[MarketEvent], Never> {
            var result: [MarketEvent] = []
            for await event in stream {
                result.append(event)
                if result.count >= count { break }
            }
            return result
        }
        let guardTask = Task {
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            consumer.cancel()
        }
        let result = await consumer.value
        guardTask.cancel()
        return result
    }
    
    /// Feeds events through MergeEngine and returns every outcome.
    private func outcomes(of events: [MarketEvent]) -> [MergeOutcome] {
        var state: [String: InstrumentTick] = [:]
        var result: [MergeOutcome] = []
        for event in events {
            let merged = MergeEngine.apply(event, to: state)
            state = merged.state
            result.append(merged.outcome)
        }
        return result
    }
    
}
