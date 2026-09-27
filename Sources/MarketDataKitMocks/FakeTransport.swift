//
// Copyright (c) 2026 Enjel Hutasoit
//

import MarketDataKit

/// Wraps FakeMarketEventSource as a real MarketDataTransport: unlike the
/// source's plain `.stream()`, this holds onto the running replay task
/// so `disconnect()` can actually cancel it mid-flight — mirroring what
/// `URLSessionWebSocketTask.cancel()` does to a real socket.
public actor FakeTransport: MarketDataTransport {
    private let source: FakeMarketEventSource
    private let interval: Duration
    private var currentTask: Task<Void, Never>?
    
    public init(source: FakeMarketEventSource, interval: Duration = .milliseconds(10)) {
        self.source = source
        self.interval = interval
    }
    
    public nonisolated func connect() -> AsyncStream<MarketEvent> {
        AsyncStream { continuation in
            Task { await self.start(continuation) }
        }
    }
    
    private func start(_ continuation: AsyncStream<MarketEvent>.Continuation) {
        let events = source.corruptedSequence()
        let delay = interval
        currentTask = Task {
            for event in events {
                if Task.isCancelled { break }
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
    
    public func disconnect() async {
        currentTask?.cancel()
        currentTask = nil
    }
}
