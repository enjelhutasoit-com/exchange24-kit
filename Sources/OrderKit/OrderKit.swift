// OrderKit
//
// Client-side order integrity: client order IDs, idempotency, dedup,
// and an explicit state machine that treats "network dropped mid-submit"
// as a first-class state instead of assuming success or failure.
//
// This file only declares the public surface. State-machine transitions,
// persistence, and reconciliation land in follow-up commits.

import Foundation

/// Client-generated, persisted before any network call. Doubles as the
/// idempotency key sent on every retry.
public struct ClientOrderID: Sendable, Hashable {
    public let value: UUID
    public init(_ value: UUID = UUID()) {
        self.value = value
    }
}

public enum OrderSide: Sendable, Equatable {
    case buy
    case sell
}

/// Explicit order lifecycle. The states that carry the JD scenario:
///
/// - `timeoutUnknown`: the request may or may not have reached the
///   server. Never treated as success, never as failure, never retried
///   with a new ClientOrderID.
/// - `reconciling`: asking the server what actually happened.
/// - `notPlaced`: the server confirmed it has no record of this ID, so
///   it is safe to resubmit with the SAME ClientOrderID.
public enum OrderState: Sendable, Equatable {
    case draft
    case submitting
    case acknowledged
    case partiallyFilled(filledQuantity: Int)
    case filled
    case rejected(reason: String)
    case timeoutUnknown
    case reconciling
    case notPlaced
    case cancelPending(filledQuantity: Int)
    case cancelled(filledQuantity: Int)
    
    /// No further transitions expected from the server for this order.
    public var isTerminal: Bool {
        switch self {
        case .filled, .rejected, .cancelled:
            return true
        default:
            return false
        }
    }
}

public struct Order: Sendable, Equatable {
    public let id: ClientOrderID
    public let symbol: String
    public let side: OrderSide
    public let quantity: Int
    public let price: Decimal
    /// Only the state machine changes this, through OrderReducer.
    public internal(set) var state: OrderState

    public init(
        id: ClientOrderID,
        symbol: String,
        side: OrderSide = .buy,
        quantity: Int,
        price: Decimal,
        state: OrderState = .draft
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.quantity = quantity
        self.price = price
        self.state = state
    }
}

/// Placeholder until the next commit replaces it with the real
/// implementation (gateway, persistence, reconciliation).
public actor OrderStateMachine {
    public init() {}
}
