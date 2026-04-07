import Foundation

/// Persistence model for pop-out window state across app launches.
public struct PopoutWindowState: Codable, Sendable {
    public struct CodableRect: Codable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct ThreadPopout: Codable, Sendable {
        public var threadId: UUID
        public var windowFrame: CodableRect

        public init(threadId: UUID, windowFrame: CodableRect) {
            self.threadId = threadId
            self.windowFrame = windowFrame
        }
    }

    public struct TabPopout: Codable, Sendable {
        public var threadId: UUID
        public var sessionName: String
        public var windowFrame: CodableRect

        public init(threadId: UUID, sessionName: String, windowFrame: CodableRect) {
            self.threadId = threadId
            self.sessionName = sessionName
            self.windowFrame = windowFrame
        }
    }

    public var threadPopouts: [ThreadPopout]
    public var tabPopouts: [TabPopout]

    public init(threadPopouts: [ThreadPopout] = [], tabPopouts: [TabPopout] = []) {
        self.threadPopouts = threadPopouts
        self.tabPopouts = tabPopouts
    }
}
