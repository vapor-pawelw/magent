import Foundation

enum AppFeature {
    case jiraSync

    var isEnabled: Bool {
        switch self {
        case .jiraSync:
#if FEATURE_JIRA_SYNC
            true
#else
            false
#endif
        }
    }

    var developerAnnotation: String? {
        guard isEnabled else { return nil }

        switch self {
        case .jiraSync:
            return "Debug builds only"
        }
    }
}

enum AppFeatures {
    static let jiraSyncEnabled = AppFeature.jiraSync.isEnabled

    static func annotatedTitle(_ title: String, for feature: AppFeature) -> String {
        guard let annotation = feature.developerAnnotation else { return title }
        return "\(title) (\(annotation))"
    }
}
