import SwiftUI

struct MiniPlayerView: View {
    var store: SongStore

    var body: some View {
        if let project = store.audio.nowPlaying {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    HStack(spacing: 12) {
                        artwork(for: project)
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if store.audio.duration > 0 {
                                Text(timecode(store.audio.currentTime) + " / " + timecode(store.audio.duration))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
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

                ScrubBar(progress: progress) { pct in
                    store.audio.seek(to: pct * store.audio.duration)
                }
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

    private var progress: Double {
        guard store.audio.duration > 0 else { return 0 }
        return min(1, max(0, store.audio.currentTime / store.audio.duration))
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

private struct ScrubBar: View {
    var progress: Double
    var onScrub: (Double) -> Void
    @State private var dragProgress: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let displayProgress = dragProgress ?? progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: max(0, geo.size.width * displayProgress))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = max(0, min(1, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        let pct = max(0, min(1, value.location.x / geo.size.width))
                        onScrub(pct)
                        dragProgress = nil
                    }
            )
        }
        .frame(height: 3)
    }
}
