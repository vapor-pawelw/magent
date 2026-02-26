import Foundation

final class PersistenceService {

    static let shared = PersistenceService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var appSupportURL: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Magent", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var threadsURL: URL {
        appSupportURL.appendingPathComponent("threads.json")
    }

    private var settingsURL: URL {
        appSupportURL.appendingPathComponent("settings.json")
    }

    // MARK: - Threads

    func loadThreads() -> [MagentThread] {
        guard let data = try? Data(contentsOf: threadsURL) else { return [] }
        return (try? decoder.decode([MagentThread].self, from: data)) ?? []
    }

    func saveThreads(_ threads: [MagentThread]) throws {
        let data = try encoder.encode(threads)
        try data.write(to: threadsURL, options: .atomic)
    }

    // MARK: - Settings

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        let settings = (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()

        // Ensure default threadSections are persisted so their UUIDs are stable.
        // If the JSON doesn't contain "threadSections", the decoder generated fresh
        // defaults — save them so subsequent loads return the same UUIDs.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["threadSections"] == nil {
            try? saveSettings(settings)
        }

        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }
}
