// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagentModules",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MagentCore",
            targets: ["MagentCore"]
        ),
        .library(
            name: "GhosttyBridge",
            targets: ["GhosttyBridge"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../Libraries/GhosttyKit.xcframework"
        ),
        .target(
            name: "MagentModels",
            path: "Sources/MagentModels"
        ),
        .target(
            name: "ShellInfra",
            path: "Sources/ShellInfra"
        ),
        .target(
            name: "GitCore",
            dependencies: [
                "MagentModels",
                "ShellInfra",
            ],
            path: "Sources/GitCore"
        ),
        .target(
            name: "TmuxCore",
            dependencies: [
                "MagentModels",
                "ShellInfra",
            ],
            path: "Sources/TmuxCore"
        ),
        .target(
            name: "JiraCore",
            dependencies: ["ShellInfra"],
            path: "Sources/JiraCore"
        ),
        .target(
            name: "IPCCore",
            dependencies: ["MagentModels"],
            path: "Sources/IPCCore"
        ),
        .target(
            name: "MagentCore",
            dependencies: [
                "IPCCore",
                "MagentModels",
                "ShellInfra",
                "GitCore",
                "TmuxCore",
                "JiraCore",
            ],
            path: "Sources/MagentCore"
        ),
        .target(
            name: "GhosttyBridge",
            dependencies: ["GhosttyKit"],
            path: "Sources/GhosttyBridge"
        ),
    ]
)
