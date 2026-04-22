import Foundation

/// Chooses where an in-app external link should open.
///
/// `create-web-tab` can target either a thread shown in the main window or a
/// thread currently popped out into its own window. Routing has to prefer the
/// popped-out destination when present, otherwise the request can be dropped by
/// main-window-only handlers.
public enum ExternalLinkOpenRouting: Equatable, Sendable {
    case poppedOutThreadWindow
    case currentMainThread
    case selectThreadInMainWindow

    public static func resolve(
        isThreadPoppedOut: Bool,
        isCurrentMainThread: Bool
    ) -> Self {
        if isThreadPoppedOut {
            return .poppedOutThreadWindow
        }
        if isCurrentMainThread {
            return .currentMainThread
        }
        return .selectThreadInMainWindow
    }
}
