import XCTest
@testable import OrderKit

final class OrderKitTests: XCTestCase {
    func test_order_startsInDraftState() {
        let order = Order(id: ClientOrderID(), symbol: "BBCA", quantity: 100, price: 9000)
        XCTAssertEqual(order.state, .draft)
    }

    // TODO: timeoutUnknown on network drop mid-submit
    // TODO: idempotent retry does not create a duplicate order
    // TODO: reconciliation resolves timeoutUnknown to a terminal state
}
