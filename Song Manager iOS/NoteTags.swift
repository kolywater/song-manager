import Foundation

struct NoteTagCategory {
    let name: String
    let tags: [String]
}

enum NoteTags {
    static let categories: [NoteTagCategory] = [
        NoteTagCategory(name: "Instrument", tags: ["bass", "strings", "sub", "vox", "drums", "synth", "keys"]),
        NoteTagCategory(name: "Mixing", tags: ["eq", "compression", "volume", "saturation", "reverb/delay"]),
        NoteTagCategory(name: "Structure", tags: ["arrangement", "outro", "intro", "verse", "pc", "chorus", "bridge"])
    ]

    static var allTags: [String] { categories.flatMap(\.tags) }

    /// Whole-word, case-insensitive scan of `transcript` for known tag terms.
    /// A tag like "reverb/delay" matches if either alias appears.
    static func matches(in transcript: String) -> [String] {
        let lower = transcript.lowercased()
        var found = Set<String>()
        for tag in allTags {
            let aliases = tag.split(separator: "/").map(String.init)
            for alias in aliases {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: alias) + "\\b"
                if lower.range(of: pattern, options: .regularExpression) != nil {
                    found.insert(tag)
                    break
                }
            }
        }
        return Array(found).sorted()
    }
}
