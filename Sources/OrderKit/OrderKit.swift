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

/// Explicit order lifecycle. `timeoutUnknown` exists specifically for the
/// "network dropped mid-submit" case from the JD — it is never silently
/// promoted to success or retried with a new ClientOrderID.
public enum OrderState: Sendable, Equatable {
    case draft
    case validating
    case submitting
    case submitted
    case acknowledged
    case partiallyFilled(filledQuantity: Int)
    case filled
    case rejected(reason: String)
    case timeoutUnknown
    case reconciling
    case cancelPending
    case cancelled
}

public struct Order: Sendable, Equatable {
    public let id: ClientOrderID
    public let symbol: String
    public let quantity: Int
    public let price: Decimal
    public private(set) var state: OrderState

    public init(id: ClientOrderID, symbol: String, quantity: Int, price: Decimal, state: OrderState = .draft) {
        self.id = id
        self.symbol = symbol
        self.quantity = quantity
        self.price = price
        self.state = state
    }
}

/// Public entry point consumers will hold onto. Implementation (reducer,
/// persistence, reconciliation-on-reconnect) is TODO.
public actor OrderStateMachine {
    public init() {}

    // TODO: submit(_ order: Order) async throws
    // TODO: apply(_ event: OrderEvent, to id: ClientOrderID) async
    // TODO: reconcile(pending: [ClientOrderID]) async
}
