//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import OrderKit

private enum FakeNetworkError: Error {
    case timeout
    case unavailable
}

/// A fake exchange. `records` is the server-side truth keyed by
/// ClientOrderID, and submit is idempotent on it: the same ID never
/// creates a second order. Failures are scripted so each test can place
/// the network failure at the exact point it wants to examine:
///
/// - dropNextRequest: the request never reaches the server.
/// - loseNext*Response: the server DID apply the request, but the
///   response is lost, so the client sees only a timeout.
private actor FakeExchange: OrderGateway {
    private var records: [ClientOrderID: ServerOrderStatus] = [:]
    private var attempts: [ClientOrderID: Int] = [:]
    private var statusQueries = 0
    private var observedStates: [OrderState?] = []
    private let observedStore: (any OrderStore)?
    
    private var dropNextRequest = false
    private var loseNextSubmitResponse = false
    private var loseNextCancelResponse = false
    private var failNextStatusQuery = false
    private var rejectNextReason: String?
    
    init(observing store: (any OrderStore)? = nil) {
        self.observedStore = store
    }
    
    // MARK: scripting
    
    func dropNextRequestBeforeServer() { dropNextRequest = true }
    func loseNextSubmitResponseAfterServerApplied() { loseNextSubmitResponse = true }
    func loseNextCancelResponseAfterServerApplied() { loseNextCancelResponse = true }
    func failNextStatus() { failNextStatusQuery = true }
    func rejectNext(_ reason: String) { rejectNextReason = reason }
    func setServerStatus(_ id: ClientOrderID, _ status: ServerOrderStatus) { records[id] = status }
    
    // MARK: inspection
    
    func recordCount() -> Int { records.count }
    func serverStatus(_ id: ClientOrderID) -> ServerOrderStatus? { records[id] }
    func attemptCount(_ id: ClientOrderID) -> Int { attempts[id, default: 0] }
    func statusQueryCount() -> Int { statusQueries }
    func statesObservedAtSubmit() -> [OrderState?] { observedStates }
    
    // MARK: OrderGateway
    
    func submit(_ order: Order) async throws -> ServerOrderStatus {
        attempts[order.id, default: 0] += 1
        
        if let observedStore {
            let saved = await observedStore.load(order.id)
            observedStates.append(saved?.state)
        }
        
        if dropNextRequest {
            dropNextRequest = false
            throw FakeNetworkError.unavailable
        }
        
        let status: ServerOrderStatus
        if let existing = records[order.id] {
            status = existing
        } else if let reason = rejectNextReason {
            rejectNextReason = nil
            status = .rejected(reason: reason)
            records[order.id] = status
        } else {
            status = .working
            records[order.id] = status
        }
        
        if loseNextSubmitResponse {
            loseNextSubmitResponse = false
            throw FakeNetworkError.timeout
        }
        return status
    }
    
    func cancel(_ id: ClientOrderID) async throws -> ServerOrderStatus {
        let result: ServerOrderStatus
        switch records[id] {
        case .some(.working), .some(.partiallyFilled):
            records[id] = .cancelled
            result = .cancelled
        case .some(let other):
            result = other
        case .none:
            result = .notFound
        }
        
        if loseNextCancelResponse {
            loseNextCancelResponse = false
            throw FakeNetworkError.timeout
        }
        return result
    }
    
    func status(of id: ClientOrderID) async throws -> ServerOrderStatus {
        statusQueries += 1
        if failNextStatusQuery {
            failNextStatusQuery = false
            throw FakeNetworkError.unavailable
        }
        return records[id] ?? .notFound
    }
}

final class OrderStateMachineTests: XCTestCase {
    private func makeMachine(exchange: FakeExchange, store: InMemoryOrderStore) -> OrderStateMachine {
        OrderStateMachine(gateway: exchange, store: store)
    }
    
    // MARK: - happy path and persistence
    
    func test_submit_happyPath_endsAcknowledged() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        
        let state = await machine.submit(order.id)
        
        XCTAssertEqual(state, OrderState.acknowledged)
        let records = await exchange.recordCount()
        XCTAssertEqual(records, 1)
    }
    
    func test_submit_persistsSubmittingBeforeTheNetworkCall() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange(observing: store)
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        
        await machine.submit(order.id)
        
        let observed = await exchange.statesObservedAtSubmit()
        XCTAssertEqual(observed, [OrderState.submitting])
    }
    
    func test_everyTransition_isPersisted() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        
        await machine.submit(order.id)
        
        let saved = await store.load(order.id)
        XCTAssertEqual(saved?.state, OrderState.acknowledged)
    }
    
    func test_serverRejection_endsRejected() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await exchange.rejectNext("insufficient buying power")
        
        let state = await machine.submit(order.id)
        
        XCTAssertEqual(state, OrderState.rejected(reason: "insufficient buying power"))
    }
    
    // MARK: - network drops mid-submit
    
    func test_responseLost_serverApplied_reconcileFindsIt_noDuplicate() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await exchange.loseNextSubmitResponseAfterServerApplied()
        
        let afterSubmit = await machine.submit(order.id)
        XCTAssertEqual(afterSubmit, OrderState.timeoutUnknown)
        
        await machine.reconcile(order.id)
        
        let finalState = await machine.order(order.id)?.state
        let records = await exchange.recordCount()
        XCTAssertEqual(finalState, OrderState.acknowledged)
        XCTAssertEqual(records, 1)
    }
    
    func test_requestDropped_reconcileFindsNothing_retryWithSameID_placesExactlyOne() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await exchange.dropNextRequestBeforeServer()
        
        let afterSubmit = await machine.submit(order.id)
        XCTAssertEqual(afterSubmit, OrderState.timeoutUnknown)
        let recordsAfterDrop = await exchange.recordCount()
        XCTAssertEqual(recordsAfterDrop, 0)
        
        await machine.reconcile(order.id)
        let afterReconcile = await machine.order(order.id)?.state
        XCTAssertEqual(afterReconcile, OrderState.notPlaced)
        
        let afterRetry = await machine.submit(order.id)
        XCTAssertEqual(afterRetry, OrderState.acknowledged)
        
        let records = await exchange.recordCount()
        let attempts = await exchange.attemptCount(order.id)
        XCTAssertEqual(records, 1)
        XCTAssertEqual(attempts, 2)
    }
    
    func test_retryingAfterLostResponse_isIdempotent() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await exchange.loseNextSubmitResponseAfterServerApplied()
        
        await machine.submit(order.id)
        let afterRetry = await machine.submit(order.id)
        
        let records = await exchange.recordCount()
        let attempts = await exchange.attemptCount(order.id)
        XCTAssertEqual(afterRetry, OrderState.acknowledged)
        XCTAssertEqual(records, 1, "same ClientOrderID must never create a second order")
        XCTAssertEqual(attempts, 2)
    }
    
    func test_failedStatusQuery_returnsToUnknown_thenLaterReconcileSucceeds() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await exchange.loseNextSubmitResponseAfterServerApplied()
        await machine.submit(order.id)
        
        await exchange.failNextStatus()
        await machine.reconcile(order.id)
        let afterFailedQuery = await machine.order(order.id)?.state
        XCTAssertEqual(afterFailedQuery, OrderState.timeoutUnknown)
        
        await machine.reconcile(order.id)
        let afterSecondTry = await machine.order(order.id)?.state
        XCTAssertEqual(afterSecondTry, OrderState.acknowledged)
    }
    
    func test_doubleTap_sendsExactlyOneRequest() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        
        async let first = machine.submit(order.id)
        async let second = machine.submit(order.id)
        _ = await (first, second)
        
        let attempts = await exchange.attemptCount(order.id)
        let records = await exchange.recordCount()
        XCTAssertEqual(attempts, 1, "a duplicate tap must not send a second request")
        XCTAssertEqual(records, 1)
    }
    
    // MARK: - app restart
    
    func test_restart_afterLostResponse_recoversTheRealOutcome() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let firstRun = makeMachine(exchange: exchange, store: store)
        let order = await firstRun.create(symbol: "BBCA", quantity: 100, price: 9000)
        await exchange.loseNextSubmitResponseAfterServerApplied()
        await firstRun.submit(order.id)
        
        // "Relaunch": a brand-new machine over the same durable store.
        let secondRun = makeMachine(exchange: exchange, store: store)
        await secondRun.recoverAll()
        
        let state = await secondRun.order(order.id)?.state
        XCTAssertEqual(state, OrderState.acknowledged)
    }
    
    func test_restart_killedMidSubmit_serverNeverSawIt_becomesNotPlaced() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let id = ClientOrderID()
        await store.save(Order(id: id, symbol: "BBCA", quantity: 100, price: 9000, state: .submitting))
        
        let machine = makeMachine(exchange: exchange, store: store)
        await machine.recoverAll()
        
        let state = await machine.order(id)?.state
        XCTAssertEqual(state, OrderState.notPlaced)
    }
    
    func test_restart_killedMidSubmit_serverDidReceiveIt_becomesAcknowledged() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let id = ClientOrderID()
        await store.save(Order(id: id, symbol: "BBCA", quantity: 100, price: 9000, state: .submitting))
        await exchange.setServerStatus(id, .working)
        
        let machine = makeMachine(exchange: exchange, store: store)
        await machine.recoverAll()
        
        let state = await machine.order(id)?.state
        XCTAssertEqual(state, OrderState.acknowledged)
    }
    
    func test_restart_staleLocalState_isCorrectedByServer() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let id = ClientOrderID()
        await store.save(Order(id: id, symbol: "BBCA", quantity: 100, price: 9000, state: .acknowledged))
        await exchange.setServerStatus(id, .filled)
        
        let machine = makeMachine(exchange: exchange, store: store)
        await machine.recoverAll()
        
        let state = await machine.order(id)?.state
        XCTAssertEqual(state, OrderState.filled)
    }
    
    func test_restart_skipsDraftsAndTerminalOrders() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        await store.save(Order(id: ClientOrderID(), symbol: "BBCA", quantity: 100, price: 9000, state: .draft))
        await store.save(Order(id: ClientOrderID(), symbol: "BBRI", quantity: 100, price: 4000, state: .filled))
        
        let machine = makeMachine(exchange: exchange, store: store)
        await machine.recoverAll()
        
        let queries = await exchange.statusQueryCount()
        XCTAssertEqual(queries, 0)
    }
    
    // MARK: - cancellation
    
    func test_cancel_happyPath() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await machine.submit(order.id)
        
        let state = await machine.cancel(order.id)
        
        XCTAssertEqual(state, OrderState.cancelled(filledQuantity: 0))
    }
    
    func test_cancel_whenFillWinsTheRace_endsFilled() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await machine.submit(order.id)
        await exchange.setServerStatus(order.id, .filled)
        
        let state = await machine.cancel(order.id)
        
        XCTAssertEqual(state, OrderState.filled)
    }
    
    func test_cancel_responseLost_staysPending_thenReconcileResolvesIt() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await machine.submit(order.id)
        await exchange.loseNextCancelResponseAfterServerApplied()
        
        let afterCancel = await machine.cancel(order.id)
        XCTAssertEqual(afterCancel, OrderState.cancelPending(filledQuantity: 0))
        
        await machine.reconcile(order.id)
        
        let finalState = await machine.order(order.id)?.state
        XCTAssertEqual(finalState, OrderState.cancelled(filledQuantity: 0))
    }
    
    // MARK: - server pushes
    
    func test_serverUpdates_advanceDuplicateStaleAndFlagContradictions() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let order = await machine.create(symbol: "BBCA", quantity: 100, price: 9000)
        await machine.submit(order.id)
        
        let advanced = await machine.handleServerUpdate(order.id, .partiallyFilled(filledQuantity: 30))
        XCTAssertEqual(advanced, .moved(to: .partiallyFilled(filledQuantity: 30)))
        
        let duplicate = await machine.handleServerUpdate(order.id, .partiallyFilled(filledQuantity: 30))
        XCTAssertEqual(duplicate, .ignoredDuplicate)
        
        let stale = await machine.handleServerUpdate(order.id, .partiallyFilled(filledQuantity: 20))
        XCTAssertEqual(stale, .ignoredStale)
        
        let filled = await machine.handleServerUpdate(order.id, .filled)
        XCTAssertEqual(filled, .moved(to: .filled))
        
        let contradiction = await machine.handleServerUpdate(order.id, .cancelled)
        XCTAssertEqual(contradiction, .invalid)
    }
    
    // MARK: - unknown ids
    
    func test_unknownOrderID_isHandledWithoutCrashing() async {
        let store = InMemoryOrderStore()
        let exchange = FakeExchange()
        let machine = makeMachine(exchange: exchange, store: store)
        let ghost = ClientOrderID()
        
        let submitted = await machine.submit(ghost)
        let transition = await machine.handleServerUpdate(ghost, .working)
        
        XCTAssertNil(submitted)
        XCTAssertEqual(transition, .invalid)
    }
}
