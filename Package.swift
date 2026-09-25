// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Exchange24Kit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        // Real-time market data pipeline: WebSocket lifecycle, reconnect,
        // snapshot+delta merge, conflation under load.
        .library(name: "MarketDataKit", targets: ["MarketDataKit"]),

        // Client-side order integrity: client order IDs, idempotency,
        // dedup, and the order state machine.
        .library(name: "OrderKit", targets: ["OrderKit"]),
        
        // Fake event source (snapshot/delta/drop/duplicate/reorder).
        // Separate product so it never ships inside the app target —
        // only Tests and the demo app import it.
        .library(name: "MarketDataKitMocks", targets: ["MarketDataKitMocks"])
    ],
    targets: [
        .target(name: "MarketDataKit"),
        .testTarget(name: "MarketDataKitTests", dependencies: ["MarketDataKit"]),

        .target(name: "OrderKit"),
        .testTarget(name: "OrderKitTests", dependencies: ["OrderKit"]),
        
        .target(name: "MarketDataKitMocks", dependencies: ["MarketDataKit"]),
        .testTarget(name: "MarketDataKitMocksTests", dependencies: ["MarketDataKitMocks"]),
    ]
)
