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
                "CFBundleDisplayName": "mAgent",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "mAgent",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
                "NSPrincipalClass": "NSApplication",
                "NSApplicationDelegateClassName": "AppDelegate",
                "CFBundleIconFile": "AppIcon",
            ]),
            sources: [
                "Magent/App/**",
                "Magent/Services/BannerManager.swift",
                "Magent/Services/CrashReportingService.swift",
                "Magent/Services/IPCCommandHandler.swift",
                "Magent/Services/IPCCommandHandler+Sections.swift",
                "Magent/Services/IPCSocketServer.swift",
                "Magent/Services/ThreadManager.swift",
                "Magent/Services/ThreadManager+*.swift",
                "Magent/Services/UpdateService.swift",
                "Magent/Utilities/AgentMenuBuilder.swift",
                "Magent/Utilities/ColorDot.swift",
                "Magent/Utilities/OpenActionIcons.swift",
                "Magent/Utilities/SpinnerSheet.swift",
                "Magent/Views/**",
            ],
            resources: [
                "Magent/Resources/Assets.xcassets",
                "Magent/Resources/AppIcon.icon",
                "Magent/Resources/**/*.xcstrings",
            ],
            entitlements: .file(path: "Magent/Magent.entitlements"),
            dependencies: [
                .external(name: "GhosttyBridge"),
                .external(name: "MagentCore"),
                .external(name: "Sentry-Dynamic"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.2",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
                    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
                    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ],
                configurations: [
                    .debug(
                        name: "Debug",
                        settings: [
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) FEATURE_JIRA",
                        ]
                    ),
                    .release(
                        name: "Release",
                        settings: [:]
                    ),
                ]
            )
        ),
    ]
)
