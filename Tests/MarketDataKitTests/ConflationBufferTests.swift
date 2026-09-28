//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKit

final class ConflationBufferTests: XCTestCase {
    func test_manyTicksForOneSymbol_collapseToTheLatest() {
        var buffer = ConflationBuffer()
        for seq in 1...50 {
            buffer.insert(tick("BBCA", seq: UInt64(seq)))
        }
        let batch = buffer.drain()
        
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.sequence, 50)
        XCTAssertEqual(buffer.conflatedCount, 49)
    }
    
    func test_differentSymbols_areKeptSeparateAndSortedBySymbol() {
        var buffer = ConflationBuffer()
        buffer.insert(tick("TLKM", seq: 1))
        buffer.insert(tick("BBCA", seq: 1))
        buffer.insert(tick("BBRI", seq: 1))

        let batch = buffer.drain()

        XCTAssertEqual(batch.map(\.symbol), ["BBCA", "BBRI", "TLKM"])
        XCTAssertEqual(buffer.conflatedCount, 0)
    }
    
    func test_drain_emptiesTheBuffer() {
        var buffer = ConflationBuffer()
        buffer.insert(tick("BBCA", seq: 1))
        
        XCTAssertFalse(buffer.isEmpty)
        _ = buffer.drain()
        
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.drain().count, 0)
    }
    
    func test_conflatedCount_keepsAccumulatingAcrossDrains() {
        var buffer = ConflationBuffer()
        buffer.insert(tick("BBCA", seq: 1))
        buffer.insert(tick("BBCA", seq: 2))
        _ = buffer.drain()
        buffer.insert(tick("BBCA", seq: 3))
        buffer.insert(tick("BBCA", seq: 4))
        
        XCTAssertEqual(buffer.conflatedCount, 2)
    }
    
    // MARK: - Helpers
    private func tick(_ symbol: String, seq: UInt64, price: Decimal = 9000) -> InstrumentTick {
        InstrumentTick(symbol: symbol, price: price, volume: 100, sequence: seq, receivedAt: .now)
    }
}
