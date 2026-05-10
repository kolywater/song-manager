import SwiftUI

struct FullPlayerView: View {
    var store: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubProgress: Double? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let project = store.audio.nowPlaying {
                VStack(spacing: 0) {
                    topBar(project: project)
                    waveform(project: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 12)
                    timeDisplay
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    transport
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar

    private func topBar(project: ProjectReference) -> some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Waveform

    private func waveform(project: ProjectReference) -> some View {
        let bars = waveformBars(for: project)
        return GeometryReader { geo in
            let totalH = geo.size.height
            let barH = totalH / CGFloat(bars.count)
            let progress = playbackProgress
            let centerlineX = geo.size.width / 2

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .offset(x: centerlineX - 0.5)

                ForEach(Array(bars.enumerated()), id: \.offset) { idx, amp in
                    let pct = Double(idx) / Double(bars.count)
                    let played = pct < progress
                    let isHead = abs(pct - progress) < (1.0 / Double(bars.count) * 0.6)
                    let halfWidth = max(2, amp * 22)
                    Rectangle()
                        .fill(barColor(played: played, isHead: isHead))
                        .frame(width: halfWidth * 2, height: max(1.5, barH - 1.5))
                        .position(x: centerlineX, y: CGFloat(idx) * barH + barH / 2)
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width + 16, height: 2)
                    .offset(x: -8, y: CGFloat(progress) * totalH - 1)
                    .shadow(color: .white.opacity(0.6), radius: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubProgress = max(0, min(1, value.location.y / totalH))
                    }
                    .onEnded { value in
                        let pct = max(0, min(1, value.location.y / totalH))
                        store.audio.seek(to: pct * store.audio.duration)
                        scrubProgress = nil
                    }
            )
        }
        .padding(.horizontal, 20)
    }

    private func barColor(played: Bool, isHead: Bool) -> Color {
        if isHead { return .white }
        return played ? Color.white.opacity(0.85) : Color.white.opacity(0.18)
    }

    private func waveformBars(for project: ProjectReference) -> [Double] {
        if let real = store.waveform.waveforms[project.id] {
            return real.map(Double.init)
        }
        return makeFakeWaveform(seed: seed(for: project), count: WaveformService.barCount)
    }

    private var playbackProgress: Double {
        if let scrubProgress { return scrubProgress }
        guard store.audio.duration > 0 else { return 0 }
        return min(1, max(0, store.audio.currentTime / store.audio.duration))
    }

    private var displayedTime: Double {
        if let scrubProgress { return scrubProgress * store.audio.duration }
        return store.audio.currentTime
    }

    // MARK: - Time display

    private var timeDisplay: some View {
        HStack {
            Text(timecode(displayedTime))
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer()
            Text("−" + timecode(max(0, store.audio.duration - displayedTime)))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.32))
        }
        .monospacedDigit()
    }

    // MARK: - Transport

    private var transport: some View {
        HStack {
            Spacer()
            skipButton(seconds: -10, systemImage: "gobackward.10")
            Spacer()
            playPauseButton
            Spacer()
            skipButton(seconds: 10, systemImage: "goforward.10")
            Spacer()
        }
    }

    private var playPauseButton: some View {
        Button {
            store.audio.togglePlay()
        } label: {
            Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: 64, height: 64)
                .background(Circle().fill(.white))
                .shadow(color: .white.opacity(0.18), radius: 14, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func skipButton(seconds: Double, systemImage: String) -> some View {
        Button {
            store.audio.skip(by: seconds)
        } label: {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private func seed(for project: ProjectReference) -> UInt32 {
        let bytes = project.id.uuid
        return UInt32(bytes.0) | (UInt32(bytes.1) << 8) | (UInt32(bytes.2) << 16) | (UInt32(bytes.3) << 24)
    }

    private func makeFakeWaveform(seed: UInt32, count: Int) -> [Double] {
        var s = seed == 0 ? 1 : seed
        let next: () -> Double = {
            s = s &* 1664525 &+ 1013904223
            return Double(s) / Double(UInt32.max)
        }
        return (0..<count).map { i in
            let envelope = sin(Double(i) / Double(count) * .pi) * 0.52 + 0.18
            let jitter = (next() - 0.5) * 0.55
            return max(0.05, min(1, envelope + jitter))
        }
    }
}
