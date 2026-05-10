import Foundation
import SwiftUI

struct NoteTagCategory {
    let name: String
    let tags: [String]
}

enum NoteTags {
    static let categories: [NoteTagCategory] = [
        NoteTagCategory(name: "Instrument", tags: ["vox", "synth", "strings", "keys", "bass", "sub", "drums"]),
        NoteTagCategory(name: "Mixing", tags: ["eq", "compression", "volume", "saturation", "reverb/delay"]),
        NoteTagCategory(name: "Structure", tags: ["arrangement", "outro", "intro", "verse", "pc", "chorus", "bridge"])
    ]

    /// Spoken aliases that should resolve to a canonical tag during
    /// transcription matching. The canonical tag is the dictionary key.
    private static let spokenAliases: [String: [String]] = [
        "vox": ["vocals", "vocal"]
    ]

    static var allTags: [String] { categories.flatMap(\.tags) }

    /// Color associated with a tag. Instruments get distinct hues;
    /// Mixing sweeps green→blue across its chips; Structure sweeps
    /// orange→yellow.
    static func color(for tag: String) -> Color {
        if let c = instrumentColors[tag] { return c }
        if let i = categories.first(where: { $0.name == "Mixing" })?.tags.firstIndex(of: tag) {
            return mixingPalette[i]
        }
        if let i = categories.first(where: { $0.name == "Structure" })?.tags.firstIndex(of: tag) {
            return structurePalette[i]
        }
        return Color.white.opacity(0.5)
    }

    private static let instrumentColors: [String: Color] = [
        "bass":    Color(red: 0.659, green: 0.333, blue: 0.969), // purple
        "strings": Color(red: 0.502, green: 0.890, blue: 0.643), // light green
        "sub":     Color(red: 0.486, green: 0.227, blue: 0.929), // deep violet
        "vox":     Color(red: 0.933, green: 1.000, blue: 0.255), // neon yellow
        "drums":   Color(red: 1.000, green: 0.549, blue: 0.259), // orange
        "synth":   Color(red: 0.176, green: 0.831, blue: 0.643), // vibrant teal-green
        "keys":    Color(red: 0.078, green: 0.722, blue: 0.651)  // teal
    ]

    /// 5 stops, green → blue (eq, compression, volume, saturation, reverb/delay).
    private static let mixingPalette: [Color] = [
        Color(red: 0.169, green: 0.851, blue: 0.447),
        Color(red: 0.145, green: 0.741, blue: 0.557),
        Color(red: 0.161, green: 0.627, blue: 0.710),
        Color(red: 0.176, green: 0.506, blue: 0.863),
        Color(red: 0.200, green: 0.400, blue: 1.000)
    ]

    /// 7 stops, orange → yellow (array order: arrangement, outro, intro, verse, pc, chorus, bridge).
    private static let structurePalette: [Color] = [
        Color(red: 1.000, green: 0.478, blue: 0.200),
        Color(red: 1.000, green: 0.576, blue: 0.200),
        Color(red: 1.000, green: 0.667, blue: 0.200),
        Color(red: 1.000, green: 0.757, blue: 0.200),
        Color(red: 1.000, green: 0.827, blue: 0.200),
        Color(red: 1.000, green: 0.886, blue: 0.200),
        Color(red: 1.000, green: 0.925, blue: 0.200)
    ]

    /// Whole-word, case-insensitive scan of `transcript` for known tag terms.
    /// A tag like "reverb/delay" matches if either alias appears, and
    /// `spokenAliases` adds extra synonyms for transcription matching
    /// (e.g. "vocals" → "vox").
    static func matches(in transcript: String) -> [String] {
        let lower = transcript.lowercased()
        var found = Set<String>()
        for tag in allTags {
            var aliases = tag.split(separator: "/").map(String.init)
            if let extras = spokenAliases[tag] {
                aliases.append(contentsOf: extras)
            }
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
