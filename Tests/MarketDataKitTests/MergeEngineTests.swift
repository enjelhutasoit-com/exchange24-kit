//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKit

final class MergeEngineTests: XCTestCase {
    private func tick(_ symbol: String, seq: UInt64, price: Decimal = 9000) -> InstrumentTick {
        InstrumentTick(symbol: symbol, price: price, volume: 100, sequence: seq, receivedAt: .now)
    }
    
    func test_snapshot_seedsStateForEveryInstrument() {
        let snapshot = MarketEvent.snapshot([tick("BBCA", seq: 1), tick("BBRI", seq: 1)])
        let result = MergeEngine.apply(snapshot, to: [:])
        
        XCTAssertEqual(result.outcome, .appliedSnapshot(count: 2))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 1)
        XCTAssertEqual(result.state["BBRI"]?.sequence, 1)
    }
    
    func test_inOrderDelta_advancesState() {
        let afterSnapshot = MergeEngine.apply(.snapshot([tick("BBCA", seq: 1)]), to: [:])
        let result = MergeEngine.apply(.delta(tick("BBCA", seq: 2)), to: afterSnapshot.state)
        
        XCTAssertEqual(result.outcome, .appliedDelta(symbol: "BBCA"))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 2)
    }
    
    func test_duplicateDelta_isIgnoredAndStateUnchanged() {
        let afterSnapshot = MergeEngine.apply(.snapshot([tick("BBCA", seq: 5)]), to: [:])
        let result = MergeEngine.apply(.delta(tick("BBCA", seq: 5)), to: afterSnapshot.state)
        
        XCTAssertEqual(result.outcome, .duplicateIgnored(symbol: "BBCA", sequence: 5))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 5)
    }
    
    func test_staleOutOfOrderDelta_isIgnoredAndStateUnchanged() {
        let afterSnapshot = MergeEngine.apply(.snapshot([tick("BBCA", seq: 10)]), to: [:])
        let result = MergeEngine.apply(.delta(tick("BBCA", seq: 7)), to: afterSnapshot.state)
        
        XCTAssertEqual(result.outcome, .staleIgnored(symbol: "BBCA", sequence: 7))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 10)
    }
    
    func test_gapInSequence_isDetectedAndStateUnchanged() {
        let afterSnapshot = MergeEngine.apply(.snapshot([tick("BBCA", seq: 1)]), to: [:])
        let result = MergeEngine.apply(.delta(tick("BBCA", seq: 4)), to: afterSnapshot.state)
        
        XCTAssertEqual(result.outcome, .gapDetected(symbol: "BBCA", expected: 2, got: 4))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 1, "state must not advance past a detected gap")
    }
    
    func test_deltaWithNoPriorSnapshot_isAcceptedAsBaseline() {
        let result = MergeEngine.apply(.delta(tick("BBCA", seq: 1)), to: [:])
        
        XCTAssertEqual(result.outcome, .appliedDelta(symbol: "BBCA"))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 1)
    }
    
    func test_connectionStateEvent_isIgnoredAndStateUnchanged() {
        let seeded = MergeEngine.apply(.snapshot([tick("BBCA", seq: 1)]), to: [:]).state
        let result = MergeEngine.apply(.connectionStateChanged(.connected), to: seeded)
        
        XCTAssertEqual(result.outcome, .ignoredConnectionEvent)
        XCTAssertEqual(result.state, seeded)
    }
    
    func test_multipleInstruments_areTrackedIndependently() {
        var state = MergeEngine.apply(.snapshot([tick("BBCA", seq: 1), tick("BBRI", seq: 1)]), to: [:]).state
        state = MergeEngine.apply(.delta(tick("BBCA", seq: 2)), to: state).state
        let result = MergeEngine.apply(.delta(tick("BBRI", seq: 5)), to: state)
        
        XCTAssertEqual(result.outcome, .gapDetected(symbol: "BBRI", expected: 2, got: 5))
        XCTAssertEqual(result.state["BBCA"]?.sequence, 2, "BBCA must be unaffected by BBRI's gap")
        XCTAssertEqual(result.state["BBRI"]?.sequence, 1, "BBRI must not advance past its own gap")
    }
}
