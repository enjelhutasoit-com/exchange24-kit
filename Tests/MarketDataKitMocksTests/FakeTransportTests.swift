//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKitMocks
import MarketDataKit

final class FakeTransportTests: XCTestCase {
    func test_disconnect_stopsDeliveryBeforeAnyEventArrives() async {
        let events: [MarketEvent] = [
            .delta(InstrumentTick(symbol: "BBCA", price: 6250, volume: 100, sequence: 1, receivedAt: .now))
        ]
        let source = FakeMarketEventSource(canonicalEvents: events)
        let transport = FakeTransport(source: source, interval: .seconds(5))
        
        let collected = Task<[MarketEvent], Never> {
            var result: [MarketEvent] = []
            for await event in transport.connect() { result.append(event) }
            return result
        }
        
        try? await Task.sleep(for: .milliseconds(50))
        await transport.disconnect()
        
        let result = await collected.value
        XCTAssertEqual(result.count, 0)
    }
}

private actor SilentTransport: MarketDataTransport {
    private var continuation: AsyncStream<MarketEvent>.Continuation?
    
    nonisolated func connect() -> AsyncStream<MarketEvent> {
        AsyncStream { continuation in
            Task { await self.store(continuation) }
        }
    }
    
    private func store(_ continuation: AsyncStream<MarketEvent>.Continuation) {
        self.continuation = continuation
    }
    
    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }
}

final class ConnectionManagerHeartbeatTests: XCTestCase {
    // Timing-sensitive by nature (real sleeps, not a virtual clock).
    // heartbeatTimeout (200ms) is kept well below the assertion window
    // (2000ms) so scheduling drift can't turn this into a coin-flip.
    func test_heartbeatTimeout_forcesReconnectWhenSilent() async {
        let transport = SilentTransport()
        let manager = ConnectionManager(
            transport: transport,
            backoff: BackoffPolicy(initialSeconds: 0.05, maxSeconds: 0.05, jitterFraction: 0),
            heartbeatTimeout: .milliseconds(Int64(200))
        )
        
        let statesStream = await manager.connectionStates()
        
        // The events stream MUST be retained and consumed. If it is
        // dropped (e.g. `_ = await manager.events()`), AsyncStream
        // deallocation fires onTermination, which calls manager.stop()
        // and kills the run loop + watchdog before they ever run.
        let eventsStream = await manager.events()
        let drain = Task {
            for await _ in eventsStream {}
        }
        
        let collector = Task<Bool, Never> {
            for await state in statesStream {
                if case .reconnecting(let attempt) = state, attempt >= 1 {
                    return true
                }
            }
            return false
        }
        
        try? await Task.sleep(for: .milliseconds(Int64(2000)))
        await manager.stop()
        drain.cancel()
        collector.cancel()
        
        let sawReconnecting = await collector.value
        XCTAssertTrue(sawReconnecting, "expected heartbeat timeout to force a reconnect within 2s")
    }
}

