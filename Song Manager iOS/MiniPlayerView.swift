import SwiftUI

struct MiniPlayerView: View {
    var store: SongStore

    var body: some View {
        if let project = store.audio.nowPlaying {
            HStack(spacing: 12) {
                artwork(for: project)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if store.audio.duration > 0 {
                        Text(timecode(store.audio.currentTime) + " / " + timecode(store.audio.duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 8)

                Button {
                    store.audio.togglePlay()
                } label: {
                    Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    store.audio.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
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
