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
        .library(name: "OrderKit", targets: ["OrderKit"])
    ],
    targets: [
        .target(name: "MarketDataKit"),
        .testTarget(name: "MarketDataKitTests", dependencies: ["MarketDataKit"]),

        .target(name: "OrderKit"),
        .testTarget(name: "OrderKitTests", dependencies: ["OrderKit"])
    ]
)
