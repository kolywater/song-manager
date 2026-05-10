import SwiftUI

struct MiniPlayerView: View {
    var store: SongStore

    var body: some View {
        if let project = store.audio.nowPlaying {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    artwork(for: project)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.displayTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if store.audio.duration > 0 {
                            Text(timecode(store.audio.currentTime) + " / " + timecode(store.audio.duration))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.presentingFullPlayer = true
                }

                Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.primary.opacity(0.10)))
                    .contentShape(Circle())
                    .highPriorityGesture(
                        TapGesture().onEnded { store.audio.togglePlay() }
                    )

                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                    .highPriorityGesture(
                        TapGesture().onEnded { store.audio.stop() }
                    )
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .glassEffect(.clear, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func artwork(for project: ProjectReference) -> some View {
        if let image = store.albumArt[project.id] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
