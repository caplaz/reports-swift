// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "reports-swift",
    platforms: [
        .macOS("15.4"),
        .iOS("18.4")
    ],
    products: [
        .library(name: "ReportsKit", targets: ["ReportsKit"])
    ],
    dependencies: [
        // Exact pin: the consent gate and sanitizer depend on 9.24.0 transport/serialization
        // behavior (envelopes kept on disk only for connection-level failures, `close()`
        // flushing, installation-ID user, the installation ID living in
        // `<cacheDirectory>/INSTALLATION`, session envelopes bypassing `beforeSend`, stored
        // crash/hang reports keeping their collection-time scope tags) and on `@_spi(Private)`
        // API (`CachedSessionRecovery`). Re-run this package's tests on every bump.
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.24.0")
    ],
    targets: [
        .target(
            name: "ReportsKit",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa")
            ]
        ),
        .testTarget(
            name: "ReportsKitTests",
            dependencies: [
                "ReportsKit",
                .product(name: "Sentry", package: "sentry-cocoa")
            ]
        )
    ]
)
