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

    /// Tags only emitted by voice transcription matching; not surfaced
    /// in the manual tag picker. They still render with their own
    /// colors when they appear on a note.
    static let voiceOnlyTags: [String] = ["pads", "snare", "kick", "hi-hat", "percussion"]

    /// Spoken aliases that should resolve to a canonical tag during
    /// transcription matching. Plural forms are handled automatically
    /// by the matcher's `(s|es)?` suffix, so list singulars / variants
    /// only.
    private static let spokenAliases: [String: [String]] = [
        "vox": ["vocals", "vocal"],
        "compression": ["compressor", "compressing"],
        "saturation": ["saturator", "saturate"],
        "volume": ["vol"],
        "reverb/delay": ["verb"],
        "arrangement": ["arr"],
        "pc": ["pre-chorus", "prechorus"],
        "pads": ["pad"],
        "kick": ["kicker"],
        "hi-hat": ["hihat", "hat"],
        "percussion": ["perc"]
    ]

    static var allTags: [String] { categories.flatMap(\.tags) }

    /// Tags eligible for transcription auto-match — visible UI tags
    /// plus the voice-only set.
    private static var matchableTags: [String] { allTags + voiceOnlyTags }

    /// Color associated with a tag. Instruments get distinct hues;
    /// Mixing sweeps green→blue across its chips; Structure sweeps
    /// orange→yellow.
    static func color(for tag: String) -> Color {
        if let c = instrumentColors[tag] { return c }
        if let c = voiceOnlyColors[tag] { return c }
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

    /// Drum-kit pieces sit in an orange family alongside `drums`;
    /// `pads` lands on a soft lavender that contrasts with synth teal.
    private static let voiceOnlyColors: [String: Color] = [
        "snare":      Color(red: 1.000, green: 0.620, blue: 0.290), // peach
        "kick":       Color(red: 0.929, green: 0.404, blue: 0.184), // deep orange
        "hi-hat":     Color(red: 1.000, green: 0.706, blue: 0.353), // gold
        "percussion": Color(red: 0.847, green: 0.498, blue: 0.227), // warm bronze
        "pads":       Color(red: 0.667, green: 0.553, blue: 0.929)  // lavender
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

    /// Whole-word, case-insensitive scan of `transcript` for known tag
    /// terms. Scans both `categories` (UI tags) and `voiceOnlyTags`. A
    /// tag like "reverb/delay" matches if either alias appears, and
    /// `spokenAliases` adds extra synonyms. Each alias is tested as
    /// `\b{alias}(s|es)?\b` so plural forms ("synths", "choruses",
    /// "kicks", "hi-hats") match without per-word listing.
    static func matches(in transcript: String) -> [String] {
        let lower = transcript.lowercased()
        var found = Set<String>()
        for tag in matchableTags {
            var aliases = tag.split(separator: "/").map(String.init)
            if let extras = spokenAliases[tag] {
                aliases.append(contentsOf: extras)
            }
            for alias in aliases {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: alias) + "(s|es)?\\b"
                if lower.range(of: pattern, options: .regularExpression) != nil {
                    found.insert(tag)
                    break
                }
            }
        }
        return Array(found).sorted()
    }
}
