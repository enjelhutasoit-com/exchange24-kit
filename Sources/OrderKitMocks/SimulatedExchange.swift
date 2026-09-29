//
// Copyright (c) 2026 Enjel Hutasoit
//

import Foundation
import OrderKit

/// The two ambiguous failures a real network produces. Both mean the
/// client does NOT know whether the request was executed.
public enum SimulatedNetworkError: Error, Sendable {
    case timeout
    case unavailable
}

/// A status pushed by the server on its own initiative (fills). Delivered
/// through SimulatedExchange.updates(), independent of any request.
public struct OrderUpdate: Sendable, Equatable {
    public let id: ClientOrderID
    public let status: ServerOrderStatus
    
    public init(id: ClientOrderID, status: ServerOrderStatus) {
        self.id = id
        self.status = status
    }
}

/// A fake exchange for the demo app and tests. `records` is the
/// server-side truth keyed by ClientOrderID and submit is idempotent on
/// it: the same ID never creates a second order.
///
/// Network failures are scripted, one shot each, so a demo (or a test) can
/// place the failure at the exact moment it wants to show:
///
/// - dropNextRequest(): the request never reaches the server.
/// - loseNextSubmitResponse(): the server DID accept the order, but the
///   client only sees a timeout. The classic duplicate-order trap.
/// - loseNextCancelResponse(): same, for a cancel.
/// - failNextStatusQuery(): the reconciliation query itself fails.
/// - rejectNext(_:): the server definitively rejects the next new order.
///
/// Latency makes in-flight states visible in a UI; use `.zero` in tests.
public actor SimulatedExchange: OrderGateway {
    private var latency: Duration
    private let autoFill: Bool
    private let fillDelay: Duration
    
    private var records: [ClientOrderID: ServerOrderStatus] = [:]
    private var submitAttempts = 0
    private var updateContinuation: AsyncStream<OrderUpdate>.Continuation?
    
    private var pendingDrop = false
    private var pendingSubmitResponseLoss = false
    private var pendingCancelResponseLoss = false
    private var pendingStatusFailure = false
    private var pendingRejection: String?
    
    public init(
        latency: Duration = .milliseconds(Int64(700)),
        autoFill: Bool = true,
        fillDelay: Duration = .milliseconds(Int64(1500))
    ) {
        self.latency = latency
        self.autoFill = autoFill
        self.fillDelay = fillDelay
    }
    
    // MARK: - Scripting
    
    public func setLatency(_ newLatency: Duration) { latency = newLatency }
    public func dropNextRequest() { pendingDrop = true }
    public func loseNextSubmitResponse() { pendingSubmitResponseLoss = true }
    public func loseNextCancelResponse() { pendingCancelResponseLoss = true }
    public func failNextStatusQuery() { pendingStatusFailure = true }
    public func rejectNext(_ reason: String) { pendingRejection = reason }
    
    /// Forces the server-side truth, e.g. "the order got filled while the
    /// client was offline".
    public func setServerStatus(_ id: ClientOrderID, _ status: ServerOrderStatus) {
        records[id] = status
    }
    
    // MARK: - Inspection ("what the server actually has")
    
    public func serverOrders() -> [ClientOrderID: ServerOrderStatus] { records }
    public func submitAttemptCount() -> Int { submitAttempts }
    
    /// Server pushes (fills). Call before submitting so nothing is missed.
    public func updates() -> AsyncStream<OrderUpdate> {
        AsyncStream { continuation in
            self.updateContinuation = continuation
        }
    }
    
    // MARK: - OrderGateway
    
    public func submit(_ order: Order) async throws -> ServerOrderStatus {
        submitAttempts += 1
        try? await Task.sleep(for: latency)
        
        if pendingDrop {
            pendingDrop = false
            throw SimulatedNetworkError.unavailable
        }
        
        let status: ServerOrderStatus
        if let existing = records[order.id] {
            // Idempotency: same ClientOrderID, same answer, no new order.
            status = existing
        } else if let reason = pendingRejection {
            pendingRejection = nil
            status = .rejected(reason: reason)
            records[order.id] = status
        } else {
            status = .working
            records[order.id] = status
            if autoFill {
                let id = order.id
                let quantity = order.quantity
                Task { await self.runFills(for: id, quantity: quantity) }
            }
        }
        
        if pendingSubmitResponseLoss {
            pendingSubmitResponseLoss = false
            throw SimulatedNetworkError.timeout
        }
        return status
    }
    
    public func cancel(_ id: ClientOrderID) async throws -> ServerOrderStatus {
        try? await Task.sleep(for: latency)
        
        let result: ServerOrderStatus
        switch records[id] {
        case .some(.working), .some(.partiallyFilled):
            records[id] = .cancelled
            result = .cancelled
        case .some(let other):
            // Too late (already filled, etc.): report the truth.
            result = other
        case .none:
            result = .notFound
        }
        
        if pendingCancelResponseLoss {
            pendingCancelResponseLoss = false
            throw SimulatedNetworkError.timeout
        }
        return result
    }
    
    public func status(of id: ClientOrderID) async throws -> ServerOrderStatus {
        try? await Task.sleep(for: latency)
        
        if pendingStatusFailure {
            pendingStatusFailure = false
            throw SimulatedNetworkError.unavailable
        }
        return records[id] ?? .notFound
    }
    
    // MARK: - Fills
    
    /// working -> partiallyFilled (a third, at least 1) -> filled, pushed
    /// to updates(). Stops quietly if the order is cancelled meanwhile.
    private func runFills(for id: ClientOrderID, quantity: Int) async {
        try? await Task.sleep(for: fillDelay)
        guard case .some(.working) = records[id] else { return }
        
        let partial = Swift.max(1, quantity / 3)
        records[id] = .partiallyFilled(filledQuantity: partial)
        updateContinuation?.yield(OrderUpdate(id: id, status: .partiallyFilled(filledQuantity: partial)))
        
        try? await Task.sleep(for: fillDelay)
        guard case .some(.partiallyFilled) = records[id] else { return }
        
        records[id] = .filled
        updateContinuation?.yield(OrderUpdate(id: id, status: .filled))
    }
}
