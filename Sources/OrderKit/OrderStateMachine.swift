//
// Copyright (c) 2026 Enjel Hutasoit
//

import Foundation

/// Owns every order's lifecycle on the client. All state changes go
/// through OrderReducer; this actor adds the side effects around it:
/// persisting, calling the gateway, and reconciling with the server.
///
/// Three rules this type exists to enforce:
/// 1. State is changed and persisted BEFORE the network call, so a
///    double tap or an app kill mid-request can never lose the order.
/// 2. An ambiguous failure (timeout, dropped connection) becomes
///    `timeoutUnknown`, and any retry reuses the SAME ClientOrderID.
/// 3. The server is the source of truth: after any doubt, ask it.
public actor OrderStateMachine {
    private let gateway: any OrderGateway
    private let store: any OrderStore
    private var orders: [ClientOrderID: Order] = [:]
    
    public init(gateway: some OrderGateway, store: some OrderStore) {
        self.gateway = gateway
        self.store = store
    }
    
    // MARK: - queries
    
    public func order(_ id: ClientOrderID) -> Order? {
        orders[id]
    }
    
    public func allOrders() -> [Order] {
        Array(orders.values)
    }
    
    // MARK: - lifecycle
    
    /// Creates a draft and persists it. The ClientOrderID generated here
    /// is the idempotency key for the whole life of the order.
    public func create(symbol: String, side: OrderSide = .buy, quantity: Int, price: Decimal) async -> Order {
        let order = Order(id: ClientOrderID(), symbol: symbol, side: side, quantity: quantity, price: price)
        orders[order.id] = order
        await store.save(order)
        return order
    }
    
    /// Submits an order. Safe to call repeatedly: a second call while the
    /// first is in flight (or after it succeeded) is a no-op that sends
    /// nothing. Returns the state after this call.
    @discardableResult
    public func submit(_ id: ClientOrderID) async -> OrderState? {
        // The state flips to .submitting synchronously inside apply(),
        // before its first suspension point. A concurrent second call
        // therefore sees .submitting and is ignored as a duplicate.
        let transition = await apply(.submitRequested, to: id)
        guard case .moved = transition, let order = orders[id] else {
            return orders[id]?.state
        }
        
        do {
            let status = try await gateway.submit(order)
            await apply(.serverReported(status), to: id)
        } catch {
            // Thrown means UNKNOWN, not failed. The request may have been
            // executed. Reconcile or retry with the same ClientOrderID.
            await apply(.submitTimedOut, to: id)
        }
        return orders[id]?.state
    }
    
    /// Requests cancellation. If the response is lost the order stays
    /// `cancelPending`; reconcile() resolves it.
    @discardableResult
    public func cancel(_ id: ClientOrderID) async -> OrderState? {
        let transition = await apply(.cancelRequested, to: id)
        guard case .moved = transition else {
            return orders[id]?.state
        }
        
        do {
            let status = try await gateway.cancel(id)
            // May be .cancelled, or .filled when the fill won the race.
            await apply(.serverReported(status), to: id)
        } catch {
            // Unknown: leave cancelPending and let reconcile() decide.
        }
        return orders[id]?.state
    }
    
    /// Asks the server what actually happened and applies the answer.
    public func reconcile(_ id: ClientOrderID) async {
        guard let order = orders[id] else { return }
        
        switch order.state {
        case .submitting, .timeoutUnknown:
            let started = await apply(.reconciliationStarted, to: id)
            guard case .moved = started else { return }
            do {
                let status = try await gateway.status(of: id)
                await apply(.serverReported(status), to: id)
            } catch {
                await apply(.reconciliationFailed, to: id)
            }
            
        case .acknowledged, .partiallyFilled, .cancelPending:
            // Already confirmed once, but the local copy may be stale
            // (fills while offline or while the app was dead).
            if let status = try? await gateway.status(of: id) {
                await apply(.serverReported(status), to: id)
            }
            
        default:
            // draft, reconciling (already running), notPlaced, terminal.
            return
        }
    }
    
    /// Applies a status pushed by the server (order update stream).
    /// Returns the transition so the caller can surface `.invalid`
    /// contradictions instead of silently swallowing them.
    @discardableResult
    public func handleServerUpdate(_ id: ClientOrderID, _ status: ServerOrderStatus) async -> OrderTransition {
        await apply(.serverReported(status), to: id)
    }
    
    /// Call on app launch. Loads persisted orders and reconciles every
    /// one that is not terminal and not a plain draft. Local state may
    /// be arbitrarily stale after a kill or a long background period.
    public func recoverAll() async {
        let persisted = await store.loadAll()
        for order in persisted where orders[order.id] == nil {
            orders[order.id] = order
        }
        for order in persisted where !order.state.isTerminal && order.state != .draft {
            await reconcile(order.id)
        }
    }
    
    // MARK: - core
    
    /// Runs the reducer and, when the state moves, updates memory FIRST
    /// (synchronously) and only then awaits persistence. Ordering matters:
    /// the in-memory change is what makes concurrent duplicate calls safe
    /// across the suspension point.
    @discardableResult
    private func apply(_ event: OrderEvent, to id: ClientOrderID) async -> OrderTransition {
        guard var order = orders[id] else { return .invalid }
        
        let transition = OrderReducer.reduce(order.state, event)
        if case .moved(let next) = transition {
            order.state = next
            orders[id] = order
            await store.save(order)
        }
        return transition
    }
}
