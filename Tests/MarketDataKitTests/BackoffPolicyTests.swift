//
// Copyright (c) 2026 Enjel Hutasoit
//

import XCTest
@testable import MarketDataKit

final class BackoffPolicyTests: XCTestCase {
    func test_delayGrowsWithAttemptNumber() {
        let policy = BackoffPolicy(initialSeconds: 1, maxSeconds: 100, multiplier: 2, jitterFraction: 0)
        let d0 = policy.delay(forAttempt: 0).components.seconds
        let d1 = policy.delay(forAttempt: 1).components.seconds
        let d2 = policy.delay(forAttempt: 2).components.seconds
        XCTAssertEqual(d0, 1)
        XCTAssertEqual(d1, 2)
        XCTAssertEqual(d2, 4)
    }
    
    func test_delayNeverExceedsMax() {
        let policy = BackoffPolicy(initialSeconds: 1, maxSeconds: 10, multiplier: 2, jitterFraction: 0)
        let farAttempt = policy.delay(forAttempt: 20).components.seconds
        XCTAssertEqual(farAttempt, 10)
    }
    
    func test_jitterStaysWithinConfiguredFraction() {
        let policy = BackoffPolicy(initialSeconds: 10, maxSeconds: 100, multiplier: 1, jitterFraction: 0.2)
        for _ in 0..<50 {
            let seconds = Double(policy.delay(forAttempt: 0).components.seconds)
            XCTAssertGreaterThanOrEqual(seconds, 8)
            XCTAssertLessThanOrEqual(seconds, 12)
        }
    }
}
