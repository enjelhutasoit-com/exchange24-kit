//
// Copyright (c) 2026 Enjel Hutasoit
//

/// Owns the connect -> consume -> drop -> backoff -> reconnect loop for
/// a single logical market-data connection. Consumers see one continuous
/// event stream and one connection-state stream regardless of how many
/// times the underlying transport actually reconnected underneath.
public actor ConnectionManager {
    private let transport: any MarketDataTransport
    private let backoff: BackoffPolicy
    private let heartbeatTimeout: Duration
    
    private var attempt = 0
    private var lastEventAt: ContinuousClock.Instant = .now
    private var runLoopTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    
    /// heartbeatTimeout: if no event (including a server ping/heartbeat
    /// frame, once the real transport forwards one as a MarketEvent) has
    /// arrived within this window, the connection is treated as dead
    /// even though the socket never technically errored or closed.
    public init(transport: some MarketDataTransport, backoff: BackoffPolicy = .default, heartbeatTimeout: Duration = .seconds(15)) {
        self.transport = transport
        self.backoff = backoff
        self.heartbeatTimeout = heartbeatTimeout
    }
    
    /// Connection lifecycle, observed independently of the data itself —
    /// lets UI show "reconnecting…" without coupling to price data.
    public func connectionStates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            self.stateContinuation = continuation
        }
    }
    
    /// Starts the reconnect loop and returns a merged event feed spanning
    /// every connection attempt. Calling this more than once restarts
    /// the loop from a clean attempt counter.
    public func events() -> AsyncStream<MarketEvent> {
        AsyncStream { continuation in
            let task = Task { await self.runLoop(into: continuation) }
            self.runLoopTask = task
            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
        }
    }
    
    public func stop() {
        runLoopTask?.cancel()
        watchdogTask?.cancel()
        runLoopTask = nil
        watchdogTask = nil
        stateContinuation?.yield(.disconnected)
    }
    
    private func runLoop(into continuation: AsyncStream<MarketEvent>.Continuation) async {
        while !Task.isCancelled {
            stateContinuation?.yield(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            lastEventAt = .now
            startWatchdog()
            
            var sawAnyEvent = false
            for await event in transport.connect() {
                if Task.isCancelled { break }
                lastEventAt = .now
                if !sawAnyEvent {
                    sawAnyEvent = true
                    attempt = 0
                    stateContinuation?.yield(.connected)
                }
                continuation.yield(event)
            }
            
            watchdogTask?.cancel()
            if Task.isCancelled { break }
            
            let delay = backoff.delay(forAttempt: attempt)
            attempt += 1
            stateContinuation?.yield(.reconnecting(attempt: attempt))
            try? await Task.sleep(for: delay)
        }
        continuation.finish()
    }
    
    /// Polls elapsed-since-last-event on a short interval. When silence
    /// exceeds heartbeatTimeout, calls transport.disconnect() to force
    /// the run loop's `for await` to unblock — without this, a socket
    /// that goes quiet but never errors would hang the loop forever.
    private func startWatchdog() {
        let timeout = heartbeatTimeout
        watchdogTask = Task { [transport] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                let elapsed = ContinuousClock.now - self.lastEventAt
                if elapsed > timeout {
                    await transport.disconnect()
                    return
                }
            }
        }
    }
}
