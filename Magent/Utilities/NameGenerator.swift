import Foundation

enum NameGenerator {

    private static let adjectives = [
        "swift", "bright", "calm", "dark", "eager", "fair", "glad", "hazy",
        "keen", "lush", "mild", "neat", "odd", "pale", "quick", "rare",
        "sharp", "tall", "vast", "warm", "bold", "crisp", "deep", "fine",
        "gold", "high", "iron", "jade", "kind", "lean", "moss", "nova",
    ]

    private static let nouns = [
        "falcon", "brook", "cedar", "delta", "ember", "frost", "grove", "haven",
        "inlet", "jewel", "knoll", "larch", "maple", "nexus", "orbit", "pearl",
        "quill", "ridge", "shore", "thorn", "umbra", "vault", "whale", "xenon",
        "birch", "coral", "dusk", "fern", "gale", "heron", "ivory", "junco",
    ]

    /// Generates a name like "swift-falcon"
    static func generate() -> String {
        let adj = adjectives.randomElement()!
        let noun = nouns.randomElement()!
        return "\(adj)-\(noun)"
    }
}
