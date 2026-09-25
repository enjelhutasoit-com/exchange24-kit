//
// Copyright (c) 2026 Enjel Hutasoit
//

/// Abstraction over "however events actually arrive" — a real
/// URLSessionWebSocketTask in production, a scripted replay in tests.
/// ConnectionManager only knows this protocol, never a concrete socket.
public protocol MarketDataTransport: Sendable {
    /// Opens a connection attempt and returns its event stream. The
    /// stream finishing (naturally or via disconnect()) means this
    /// attempt is over; ConnectionManager decides whether to reconnect.
    func connect() -> AsyncStream<MarketEvent>
    
    /// Forcibly tears down the current connection attempt. Called by
    /// ConnectionManager's heartbeat watchdog when it decides the
    /// connection is stale, so a silent socket gets unblocked instead
    /// of hanging forever waiting for a message that will never come.
    func disconnect() async
}
