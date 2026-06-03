import Foundation

/// Per-song workflow state, shown as the top-level grouping on the home
/// grid. The declaration order here is the on-screen group order:
/// in-progress first, released next, idle last — so `.allCases` doubles
/// as the section ordering. Unset (nil) resolves to `.inProgress`
/// everywhere it's read, which is how legacy songs migrate silently
/// when this field rolls out.
enum SongStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case inProgress
    case prepForRelease
    case released
    case idle

    var id: Self { self }

    var displayName: String {
        switch self {
        case .inProgress:     return "In Progress"
        case .prepForRelease: return "Prep for Release"
        case .released:       return "Released"
        case .idle:           return "Idle"
        }
    }

    var systemImage: String {
        switch self {
        case .inProgress:     return "hammer.fill"
        case .prepForRelease: return "shippingbox.fill"
        case .released:       return "checkmark.seal.fill"
        case .idle:           return "moon.zzz.fill"
        }
    }
}
