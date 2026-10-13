// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PatternSpaceCrashReporting",
    platforms: [
        .macOS("15.4"),
        .iOS("18.4")
    ],
    products: [
        .library(name: "PatternSpaceCrashReporting", targets: ["PatternSpaceCrashReporting"])
    ],
    dependencies: [
        .package(path: "../PatternSpaceCore"),
        // Exact pin: the consent gate and sanitizer depend on 9.24.0 transport/serialization
        // behavior. Re-run this package's tests on every bump (spec §2).
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.24.0")
    ],
    targets: [
        .target(
            name: "PatternSpaceCrashReporting",
            dependencies: [
                .product(name: "PatternSpaceCore", package: "PatternSpaceCore"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ]
        ),
        .testTarget(
            name: "PatternSpaceCrashReportingTests",
            dependencies: [
                "PatternSpaceCrashReporting",
                .product(name: "Sentry", package: "sentry-cocoa")
            ]
        )
    ]
)
