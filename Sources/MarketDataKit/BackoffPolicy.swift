//
// Copyright (c) 2026 Enjel Hutasoit
//

import Foundation

/// Delay schedule for reconnect attempts. Jitter exists so a fleet of
/// clients that all drop at the same moment (e.g. a backend blip at
/// market open) don't all retry in lockstep and hammer the server at
/// the same instant.
public struct BackoffPolicy: Sendable {
    public var initialSeconds: Double
    public var maxSeconds: Double
    public var multiplier: Double
    /// Fraction of the computed delay randomized in both directions.
    /// 0.2 = delay can land anywhere in [computed * 0.8, computed * 1.2].
    public var jitterFraction: Double
    
    public static let `default` = BackoffPolicy()
    
    public init(
        initialSeconds: Double = 0.5,
        maxSeconds: Double = 30,
        multiplier: Double = 2.0,
        jitterFraction: Double = 0.2
    ) {
        self.initialSeconds = initialSeconds
        self.maxSeconds = maxSeconds
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
    }
    
    /// Delay for a zero-based attempt number. Attempt 0 = first retry
    /// after the initial connection dropped.
    public func delay(forAttempt attempt: Int) -> Duration {
        let raw = initialSeconds * pow(multiplier, Double(attempt))
        let capped = min(raw, maxSeconds)
        let jitterRange: Double = capped * jitterFraction
        let jittered = capped + Double.random(in: -jitterRange...jitterRange)
        return .seconds(max(0, jittered))
    }
}
