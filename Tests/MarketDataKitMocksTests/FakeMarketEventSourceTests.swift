//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKit
@testable import MarketDataKitMocks

final class FakeMarketEventSourceTests: XCTestCase {
    private func tick(_ seq: UInt64) -> MarketEvent {
        .delta(
            .init(
                symbol: "BBC",
                price: 6250,
                volume: 100,
                sequence: seq,
                receivedAt: .now
            )
        )
    }
    
    func test_noFaults_returnsCanonicalSequenceUnchanged() {
        let events = (1...5).map { tick(UInt64($0)) }
        let source = FakeMarketEventSource(canonicalEvents: events)
        XCTAssertEqual(source.corruptedSequence().count, 5)
    }
    
    func test_dropIndices_removesExactlyThoseEvents() {
        let events = (1...5).map { tick(UInt64($0)) }
        let source = FakeMarketEventSource(canonicalEvents: events, faults: FaultScript(dropIndices: [1, 3]))
        XCTAssertEqual(source.corruptedSequence().count, 3)
    }
    
    func test_duplicateIndices_insertsExactlyOneExtraCopy() {
        let events = (1...3).map { tick(UInt64($0)) }
        let source = FakeMarketEventSource(canonicalEvents: events, faults: FaultScript(duplicateIndices: [0]))
        XCTAssertEqual(source.corruptedSequence().count, 4)
    }
    
    func test_reorderPairs_swapsExactlyThoseTwoPositions() {
        let events = (1...3).map { tick(UInt64($0)) }
        let source = FakeMarketEventSource(canonicalEvents: events, faults: FaultScript(reorderPairs: [(0, 2)]))
        let result = source.corruptedSequence()
        if case let .delta(first) = result[0], case let .delta(last) = result[2] {
            XCTAssertEqual(first.sequence, 3)
            XCTAssertEqual(last.sequence, 1)
        } else {
            XCTFail("expected delta events")
        }
    }
}
