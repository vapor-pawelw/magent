import Cocoa
import MagentCore

enum OpenActionIcons {
    static func finderIcon(size: CGFloat) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        return image
    }

    static func pullRequestIcon(for provider: GitHostingProvider, size: CGFloat) -> NSImage {
        if let image = hostingProviderIcon(for: provider, size: size) {
            return image
        }

        return NSImage(
            systemSymbolName: "arrow.up.right.square",
            accessibilityDescription: "Open Pull Request"
        ) ?? NSImage()
    }

    static func hostingProviderIcon(for provider: GitHostingProvider, size: CGFloat) -> NSImage? {
        let imageName: String?
        switch provider {
        case .github:
            imageName = "RepoHostGitHub"
        case .gitlab:
            imageName = "RepoHostGitLab"
        case .bitbucket:
            imageName = "RepoHostBitbucket"
        case .unknown:
            imageName = nil
        }

        guard let imageName, let baseImage = NSImage(named: NSImage.Name(imageName)) else { return nil }
        let sourceImage = (baseImage.copy() as? NSImage) ?? baseImage
        sourceImage.size = NSSize(width: size, height: size)

        if provider == .github {
            // GitHub's mark needs a light badge to stay visible in dark appearances.
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
                let rect = NSRect(origin: .zero, size: NSSize(width: size, height: size))
                let background = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: max(2, size / 4),
                    yRadius: max(2, size / 4)
                )
                NSColor.white.setFill()
                background.fill()
                NSColor.black.withAlphaComponent(0.16).setStroke()
                background.lineWidth = 1
                background.stroke()

                sourceImage.draw(
                    in: rect.insetBy(dx: max(1, size * 0.125), dy: max(1, size * 0.125)),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                return true
            }
            image.isTemplate = false
            return image
        }

        sourceImage.isTemplate = false
        return sourceImage
    }
}
