// MarketDataKit
//
// Real-time market-data pipeline for a trading client:
// WebSocket transport -> decode -> sequence validation -> snapshot/delta
// merge -> conflation -> Sendable snapshot out to UI.
//
// This file only declares the public surface. Implementation lands in
// follow-up commits (connection manager, merge engine, conflation buffer).

import Foundation

/// A single instrument's live state as exposed to consumers (UI, tests).
/// Intentionally a value type so it can cross actor boundaries safely.
public struct InstrumentTick: Sendable, Equatable {
    public let symbol: String
    public let price: Decimal
    public let volume: Int
    public let sequence: UInt64
    public let receivedAt: Date

    public init(symbol: String, price: Decimal, volume: Int, sequence: UInt64, receivedAt: Date) {
        self.symbol = symbol
        self.price = price
        self.volume = volume
        self.sequence = sequence
        self.receivedAt = receivedAt
    }
}

/// Raw events coming off the wire before merge/conflation is applied.
public enum MarketEvent: Sendable {
    case snapshot([InstrumentTick])
    case delta(InstrumentTick)
    case connectionStateChanged(ConnectionState)
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

/// Public entry point consumers will hold onto. Implementation (actor-backed
/// store, AsyncStream-driven connection manager, conflation) is TODO.
public actor MarketDataStore {
    public init() {}

    // TODO: subscribe(symbols:) -> AsyncStream<InstrumentTick>
    // TODO: connectionState: AsyncStream<ConnectionState>
}
