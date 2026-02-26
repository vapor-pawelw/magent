import ProjectDescription

let project = Project(
    name: "Magent",
    targets: [
        .target(
            name: "Magent",
            destinations: [.mac],
            product: .app,
            bundleId: "com.magent.app",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [:]),
            sources: ["Magent/**"],
            resources: ["Magent/Resources/**"],
            dependencies: [
                .xcframework(path: "Libraries/GhosttyKit.xcframework"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon",
                ]
            )
        ),
    ]
)
