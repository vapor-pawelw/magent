import Foundation

enum AppFeature {
    case jiraIntegration

    var isEnabled: Bool {
        switch self {
        case .jiraIntegration:
#if FEATURE_JIRA
            true
#else
            false
#endif
        }
    }

    var developerAnnotation: String? {
        guard isEnabled else { return nil }

        switch self {
        case .jiraIntegration:
            return "Debug builds only"
        }
    }
}

enum AppFeatures {
    static let jiraIntegrationEnabled = AppFeature.jiraIntegration.isEnabled

    static func annotatedTitle(_ title: String, for feature: AppFeature) -> String {
        guard let annotation = feature.developerAnnotation else { return title }
        return "\(title) (\(annotation))"
    }
}
