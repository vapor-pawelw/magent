import Sentry

nonisolated(unsafe) private var _sentryInitialized = false

enum CrashReportingService {
    static func initialize() {
        guard !_sentryInitialized else { return }
        _sentryInitialized = true

        SentrySDK.start { options in
            options.dsn = "https://0a8185b6405f08c8173cf6206e4c0e83@o4510972055322624.ingest.de.sentry.io/4510972067971152"
            options.enableCrashHandler = true
            options.enableAutoSessionTracking = true
            options.debug = false
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                options.releaseName = "com.magent.app@\(version)"
            }
        }
    }
}
