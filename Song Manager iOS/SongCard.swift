import SwiftUI

struct SongCard: View {
    let project: ProjectReference
    var store: SongStore

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artLayer }
            .overlay(alignment: .bottom) { pillOverlay }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .task(id: project.id) {
                await store.loadAlbumArt(for: project)
            }
    }

    private var pillOverlay: some View {
        let fg = pillForeground
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if let version = project.latestVersionString {
                    Text(version.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(fg.opacity(0.75))
                        .tracking(0.5)
                }
                Text(project.displayTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await store.play(project, autoStart: true, showPlayer: false) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(fg)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(fg.opacity(0.22)))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(8)
    }

    /// Black if the artwork is light overall; white otherwise.
    private var pillForeground: Color {
        let lum = store.artLuminance[project.id] ?? 0
        return lum > 0.45 ? .black : .white
    }

    @ViewBuilder
    private var artLayer: some View {
        if let image = store.albumArt[project.id] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.55),
                    Color(hue: hue, saturation: 0.45, brightness: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.18))
        }
    }

    private var hue: Double {
        if let h = project.gradientHue { return h }
        // Stable across launches — UUID's first byte. (hashValue is randomized.)
        return Double(project.id.uuid.0) / 256.0
    }

    private var initial: String {
        String(project.displayName.first.map { String($0) } ?? "·").uppercased()
    }
}
