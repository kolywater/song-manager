import SwiftUI

/// Variants of the project's "glass material" abstraction. On macOS 26+
/// these map to Liquid Glass; on macOS 15 they fall back to standard
/// frosted Materials. iOS keeps using `.glassEffect` directly — only the
/// Mac target needs to compile on macOS 15.
enum GlassVariant {
    /// Most translucent. Refractive media-overlay glass — used over
    /// album art / waveforms.
    case clear
    /// Standard opaque-ish glass control — used for transcripts and
    /// other content surfaces.
    case regular
    /// Same as `.regular` but with hover/press states on macOS 26.
    /// Falls back to `.regular` on macOS 15 (no hover effect).
    case regularInteractive
}

extension View {
    /// Liquid Glass on macOS 26+, standard frosted Material on macOS 15.
    /// `.clear` → `.ultraThinMaterial`; `.regular` /
    /// `.regularInteractive` → `.regularMaterial`. Same shape on both
    /// paths so the control's silhouette stays identical.
    @ViewBuilder
    func compatGlass(_ variant: GlassVariant, in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(variant.liquidGlass, in: shape)
        } else {
            self.background(variant.material, in: shape)
        }
    }
}

private extension GlassVariant {
    @available(macOS 26.0, *)
    var liquidGlass: Glass {
        switch self {
        case .clear:              return .clear
        case .regular:            return .regular
        case .regularInteractive: return .regular.interactive()
        }
    }

    var material: Material {
        switch self {
        case .clear:                              return .ultraThinMaterial
        case .regular, .regularInteractive:       return .regularMaterial
        }
    }
}

/// Liquid Glass morph container on macOS 26+, plain pass-through on
/// macOS 15 (Materials don't morph). Use this for any group of glass
/// shapes that should visually merge — single shapes don't need it.
struct CompatGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}
