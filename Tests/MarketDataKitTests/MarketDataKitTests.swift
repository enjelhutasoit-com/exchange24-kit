import XCTest
@testable import MarketDataKit

final class MarketDataKitTests: XCTestCase {
    func test_instrumentTick_isEquatableValueType() {
        let a = InstrumentTick(symbol: "BBCA", price: 9000, volume: 100, sequence: 1, receivedAt: Date(timeIntervalSince1970: 0))
        let b = a
        XCTAssertEqual(a, b)
    }

    // TODO: snapshot+delta merge tests (gap, duplicate, out-of-order)
    // TODO: reconnect/backoff tests
    // TODO: conflation buffer tests
}
