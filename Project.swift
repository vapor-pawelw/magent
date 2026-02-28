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
            infoPlist: .dictionary([
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "$(PRODUCT_NAME)",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
                "NSPrincipalClass": "NSApplication",
                "NSApplicationDelegateClassName": "AppDelegate",
                "CFBundleIconFile": "AppIcon",
            ]),
            sources: ["Magent/**"],
            resources: [
                "Magent/Resources/Assets.xcassets",
                "Magent/Resources/AppIcon.icon",
            ],
            entitlements: .file(path: "Magent/Magent.entitlements"),
            dependencies: [
                .target(name: "GhosttyBridge"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.2",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
                ]
            )
        ),
        .target(
            name: "GhosttyBridge",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "com.magent.ghosttybridge",
            deploymentTargets: .macOS("14.0"),
            sources: ["GhosttyBridge/**"],
            dependencies: [
                .xcframework(path: "Libraries/GhosttyKit.xcframework"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.2",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon",
                ]
            )
        ),
    ]
)
