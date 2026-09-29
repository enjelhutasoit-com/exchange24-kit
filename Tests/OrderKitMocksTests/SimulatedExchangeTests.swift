//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import OrderKitMocks
import OrderKit

final class SimulatedExchangeTests: XCTestCase {
    private func makeOrder(quantity: Int = 300) -> Order {
        Order(id: ClientOrderID(), symbol: "BBCA", quantity: quantity, price: 9000)
    }
    
    /// No latency, no automatic fills: deterministic by construction.
    private func makeQuietExchange() -> SimulatedExchange {
        SimulatedExchange(latency: .zero, autoFill: false)
    }
    
    // MARK: - idempotency
    
    func test_submittingTheSameOrderTwice_createsOneOrder() async throws {
        let exchange = makeQuietExchange()
        let order = makeOrder()
        
        let first = try await exchange.submit(order)
        let second = try await exchange.submit(order)
        
        XCTAssertEqual(first, .working)
        XCTAssertEqual(second, .working)
        let orders = await exchange.serverOrders()
        let attempts = await exchange.submitAttemptCount()
        XCTAssertEqual(orders.count, 1)
        XCTAssertEqual(attempts, 2)
    }
    
    // MARK: - scripted network failures
    
    func test_droppedRequest_throws_andTheServerNeverSawIt() async {
        let exchange = makeQuietExchange()
        await exchange.dropNextRequest()
        
        do {
            _ = try await exchange.submit(makeOrder())
            XCTFail("expected a network error")
        } catch {
            XCTAssertTrue(error is SimulatedNetworkError)
        }
        
        let orders = await exchange.serverOrders()
        XCTAssertTrue(orders.isEmpty)
    }
    
    func test_lostResponse_throws_butTheServerStillAcceptedTheOrder() async throws {
        let exchange = makeQuietExchange()
        let order = makeOrder()
        await exchange.loseNextSubmitResponse()
        
        do {
            _ = try await exchange.submit(order)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is SimulatedNetworkError)
        }
        
        let orders = await exchange.serverOrders()
        XCTAssertEqual(orders.count, 1)
        let status = try await exchange.status(of: order.id)
        XCTAssertEqual(status, .working)
    }
    
    func test_lostResponse_isOneShot() async throws {
        let exchange = makeQuietExchange()
        let order = makeOrder()
        await exchange.loseNextSubmitResponse()
        
        _ = try? await exchange.submit(order)
        let retry = try await exchange.submit(order)
        
        XCTAssertEqual(retry, .working)
    }
    
    func test_rejectNext_rejectsTheNextNewOrder() async throws {
        let exchange = makeQuietExchange()
        await exchange.rejectNext("insufficient buying power")
        
        let status = try await exchange.submit(makeOrder())
        
        XCTAssertEqual(status, .rejected(reason: "insufficient buying power"))
    }
    
    func test_failedStatusQuery_throws_thenRecovers() async throws {
        let exchange = makeQuietExchange()
        let order = makeOrder()
        _ = try await exchange.submit(order)
        await exchange.failNextStatusQuery()
        
        do {
            _ = try await exchange.status(of: order.id)
            XCTFail("expected the status query to fail")
        } catch {
            XCTAssertTrue(error is SimulatedNetworkError)
        }
        
        let status = try await exchange.status(of: order.id)
        XCTAssertEqual(status, .working)
    }
    
    func test_statusOfUnknownOrder_isNotFound() async throws {
        let exchange = makeQuietExchange()
        
        let status = try await exchange.status(of: ClientOrderID())
        
        XCTAssertEqual(status, .notFound)
    }
    
    // MARK: - pushed fills
    
    func test_autoFill_pushesPartialThenFilled() async throws {
        let exchange = SimulatedExchange(
            latency: .zero,
            autoFill: true,
            fillDelay: .milliseconds(Int64(10))
        )
        let order = makeOrder(quantity: 300)
        let stream = await exchange.updates()
        
        let consumer = Task<[OrderUpdate], Never> {
            var received: [OrderUpdate] = []
            for await update in stream {
                received.append(update)
                if received.count >= 2 { break }
            }
            return received
        }
        // Safety net: cancelling ends the iteration, so a bug fails the
        // test instead of hanging it.
        let guardTask = Task {
            try? await Task.sleep(for: .milliseconds(Int64(3000)))
            consumer.cancel()
        }
        
        _ = try await exchange.submit(order)
        let received = await consumer.value
        guardTask.cancel()
        
        XCTAssertEqual(received, [
            OrderUpdate(id: order.id, status: .partiallyFilled(filledQuantity: 100)),
            OrderUpdate(id: order.id, status: .filled)
        ])
    }
    
    // MARK: - cancel
    
    func test_cancel_stopsPendingFills() async throws {
        let exchange = SimulatedExchange(
            latency: .zero,
            autoFill: true,
            fillDelay: .milliseconds(Int64(50))
        )
        let order = makeOrder()
        _ = try await exchange.submit(order)
        
        let result = try await exchange.cancel(order.id)
        XCTAssertEqual(result, .cancelled)
        
        // Wait past the fill delay: the fill must not overwrite the cancel.
        try? await Task.sleep(for: .milliseconds(Int64(250)))
        let orders = await exchange.serverOrders()
        XCTAssertEqual(orders[order.id], ServerOrderStatus.cancelled)
    }
    
    func test_cancel_afterFill_reportsTheFill() async throws {
        let exchange = makeQuietExchange()
        let order = makeOrder()
        _ = try await exchange.submit(order)
        await exchange.setServerStatus(order.id, .filled)
        
        let result = try await exchange.cancel(order.id)
        
        XCTAssertEqual(result, .filled)
    }
    
    func test_lostCancelResponse_throws_butTheCancelWasApplied() async throws {
        let exchange = makeQuietExchange()
        let order = makeOrder()
        _ = try await exchange.submit(order)
        await exchange.loseNextCancelResponse()
        
        do {
            _ = try await exchange.cancel(order.id)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is SimulatedNetworkError)
        }
        
        let status = try await exchange.status(of: order.id)
        XCTAssertEqual(status, .cancelled)
    }
    
    func test_cancelOfUnknownOrder_isNotFound() async throws {
        let exchange = makeQuietExchange()
        
        let result = try await exchange.cancel(ClientOrderID())
        
        XCTAssertEqual(result, .notFound)
    }
}
