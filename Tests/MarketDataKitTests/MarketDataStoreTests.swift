//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKit

final class MarketDataStoreTests: XCTestCase {
    func test_snapshot_thenFlush_returnsEveryInstrument() async {
        let store = MarketDataStore()
        await store.ingest(
            .snapshot(
                [
                    tick("BBRI", seq: 1),
                    tick("BBCA", seq: 1)
                ]
            )
        )
        
        let batch = await store.flush()
        
        XCTAssertEqual(batch.map(\.symbol), ["BBCA", "BBRI"])
    }
    
    func test_manyDeltasForOneSymbol_flushReturnsOnlyTheLatest() async {
        let store = MarketDataStore()
        await store.ingest(.snapshot([tick("BBCA", seq: 1)]))
        _ = await store.flush()
        
        for seq in 2...20 {
            await store.ingest(.delta(tick("BBCA", seq: UInt64(seq))))
        }
        let batch = await store.flush()
        
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.sequence, 20)
        let conflated = await store.conflatedUpdateCount()
        XCTAssertEqual(conflated, 18)
    }
    
    func test_duplicateDelta_neverReachesTheBuffer() async {
        let store = MarketDataStore()
        await store.ingest(.snapshot([tick("BBCA", seq: 1)]))
        await store.ingest(.delta(tick("BBCA", seq: 2)))
        _ = await store.flush()
        
        let outcome = await store.ingest(.delta(tick("BBCA", seq: 2)))
        let batch = await store.flush()
        
        XCTAssertEqual(outcome, .duplicateIgnored(symbol: "BBCA", sequence: 2))
        XCTAssertTrue(batch.isEmpty)
    }
    
    func test_gap_setsNeedsResync_andSnapshotClearsIt() async {
        let store = MarketDataStore()
        await store.ingest(.snapshot([tick("BBCA", seq: 1)]))
        
        let outcome = await store.ingest(.delta(tick("BBCA", seq: 5)))
        let flaggedAfterGap = await store.needsResync
        
        XCTAssertEqual(outcome, .gapDetected(symbol: "BBCA", expected: 2, got: 5))
        XCTAssertTrue(flaggedAfterGap)
        
        await store.ingest(.snapshot([tick("BBCA", seq: 9)]))
        let flaggedAfterSnapshot = await store.needsResync
        let state = await store.currentState()
        
        XCTAssertFalse(flaggedAfterSnapshot)
        XCTAssertEqual(state["BBCA"]?.sequence, 9)
    }
    
    func test_gappedDelta_isNotAddedToTheBuffer() async {
        let store = MarketDataStore()
        await store.ingest(.snapshot([tick("BBCA", seq: 1)]))
        _ = await store.flush()
        
        await store.ingest(.delta(tick("BBCA", seq: 5)))
        let batch = await store.flush()
        
        XCTAssertTrue(batch.isEmpty, "a gapped tick must not be shown to the UI")
    }
    
    func test_updatesStream_deliversOneConflatedBatch() async {
        let store = MarketDataStore()
        await store.ingest(.snapshot([tick("BBCA", seq: 1)]))
        await store.ingest(.delta(tick("BBCA", seq: 2)))
        await store.ingest(.delta(tick("BBCA", seq: 3)))
        
        // Stream must be retained and consumed for the flush loop to live.
        let stream = await store.updates(every: .milliseconds(Int64(50)))
        
        let consumer = Task<[InstrumentTick]?, Never> {
            for await batch in stream { return batch }
            return nil
        }
        // Safety net: cancelling ends the iteration, so a bug fails the
        // test instead of hanging it.
        let guardTask = Task {
            try? await Task.sleep(for: .milliseconds(Int64(2000)))
            consumer.cancel()
        }
        
        let batch = await consumer.value
        guardTask.cancel()
        
        XCTAssertEqual(batch?.count, 1)
        XCTAssertEqual(batch?.first?.sequence, 3)
    }
    
    // MARK: - Helpers
    private func tick(_ symbol: String, seq: UInt64, price: Decimal = 9000) -> InstrumentTick {
        InstrumentTick(symbol: symbol, price: price, volume: 100, sequence: seq, receivedAt: .now)
    }
}
