import SwiftUI

struct FullPlayerView: View {
    var store: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubProgress: Double? = nil
    @State private var showAddNote: Bool = false

    private let waveformColumnWidth: CGFloat = 56
    private let barHeight: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let project = store.audio.nowPlaying {
                VStack(spacing: 0) {
                    topBar(project: project)
                    timeline(project: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    timeDisplay
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    transport
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
                .sheet(isPresented: $showAddNote) {
                    AddNoteSheet(
                        project: project,
                        store: store,
                        currentTime: store.audio.currentTime
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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

            Text(project.displayName)
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Timeline (waveform + pins)

    private func timeline(project: ProjectReference) -> some View {
        let bars = waveformBars(for: project)
        let projectNotes = store.notes[project.id] ?? []
        let totalH = max(720, CGFloat(bars.count) * barHeight)

        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Hidden anchors — let us scroll to a fractional position by id.
                    VStack(spacing: 0) {
                        ForEach(0..<100, id: \.self) { i in
                            Color.clear
                                .frame(height: totalH / 100)
                                .id("a-\(i)")
                        }
                    }
                    .frame(width: 1)

                    waveformColumn(bars: bars, totalH: totalH, project: project)
                        .frame(width: waveformColumnWidth)

                    ForEach(projectNotes) { note in
                        commentPin(note: note, totalH: totalH)
                    }

                    if projectNotes.isEmpty {
                        Text("Tap + to pin a note\nat any moment")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.18))
                            .multilineTextAlignment(.leading)
                            .lineSpacing(2)
                            .position(
                                x: waveformColumnWidth + 80,
                                y: totalH * 0.45
                            )
                    }
                }
                .frame(height: totalH + 80, alignment: .top)
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .onChange(of: store.audio.currentTime) { _, _ in
                guard scrubProgress == nil,
                      store.audio.isPlaying,
                      store.audio.duration > 0 else { return }
                let pct = store.audio.currentTime / store.audio.duration
                let bucket = min(99, max(0, Int(pct * 100)))
                withAnimation(.linear(duration: 0.4)) {
                    proxy.scrollTo("a-\(bucket)", anchor: .center)
                }
            }
        }
    }

    private func waveformColumn(bars: [Double], totalH: CGFloat, project: ProjectReference) -> some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let progress = playbackProgress
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .offset(x: centerX - 0.5)
                    .frame(height: totalH)

                ForEach(Array(bars.enumerated()), id: \.offset) { idx, amp in
                    let pct = Double(idx) / Double(bars.count)
                    let played = pct < progress
                    let isHead = abs(pct - progress) < (1.0 / Double(bars.count) * 0.6)
                    let halfWidth = max(2, amp * 22)
                    Rectangle()
                        .fill(barColor(played: played, isHead: isHead))
                        .frame(width: halfWidth * 2, height: max(1.5, barHeight - 1.5))
                        .position(x: centerX, y: CGFloat(idx) * barHeight + barHeight / 2)
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width + 16, height: 2)
                    .offset(x: -8, y: CGFloat(progress) * totalH - 1)
                    .shadow(color: .white.opacity(0.6), radius: 4)
            }
            .frame(width: geo.size.width, height: totalH, alignment: .topLeading)
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
        .frame(width: waveformColumnWidth, height: totalH)
    }

    private func commentPin(note: Note, totalH: CGFloat) -> some View {
        let duration = store.audio.duration
        let y = duration > 0 ? CGFloat(note.time / duration) * totalH : 0
        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 18, height: 1)
                .padding(.top, 11)
            Button {
                if duration > 0 {
                    store.audio.seek(to: note.time)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timecode(note.time))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(0.4)
                    Text(note.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                    if !note.tags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(note.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, waveformColumnWidth)
        .offset(y: y - 10)
    }

    private func barColor(played: Bool, isHead: Bool) -> Color {
        if isHead { return .white }
        return played ? Color.white.opacity(0.85) : Color.white.opacity(0.18)
    }

    // MARK: - Computed

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

    // MARK: - Time + transport

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

    private var transport: some View {
        HStack {
            Spacer()
            skipButton(seconds: -10, systemImage: "gobackward.10")
            Spacer()
            playPauseButton
            Spacer()
            skipButton(seconds: 10, systemImage: "goforward.10")
            Spacer()
            addNoteButton
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
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
    }

    private var addNoteButton: some View {
        Button {
            store.audio.pause()
            showAddNote = true
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, height: 40)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
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

// MARK: - Wrap-flow layout for tag chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width + spacing > maxWidth && currentRowWidth > 0 {
                totalHeight += rowHeight + spacing
                rows.append(currentRowWidth)
                currentRowWidth = 0
                rowHeight = 0
            }
            currentRowWidth += size.width + (currentRowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
