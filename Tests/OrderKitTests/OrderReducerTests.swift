//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import OrderKit

final class OrderReducerTests: XCTestCase {
    
    // MARK: - happy path and basic guards
    
    func test_happyPath_draftToFilled() {
        let state = run([
            .submitRequested,
            .serverReported(.working),
            .serverReported(.partiallyFilled(filledQuantity: 30)),
            .serverReported(.filled)
        ])
        XCTAssertEqual(state, .filled)
    }
    
    func test_draft_acceptsOnlySubmit() {
        XCTAssertEqual(OrderReducer.reduce(.draft, .serverReported(.working)), .invalid)
        XCTAssertEqual(OrderReducer.reduce(.draft, .cancelRequested), .invalid)
        XCTAssertEqual(OrderReducer.reduce(.draft, .submitTimedOut), .invalid)
    }
    
    func test_doubleTapWhileSubmitting_isDuplicate() {
        XCTAssertEqual(OrderReducer.reduce(.submitting, .submitRequested), .ignoredDuplicate)
    }
    
    // MARK: - network drops mid-submit
    
    func test_timeoutMidSubmit_becomesUnknown_notFailure() {
        let state = run([.submitRequested, .submitTimedOut])
        XCTAssertEqual(state, .timeoutUnknown)
    }
    
    func test_reconcileFindsWorkingOrder_becomesAcknowledged() {
        let state = run([
            .submitRequested,
            .submitTimedOut,
            .reconciliationStarted,
            .serverReported(.working)
        ])
        XCTAssertEqual(state, .acknowledged)
    }
    
    func test_reconcileFindsNothing_becomesNotPlaced_thenRetryReusesSubmit() {
        let placed = run([
            .submitRequested,
            .submitTimedOut,
            .reconciliationStarted,
            .serverReported(.notFound)
        ])
        XCTAssertEqual(placed, .notPlaced)
        XCTAssertEqual(OrderReducer.reduce(.notPlaced, .submitRequested), .moved(to: .submitting))
    }
    
    func test_failedReconciliation_fallsBackToUnknown() {
        let state = run([
            .submitRequested,
            .submitTimedOut,
            .reconciliationStarted,
            .reconciliationFailed
        ])
        XCTAssertEqual(state, .timeoutUnknown)
    }
    
    func test_lateResponseAfterTimeout_isAccepted() {
        XCTAssertEqual(
            OrderReducer.reduce(.timeoutUnknown, .serverReported(.working)),
            .moved(to: .acknowledged)
        )
    }
    
    func test_requestLandingAfterNotFound_isAccepted() {
        XCTAssertEqual(
            OrderReducer.reduce(.notPlaced, .serverReported(.working)),
            .moved(to: .acknowledged)
        )
    }
    
    func test_timeoutFiringAfterAcknowledgement_isStale() {
        XCTAssertEqual(OrderReducer.reduce(.acknowledged, .submitTimedOut), .ignoredStale)
    }
    
    func test_orderPersistedMidSubmit_canBeReconciledAfterRestart() {
        XCTAssertEqual(
            OrderReducer.reduce(.submitting, .reconciliationStarted),
            .moved(to: .reconciling)
        )
    }
    
    func test_ambiguousNotFound_neverDestroysConfirmedState() {
        XCTAssertEqual(
            OrderReducer.reduce(.acknowledged, .serverReported(.notFound)),
            .ignoredStale
        )
    }
    
    // MARK: - rejection and contradictions
    
    func test_rejection_isTerminal_andDuplicatesAreIgnored() {
        let state = run([.submitRequested, .serverReported(.rejected(reason: "insufficient buying power"))])
        XCTAssertEqual(state, .rejected(reason: "insufficient buying power"))
        XCTAssertTrue(state.isTerminal)
        XCTAssertEqual(
            OrderReducer.reduce(state, .serverReported(.rejected(reason: "insufficient buying power"))),
            .ignoredDuplicate
        )
    }
    
    func test_contradictions_areInvalid() {
        XCTAssertEqual(
            OrderReducer.reduce(.rejected(reason: "x"), .serverReported(.filled)),
            .invalid
        )
        XCTAssertEqual(OrderReducer.reduce(.acknowledged, .serverReported(.rejected(reason: "x"))), .invalid)
        XCTAssertEqual(OrderReducer.reduce(.filled, .serverReported(.cancelled)), .invalid)
        XCTAssertEqual(OrderReducer.reduce(.cancelled(filledQuantity: 0), .serverReported(.filled)), .invalid)
    }
    
    // MARK: - fills
    
    func test_fillBeforeAcknowledgement_isAccepted() {
        XCTAssertEqual(
            OrderReducer.reduce(.submitting, .serverReported(.partiallyFilled(filledQuantity: 10))),
            .moved(to: .partiallyFilled(filledQuantity: 10))
        )
        XCTAssertEqual(OrderReducer.reduce(.submitting, .serverReported(.filled)), .moved(to: .filled))
    }
    
    func test_cumulativeFills_advanceDuplicateAndStale() {
        let state = OrderState.partiallyFilled(filledQuantity: 30)
        XCTAssertEqual(
            OrderReducer.reduce(state, .serverReported(.partiallyFilled(filledQuantity: 50))),
            .moved(to: .partiallyFilled(filledQuantity: 50))
        )
        XCTAssertEqual(
            OrderReducer.reduce(state, .serverReported(.partiallyFilled(filledQuantity: 30))),
            .ignoredDuplicate
        )
        XCTAssertEqual(
            OrderReducer.reduce(state, .serverReported(.partiallyFilled(filledQuantity: 20))),
            .ignoredStale
        )
    }
    
    func test_zeroQuantityFill_isInvalid() {
        XCTAssertEqual(
            OrderReducer.reduce(.acknowledged, .serverReported(.partiallyFilled(filledQuantity: 0))),
            .invalid
        )
    }
    
    // MARK: - cancellation
    
    func test_cancelFlow_fromAcknowledged() {
        let state = run([
            .submitRequested,
            .serverReported(.working),
            .cancelRequested,
            .serverReported(.cancelled)
        ])
        XCTAssertEqual(state, .cancelled(filledQuantity: 0))
    }
    
    func test_cancelKeepsFilledQuantity() {
        let state = run([
            .cancelRequested,
            .serverReported(.cancelled)
        ], from: .partiallyFilled(filledQuantity: 40))
        XCTAssertEqual(state, .cancelled(filledQuantity: 40))
    }
    
    func test_fillBeatsCancel_endsFilled() {
        let state = run([.serverReported(.filled)], from: .cancelPending(filledQuantity: 0))
        XCTAssertEqual(state, .filled)
    }
    
    func test_fillProgressDuringCancelPending_isTracked() {
        let state = run(
            [.serverReported(.partiallyFilled(filledQuantity: 25))],
            from: .cancelPending(filledQuantity: 10)
        )
        XCTAssertEqual(state, .cancelPending(filledQuantity: 25))
    }
    
    func test_cancelNeedsConfirmedOrder() {
        XCTAssertEqual(OrderReducer.reduce(.submitting, .cancelRequested), .invalid)
        XCTAssertEqual(OrderReducer.reduce(.timeoutUnknown, .cancelRequested), .invalid)
        XCTAssertEqual(OrderReducer.reduce(.filled, .cancelRequested), .invalid)
    }
    
    // MARK: - terminal states absorb noise
    
    func test_terminalStates_absorbDuplicatesAndStaleMessages() {
        XCTAssertEqual(OrderReducer.reduce(.filled, .serverReported(.filled)), .ignoredDuplicate)
        XCTAssertEqual(
            OrderReducer.reduce(.filled, .serverReported(.partiallyFilled(filledQuantity: 10))),
            .ignoredStale
        )
        XCTAssertEqual(OrderReducer.reduce(.filled, .submitTimedOut), .ignoredStale)
        XCTAssertEqual(
            OrderReducer.reduce(.cancelled(filledQuantity: 0), .serverReported(.cancelled)),
            .ignoredDuplicate
        )
    }
    
    func test_isTerminal() {
        XCTAssertTrue(OrderState.filled.isTerminal)
        XCTAssertTrue(OrderState.rejected(reason: "x").isTerminal)
        XCTAssertTrue(OrderState.cancelled(filledQuantity: 0).isTerminal)
        XCTAssertFalse(OrderState.timeoutUnknown.isTerminal)
        XCTAssertFalse(OrderState.acknowledged.isTerminal)
        XCTAssertFalse(OrderState.cancelPending(filledQuantity: 0).isTerminal)
    }
    
    // MARK: - Helpers
    
    /// Folds events into a state. Ignored events leave the state alone;
    /// an invalid event fails the test at the call site.
    private func run(
        _ events: [OrderEvent],
        from start: OrderState = .draft,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> OrderState {
        var state = start
        for event in events {
            switch OrderReducer.reduce(state, event) {
            case .moved(let next):
                state = next
            case .ignoredDuplicate, .ignoredStale:
                break
            case .invalid:
                XCTFail("invalid event \(event) from \(state)", file: file, line: line)
            }
        }
        return state
    }
}
