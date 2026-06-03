import Foundation

/// A grouped slice of the home grid. The store computes the full list of
/// sections in display order (starred-first, then in-progress, released,
/// idle), and the view layer renders one `Section` per non-empty entry.
struct ProjectSection: Identifiable {
    enum Kind: Hashable {
        /// Cross-status starred bucket that floats above all status
        /// groups. Only rendered when at least one song is starred.
        case starred
        case status(SongStatus)
    }

    let kind: Kind
    let projects: [ProjectReference]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .starred:           return "Starred"
        case .status(let s):     return s.displayName
        }
    }

    var systemImage: String {
        switch kind {
        case .starred:           return "star.fill"
        case .status(let s):     return s.systemImage
        }
    }
}
