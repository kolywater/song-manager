import SwiftUI

struct SongCard: View {
    let project: ProjectReference
    var store: SongStore

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artLayer }
            .overlay(alignment: .topLeading) { titleOverlay }
            // .overlay(alignment: .bottom) { pillOverlay }  // hidden — replaced by titleOverlay
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                Task { await store.play(project) }
            }
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

            Image(systemName: "play.fill")
                .font(.system(size: 11))
                .foregroundStyle(fg)
                .frame(width: 30, height: 30)
                .background(Circle().fill(fg.opacity(0.22)))
                .contentShape(Circle())
                .highPriorityGesture(
                    TapGesture().onEnded {
                        Task { await store.play(project, autoStart: true, showPlayer: false) }
                    }
                )
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(store.artTintColor[project.id]), in: Capsule())
        .padding(8)
    }

    private var pillForeground: Color { .white }

    private var titleOverlay: some View {
        Text(project.displayTitle)
            .font(.system(size: 28, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 18)
            .padding(.horizontal, 20)
            .allowsHitTesting(false)
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
