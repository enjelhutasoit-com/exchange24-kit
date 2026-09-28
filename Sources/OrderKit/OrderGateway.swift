//
// Copyright (c) 2026 Enjel Hutasoit
//

/// The network side of order handling. Implementations MUST make
/// `submit` idempotent on `order.id`: the same ClientOrderID sent twice
/// creates at most one order server-side. That contract is what makes
/// retrying after an ambiguous failure safe.
///
/// Error contract: a DEFINITIVE answer (accepted, rejected, filled) is
/// returned as a ServerOrderStatus. Anything thrown means the outcome
/// is UNKNOWN (timeout, connection lost, unreadable response). A gateway
/// must not throw for a definitive rejection, and must not return a
/// status it did not actually receive.
public protocol OrderGateway: Sendable {
    func submit(_ order: Order) async throws -> ServerOrderStatus
    func cancel(_ id: ClientOrderID) async throws -> ServerOrderStatus
    func status(of id: ClientOrderID) async throws -> ServerOrderStatus
}

/// Durable order storage. The state machine saves BEFORE any network
/// call, so an app kill mid-request leaves a record to reconcile.
public protocol OrderStore: Sendable {
    func save(_ order: Order) async
    func load(_ id: ClientOrderID) async -> Order?
    func loadAll() async -> [Order]
}

/// In-memory store for tests and the demo app. A real app would back
/// this with SQLite/Core Data/files; the protocol is the seam.
public actor InMemoryOrderStore: OrderStore {
    private var orders: [ClientOrderID: Order] = [:]
    
    public init() {}
    
    public func save(_ order: Order) {
        orders[order.id] = order
    }
    
    public func load(_ id: ClientOrderID) -> Order? {
        orders[id]
    }
    
    public func loadAll() -> [Order] {
        Array(orders.values)
    }
}
