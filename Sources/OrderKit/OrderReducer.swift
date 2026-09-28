//
// Copyright (c) 2026 Enjel Hutasoit
//

/// What the server says about an order. Fills are CUMULATIVE
/// (`filledQuantity` is the total so far, not the latest slice), which
/// makes duplicate and out-of-order fill reports detectable by comparison.
public enum ServerOrderStatus: Sendable, Equatable {
    case notFound
    case working
    case partiallyFilled(filledQuantity: Int)
    case filled
    case rejected(reason: String)
    case cancelled
}

public enum OrderEvent: Sendable, Equatable {
    case submitRequested
    /// The submit request failed or timed out: the outcome is UNKNOWN.
    case submitTimedOut
    case reconciliationStarted
    /// The status query itself failed; we still do not know.
    case reconciliationFailed
    case cancelRequested
    case serverReported(ServerOrderStatus)
}

/// Classification of one event applied to one state.
///
/// - `moved`: state changes.
/// - `ignoredDuplicate`: the event repeats what the state already
///   reflects (double tap, duplicate server message).
/// - `ignoredStale`: older information arriving late (a timeout timer
///   firing after the response already came back, a fill report lower
///   than one already applied).
/// - `invalid`: contradicts what we know (a rejected order reported as
///   filled). The caller should surface this as an anomaly, not hide it.
public enum OrderTransition: Sendable, Equatable {
    case moved(to: OrderState)
    case ignoredDuplicate
    case ignoredStale
    case invalid
}

/// Pure transition table. No I/O, no clock, no concurrency: every case
/// is a plain (state, event) -> transition pair a test can assert on.
public enum OrderReducer {
    public static func reduce(_ state: OrderState, _ event: OrderEvent) -> OrderTransition {
        switch state {
        case .draft:
            return fromDraft(event)
        case .submitting, .timeoutUnknown, .reconciling, .notPlaced:
            return fromUnconfirmed(state, event)
        case .acknowledged, .partiallyFilled, .cancelPending, .filled, .rejected, .cancelled:
            return fromConfirmed(state, event)
        }
    }
    
    // MARK: - draft
    
    private static func fromDraft(_ event: OrderEvent) -> OrderTransition {
        switch event {
        case .submitRequested:
            return .moved(to: .submitting)
        default:
            return .invalid
        }
    }
    
    // MARK: - server has not confirmed the order yet
    
    private static func fromUnconfirmed(_ state: OrderState, _ event: OrderEvent) -> OrderTransition {
        switch event {
        case .submitRequested:
            switch state {
            case .timeoutUnknown, .notPlaced:
                // Retry. The caller reuses the SAME ClientOrderID, so the
                // server can dedupe if the first attempt did land.
                return .moved(to: .submitting)
            default:
                // submitting or reconciling: already in flight. Double tap.
                return .ignoredDuplicate
            }
            
        case .submitTimedOut:
            switch state {
            case .submitting:
                return .moved(to: .timeoutUnknown)
            case .timeoutUnknown:
                return .ignoredDuplicate
            default:
                return .ignoredStale
            }
            
        case .reconciliationStarted:
            switch state {
            case .submitting, .timeoutUnknown:
                // submitting is allowed too: after an app restart, an
                // order persisted mid-submit must be reconciled.
                return .moved(to: .reconciling)
            case .reconciling:
                return .ignoredDuplicate
            default:
                return .invalid
            }
            
        case .reconciliationFailed:
            switch state {
            case .reconciling:
                return .moved(to: .timeoutUnknown)
            case .timeoutUnknown:
                return .ignoredStale
            default:
                return .invalid
            }
            
        case .cancelRequested:
            // Cannot cancel something the server has not confirmed.
            return .invalid
            
        case .serverReported(let status):
            return unconfirmedServerReport(state, status)
        }
    }
    
    private static func unconfirmedServerReport(_ state: OrderState, _ status: ServerOrderStatus) -> OrderTransition {
        switch status {
        case .notFound:
            switch state {
            case .reconciling:
                return .moved(to: .notPlaced)
            case .notPlaced:
                return .ignoredDuplicate
            default:
                return .ignoredStale
            }
        case .working:
            // Also covers a late response after timeoutUnknown, and a
            // request that lands AFTER reconciliation said notFound.
            return .moved(to: .acknowledged)
        case .partiallyFilled(let filled):
            guard filled > 0 else { return .invalid }
            return .moved(to: .partiallyFilled(filledQuantity: filled))
        case .filled:
            return .moved(to: .filled)
        case .rejected(let reason):
            return .moved(to: .rejected(reason: reason))
        case .cancelled:
            switch state {
            case .reconciling:
                return .moved(to: .cancelled(filledQuantity: 0))
            default:
                return .invalid
            }
        }
    }
    
    // MARK: - server has confirmed the order
    
    private static func fromConfirmed(_ state: OrderState, _ event: OrderEvent) -> OrderTransition {
        switch event {
        case .submitTimedOut, .reconciliationStarted, .reconciliationFailed:
            // Old timers and queries resolving after the answer is known.
            return .ignoredStale
            
        case .submitRequested:
            switch state {
            case .rejected, .cancelled:
                return .invalid
            default:
                return .ignoredDuplicate
            }
            
        case .cancelRequested:
            switch state {
            case .acknowledged:
                return .moved(to: .cancelPending(filledQuantity: 0))
            case .partiallyFilled(let filled):
                return .moved(to: .cancelPending(filledQuantity: filled))
            case .cancelPending, .cancelled:
                return .ignoredDuplicate
            default:
                return .invalid
            }
            
        case .serverReported(let status):
            return confirmedServerReport(state, status)
        }
    }
    
    private static func confirmedServerReport(_ state: OrderState, _ status: ServerOrderStatus) -> OrderTransition {
        switch status {
        case .notFound:
            // Ambiguous: could be a reconciliation query that raced with
            // the acknowledgement. Never destroy confirmed local knowledge.
            return .ignoredStale
            
        case .working:
            if case .acknowledged = state { return .ignoredDuplicate }
            return .ignoredStale
            
        case .partiallyFilled(let reported):
            guard reported > 0 else { return .invalid }
            switch state {
            case .acknowledged:
                return .moved(to: .partiallyFilled(filledQuantity: reported))
            case .partiallyFilled(let known):
                return advance(reported, over: known, to: .partiallyFilled(filledQuantity: reported))
            case .cancelPending(let known):
                return advance(reported, over: known, to: .cancelPending(filledQuantity: reported))
            case .cancelled(let known):
                // A fill AFTER the cancel was confirmed contradicts it.
                if reported > known { return .invalid }
                return reported == known ? .ignoredDuplicate : .ignoredStale
            case .filled:
                return .ignoredStale
            default:
                return .invalid
            }
            
        case .filled:
            switch state {
            case .acknowledged, .partiallyFilled, .cancelPending:
                // Includes the cancel race: the fill beat the cancel.
                return .moved(to: .filled)
            case .filled:
                return .ignoredDuplicate
            default:
                return .invalid
            }
            
        case .rejected:
            switch state {
            case .rejected:
                return .ignoredDuplicate
            default:
                // A confirmed order cannot become rejected.
                return .invalid
            }
            
        case .cancelled:
            switch state {
            case .acknowledged:
                return .moved(to: .cancelled(filledQuantity: 0))
            case .partiallyFilled(let filled), .cancelPending(let filled):
                return .moved(to: .cancelled(filledQuantity: filled))
            case .cancelled:
                return .ignoredDuplicate
            default:
                return .invalid
            }
        }
    }
    
    /// Cumulative fill comparison: higher advances, equal is a duplicate,
    /// lower is stale.
    private static func advance(_ reported: Int, over known: Int, to next: OrderState) -> OrderTransition {
        if reported > known { return .moved(to: next) }
        if reported == known { return .ignoredDuplicate }
        return .ignoredStale
    }
}
