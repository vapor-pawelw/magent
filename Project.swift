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
                "Magent/Services/AgentModelsService.swift",
                "Magent/Services/BannerManager.swift",
                "Magent/Services/CrashReportingService.swift",
                "Magent/Services/IPCCommandHandler.swift",
                "Magent/Services/IPCCommandHandler+Sections.swift",
                "Magent/Services/IPCSocketServer.swift",
                "Magent/Services/SessionTracker.swift",
                "Magent/Services/ThreadStore.swift",
                "Magent/Services/SessionLifecycleService.swift",
                "Magent/Services/JiraIntegrationService.swift",
                "Magent/Services/PullRequestService.swift",
                "Magent/Services/RateLimitService.swift",
                "Magent/Services/SidebarOrderingService.swift",
                "Magent/Services/GitStateService.swift",
                "Magent/Services/WorktreeService.swift",
                "Magent/Services/ThreadManager.swift",
                "Magent/Services/ThreadManager+*.swift",
                "Magent/Services/UpdateService.swift",
                "Magent/Services/WhatsNewContent.swift",
                "Magent/Services/WhatsNewService.swift",
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
                "config/agent-models.json",
            ],
            entitlements: .file(path: "Magent/Magent.entitlements"),
            scripts: [
                .post(
                    script: """
                    "${SRCROOT}/scripts/embed-changelog.sh"
                    """,
                    name: "Embed Changelog",
                    basedOnDependencyAnalysis: false
                ),
                .post(
                    script: """
                    "${SRCROOT}/scripts/sync-version-from-tag.sh"
                    """,
                    name: "Sync Version from Git Tag",
                    basedOnDependencyAnalysis: false
                ),
            ],
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
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) FEATURE_JIRA_SYNC",
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
