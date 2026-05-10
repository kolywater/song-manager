import Foundation

/// Compile-time scaffolding for fast iteration on specific screens.
/// Flip flags here when you want to skip the normal launch flow; set
/// them all back to false for production-shaped behavior.
enum DevHarness {
    /// When true, the app jumps straight into the FullPlayerView for
    /// the first song in the registry as soon as it loads. Useful for
    /// iterating on player styling without tapping through every time.
    static let autoOpenPlayer = false
}
