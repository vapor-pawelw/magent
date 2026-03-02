// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagentDependencies",
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ]
)
