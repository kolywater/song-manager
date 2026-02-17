import SwiftUI

struct PlayerBarView: View {
    @Bindable var player: AudioPlayer
    @State private var showingTrackPicker = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { player.togglePlayPause() }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { showingTrackPicker.toggle() }) {
                HStack(spacing: 4) {
                    Text(player.trackName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if player.bounceFiles.count > 1 {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingTrackPicker, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(player.bounceFiles.reversed(), id: \.self) { file in
                        let name = file.deletingPathExtension().lastPathComponent
                        let isCurrent = file == player.currentURL
                        Button {
                            showingTrackPicker = false
                            if !isCurrent {
                                player.switchTrack(to: file)
                            }
                        } label: {
                            HStack {
                                Text(name)
                                    .font(.system(size: 13))
                                    .fontWeight(isCurrent ? .semibold : .regular)
                                    .lineLimit(1)
                                Spacer()
                                if isCurrent {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .frame(minWidth: 240)
            }

            Slider(
                value: $player.currentTime,
                in: 0...(max(player.duration, 1)),
                onEditingChanged: { editing in
                    if !editing {
                        player.seek(to: player.currentTime)
                    }
                }
            )

            Text(formatTime(player.currentTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Button(action: { player.isLooping.toggle() }) {
                Image(systemName: "repeat")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .foregroundStyle(player.isLooping ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            Button(action: { player.stop() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
