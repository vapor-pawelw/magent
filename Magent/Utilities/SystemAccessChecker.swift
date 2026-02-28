import Foundation

nonisolated enum SystemAccessChecker {

    static func isFullDiskAccessGranted() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probePath = home.appendingPathComponent("Library/Containers/com.apple.stocks").path
        if (try? FileManager.default.contentsOfDirectory(atPath: probePath)) != nil {
            return true
        }
        let safariPath = home.appendingPathComponent("Library/Safari/History.db").path
        return FileManager.default.isReadableFile(atPath: safariPath)
    }

    static func systemSoundNames() -> [String] {
        let soundsDir = "/System/Library/Sounds"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) else {
            return ["Tink"]
        }
        return contents
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
