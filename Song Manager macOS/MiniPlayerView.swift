import SwiftUI

/// Bottom-of-window mini player. Mirrors iOS: clear glass capsule, white
/// text (reads consistently regardless of what's behind the glass), art
/// thumbnail, title + timecode, play/pause, dismiss. Tap anywhere except
/// the transport buttons to open the full player.
struct MiniPlayerView: View {
    @Bindable var store: SongStore

    var body: some View {
        if let project = store.audio.nowPlaying {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    artwork(for: project)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.displayTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if store.audio.duration > 0 {
                            Text(timecode(store.audio.currentTime) + " / " + timecode(store.audio.duration))
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
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

                Button {
                    store.audio.togglePlay()
                } label: {
                    Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    store.audio.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .glassEffect(.clear, in: Capsule())
            .frame(maxWidth: 600)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func artwork(for project: ProjectReference) -> some View {
        if let nsImage = store.albumArt[project.id] {
            Image(nsImage: nsImage)
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
