import SwiftUI

/// Mirrors iOS layout: full-bleed blurred album art, vertical waveform
/// pinned to the left with padding, scrolls behind a glass header at
/// top and a glass transport at the bottom. Notes pins lay over the
/// right side of the waveform in Phase 3.
struct FullPlayerView: View {
    @Bindable var store: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubProgress: Double?
    @State private var showAudioPicker = false
    @State private var showAddNote = false
    @State private var editingNote: Note?
    @State private var voiceNoteStartTime: Double = 0
    @State private var userScrolling = false
    @State private var resumeAutoScroll: Task<Void, Never>?

    private let speech = SpeechRecognitionService.shared
    private let waveformColumnWidth: CGFloat = 56
    private let waveformLeading: CGFloat = 40
    private let barHeight: CGFloat = 2
    private let autoScrollResumeDelay: Duration = .seconds(2.5)

    var body: some View {
        ZStack {
            blurredBackground
            if let project = store.audio.nowPlaying {
                timeline(project: project)
                    .task(id: project.id) {
                        // Refresh notes from Dropbox when the player opens, and
                        // keep polling the file's rev while it stays open so a
                        // note added on another device shows up live. `play()`
                        // skips loadNotes for an already-loaded song, so without
                        // this the timeline would sit on a stale session cache.
                        // The task is cancelled when the sheet closes or the
                        // song changes.
                        await store.loadNotes(for: project)
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(6))
                            if Task.isCancelled { break }
                            await store.refreshNotesIfChanged(for: project)
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // Header sits in the safe-area inset so the
                        // scroll content extends behind it but doesn't
                        // get cut off at the top of its travel.
                        header(project: project)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            transport(project: project)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 6)
                            timeDisplay
                                .padding(.horizontal, 28)
                                .padding(.bottom, 14)
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 600, idealHeight: 720)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAudioPicker) {
            if let project = store.audio.nowPlaying {
                AudioFilePickerSheet(store: store, project: project)
            }
        }
        .sheet(isPresented: $showAddNote) {
            if let project = store.audio.nowPlaying {
                AddNoteSheet(
                    project: project,
                    store: store,
                    currentTime: store.audio.currentTime
                )
            }
        }
        .sheet(item: $editingNote) { note in
            if let project = store.audio.nowPlaying {
                AddNoteSheet(
                    project: project,
                    store: store,
                    currentTime: note.time,
                    editing: note
                )
            }
        }
        .overlay(alignment: .bottom) {
            if speech.isRecording {
                transcriptBubble
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: speech.isRecording)
    }

    @ViewBuilder
    private var blurredBackground: some View {
        if let project = store.audio.nowPlaying,
           let art = store.albumArt[project.id] {
            GeometryReader { geo in
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(1.4)
                    .blur(radius: 60)
                    .clipped()
            }
            .ignoresSafeArea()
            .overlay(Color.black.opacity(0.45).ignoresSafeArea())
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: - Header

    private func header(project: ProjectReference) -> some View {
        HStack(alignment: .top) {
            Button {
                store.presentingFullPlayer = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .compatGlass(.regularInteractive, in: Circle())
            .padding(.leading, 16)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayTitle)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let version = currentVersionLabel {
                    Text(version)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .tracking(0.4)
                }
            }
            .padding(.top, 14)
            .padding(.leading, 8)

            Spacer(minLength: 0)

            // Star + audio picker combo.
            HStack(spacing: 0) {
                let isStarred = store.starred[project.id] ?? false
                Button {
                    Task { await store.toggleStarred(project) }
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isStarred ? Color.yellow : Color.white.opacity(0.65))
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 0.5, height: 22)

                Button {
                    Task { await store.loadAudioFiles(for: project) }
                    showAudioPicker = true
                } label: {
                    Image(systemName: "tray.full")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .compatGlass(.regularInteractive, in: Capsule())
            .padding(.trailing, 16)
            .padding(.top, 14)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Timeline (vertical waveform, full-bleed scroll)

    private func timeline(project: ProjectReference) -> some View {
        let bars = waveformBars(for: project)
        let totalH = max(720, CGFloat(bars.count) * barHeight)
        let allNotes = store.notes[project.id] ?? []
        let currentVersion = store.audio.currentVersion
        // Strict per-version filter — match iOS behavior. Notes captured
        // against an earlier .als/bounce stay in the file but only show
        // when that version is loaded.
        let projectNotes = allNotes.filter { $0.version == currentVersion }

        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Scroll anchors for auto-follow.
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
                        .padding(.leading, waveformLeading)

                    ForEach(projectNotes) { note in
                        commentPin(note: note, project: project, totalH: totalH)
                    }

                    if projectNotes.isEmpty {
                        Text("Click + to pin a note\nat any moment")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.18))
                            .multilineTextAlignment(.leading)
                            .lineSpacing(2)
                            .position(
                                x: waveformLeading + waveformColumnWidth + 80,
                                y: totalH * 0.45
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: totalH, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .interacting, .tracking, .decelerating:
                    userScrolling = true
                    resumeAutoScroll?.cancel()
                case .idle, .animating:
                    resumeAutoScroll?.cancel()
                    resumeAutoScroll = Task {
                        try? await Task.sleep(for: autoScrollResumeDelay)
                        if !Task.isCancelled {
                            userScrolling = false
                        }
                    }
                @unknown default:
                    break
                }
            }
            .onChange(of: store.audio.currentTime) { _, _ in
                guard scrubProgress == nil,
                      store.audio.isPlaying,
                      store.audio.duration > 0,
                      !userScrolling else { return }
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
            let playedHeight = max(0, CGFloat(progress) * totalH)
            let shape = WaveformShape(bars: bars, maxAmp: 24)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .offset(x: centerX - 0.5)
                    .frame(height: totalH)

                shape
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.26), .white.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: geo.size.width, height: totalH)
                    .allowsHitTesting(false)

                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0),
                                .init(color: Color(red: 0.92, green: 0.96, blue: 1.0), location: max(0.001, progress))
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: geo.size.width, height: totalH)
                    .mask(
                        Rectangle()
                            .frame(width: geo.size.width, height: playedHeight)
                            .frame(width: geo.size.width, height: totalH, alignment: .top)
                    )
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width + 16, height: 2)
                    .offset(x: -8, y: CGFloat(progress) * totalH - 1)
                    .shadow(color: .white.opacity(0.6), radius: 4)
            }
            .frame(width: geo.size.width, height: totalH, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                let pct = max(0, min(1, location.y / totalH))
                store.audio.seek(to: pct * store.audio.duration)
            }
        }
        .frame(width: waveformColumnWidth, height: totalH)
    }

    // MARK: - Transport + time

    private var timeDisplay: some View {
        HStack {
            Text(timecode(displayedTime))
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text("−" + timecode(max(0, store.audio.duration - displayedTime)))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.32))
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func transport(project: ProjectReference) -> some View {
        if speech.isRecording {
            // Recording mode swaps the whole bottom row for a record-stop
            // pair so the user has unambiguous controls.
            HStack {
                Spacer()
                cancelRecordingButton
                Spacer()
                recordingMicButton(project: project)
                Spacer()
            }
        } else {
            CompatGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    trackCombo
                    Spacer(minLength: 8)
                    playPauseButton
                    Spacer(minLength: 8)
                    voiceAndAddCombo
                }
            }
        }
    }

    /// Mic + plus rendered as a single glass capsule, mirroring iOS.
    private var voiceAndAddCombo: some View {
        HStack(spacing: 0) {
            Button {
                startRecording()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 0.5, height: 28)

            Button {
                store.audio.pause()
                showAddNote = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .compatGlass(.regularInteractive, in: Capsule())
    }

    private func recordingMicButton(project: ProjectReference) -> some View {
        Button {
            finishRecording(project: project)
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.red))
                .symbolEffect(.pulse, options: .repeating, isActive: speech.isRecording)
        }
        .buttonStyle(.plain)
    }

    private var cancelRecordingButton: some View {
        Button {
            cancelRecording()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .compatGlass(.regularInteractive, in: Circle())
    }

    private var transcriptBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .symbolEffect(.pulse, options: .repeating, isActive: speech.isRecording)
            Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                .font(.system(size: 14))
                .foregroundStyle(speech.transcript.isEmpty ? .white.opacity(0.5) : .white)
                .multilineTextAlignment(.leading)
                .lineLimit(8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .compatGlass(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Note pins

    private func commentPin(note: Note, project: ProjectReference, totalH: CGFloat) -> some View {
        let duration = store.audio.duration
        let y = duration > 0 ? CGFloat(note.time / duration) * totalH : 0
        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 18, height: 1)
                .padding(.top, 11)

            VStack(alignment: .leading, spacing: 6) {
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
                            let color = NoteTags.color(for: tag)
                            Text(tag)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            // Fit content but cap so long notes don't span the whole
            // window — mirrors iOS readability without iOS's enforced
            // narrow width.
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .compatGlass(
                .regularInteractive,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                if duration > 0 { store.audio.seek(to: note.time) }
            }
            .contextMenu {
                Button {
                    editingNote = note
                } label: {
                    Label("Edit note", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await store.removeNote(note, from: project) }
                } label: {
                    Label("Delete note", systemImage: "trash")
                }
            }
        }
        .padding(.leading, waveformLeading + waveformColumnWidth)
        .offset(y: y - 10)
    }

    // MARK: - Voice note flow

    private func startRecording() {
        Task { @MainActor in
            let granted = await speech.requestPermissions()
            guard granted else {
                // Permission denied → fall back to the text sheet so the
                // tap isn't a dead end.
                store.audio.pause()
                showAddNote = true
                return
            }
            store.audio.pause()
            voiceNoteStartTime = store.audio.currentTime
            do {
                try speech.start()
            } catch {
                // SpeechRecognitionService surfaces nothing on errors yet;
                // open the text sheet as a fallback.
                showAddNote = true
            }
        }
    }

    private func finishRecording(project: ProjectReference) {
        let text = speech.stop()
        guard !text.isEmpty else { return }
        let tags = NoteTags.matches(in: text)
        let note = Note(time: voiceNoteStartTime, text: text, tags: tags)
        Task { await store.addNote(note, to: project) }
    }

    private func cancelRecording() {
        speech.cancel()
    }

    /// Prev / next as one glass capsule with a hairline separator. Each
    /// side is its own tap target.
    private var trackCombo: some View {
        HStack(spacing: 0) {
            Button { Task { await store.playPrevious() } } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 0.5, height: 28)

            Button { Task { await store.playNext() } } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .compatGlass(.regularInteractive, in: Capsule())
    }

    /// `.glassEffect` applied OUTSIDE the Button (not on the Image
    /// inside the label) — when stacked next to other interactive glass
    /// elements, having the effect inside the label causes taps to
    /// register visually but never fire. Square frame → Circle shape.
    private var playPauseButton: some View {
        Button { store.audio.togglePlay() } label: {
            Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .compatGlass(.regularInteractive, in: Circle())
        .keyboardShortcut(.space, modifiers: [])
    }

    // MARK: - Computed

    private var currentVersionLabel: String? {
        guard let parts = store.audio.currentVersion else { return nil }
        return "V" + parts.map(String.init).joined(separator: ".")
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

    private func waveformBars(for project: ProjectReference) -> [Double] {
        if let real = store.waveform.waveforms[project.id] {
            return real.map(Double.init)
        }
        return makeFakeWaveform(seed: seed(for: project), count: WaveformService.barCount)
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

    fileprivate static func waveformPath(bars: [Double], in size: CGSize, maxAmp: CGFloat) -> Path {
        let centerX = size.width / 2
        let count = bars.count
        let stepY = size.height / CGFloat(max(1, count - 1))

        func point(side: CGFloat, index: Int) -> CGPoint {
            let amp = max(1, CGFloat(bars[index]) * maxAmp)
            return CGPoint(x: centerX + side * amp, y: CGFloat(index) * stepY)
        }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        func appendSmoothed(side: CGFloat, indices: [Int], to path: inout Path, startsPath: Bool) {
            guard indices.count >= 2 else { return }
            let pts = indices.map { point(side: side, index: $0) }
            if startsPath { path.move(to: pts[0]) } else { path.addLine(to: pts[0]) }
            if pts.count == 2 { path.addLine(to: pts[1]); return }
            for i in 1..<(pts.count - 1) {
                let mid = midpoint(pts[i], pts[i + 1])
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addLine(to: pts.last!)
        }

        var path = Path()
        appendSmoothed(side: 1, indices: Array(0..<count), to: &path, startsPath: true)
        appendSmoothed(side: -1, indices: Array((0..<count).reversed()), to: &path, startsPath: false)
        path.closeSubpath()
        return path
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

// MARK: - Waveform shape

private struct WaveformShape: Shape {
    let bars: [Double]
    let maxAmp: CGFloat

    func path(in rect: CGRect) -> Path {
        guard bars.count > 1 else { return Path() }
        return FullPlayerView.waveformPath(bars: bars, in: rect.size, maxAmp: maxAmp)
    }
}

// MARK: - Wrap-flow layout for tag chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width + spacing > maxWidth && currentRowWidth > 0 {
                totalHeight += rowHeight + spacing
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
