import SwiftUI

struct FullPlayerView: View {
    var store: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubProgress: Double? = nil
    @State private var showAddNote: Bool = false
    @State private var editingNote: Note?
    private let speech = FluidAudioASRService.shared
    @State private var voiceNoteStartTime: Double = 0
    @State private var showAudioPicker: Bool = false
    /// Suppresses auto-scroll while the user is interacting with the
    /// scroll view (and for a grace period after they let go), so manual
    /// scrolling isn't fought by the playback follow-along.
    @State private var userScrolling: Bool = false
    @State private var resumeAutoScroll: Task<Void, Never>?

    /// -10/+10 skip buttons are hidden for now in favor of the voice-note
    /// flow. Kept in the source so it's a one-line flip to bring them back.
    private let showSkipButtons: Bool = false

    private let waveformColumnWidth: CGFloat = 56
    /// Vertical pixels per waveform sample — smaller = denser silhouette.
    /// 2pt × 600 samples ≈ 1200pt of scroll, matching the previous
    /// 8pt × 150 layout while quadrupling on-screen detail.
    private let barHeight: CGFloat = 2
    private let autoScrollResumeDelay: Duration = .seconds(2.5)

    var body: some View {
        NavigationStack {
            ZStack {
                blurredBackground
                if let project = store.audio.nowPlaying {
                    timeline(project: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            // Transport floats over the scroll view; the
                            // timecode row sits beneath it at the screen's
                            // bottom edge. safeAreaInset gives the scroll
                            // content the bottom padding it needs to clear
                            // these at the end while letting earlier
                            // content scroll past (behind) the glass.
                            VStack(spacing: 0) {
                                if speech.isRecording || speech.isLoadingModel || speech.lastErrorMessage != nil {
                                    HStack {
                                        Spacer()
                                        transcriptBubble
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 10)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                                transport(project: project)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                timeDisplay
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 8)
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(store.audio.nowPlaying?.displayTitle ?? "")
            .navigationSubtitle(currentVersionLabel ?? "")
            .toolbarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { playerToolbarContent }
            .animation(.easeInOut(duration: 0.2), value: speech.isRecording)
            .animation(.easeInOut(duration: 0.2), value: speech.isLoadingModel)
            .sheet(isPresented: $showAudioPicker) {
                if let project = store.audio.nowPlaying {
                    AudioFilePickerSheet(project: project, store: store)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showAddNote) {
                if let project = store.audio.nowPlaying {
                    AddNoteSheet(
                        project: project,
                        store: store,
                        currentTime: store.audio.currentTime
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Toolbar items for the player. Star + audio source render together
    /// as a single Liquid Glass group on the trailing edge; close stands
    /// alone as its own item (still trailing, sits closer to the edge).
    @ToolbarContentBuilder
    private var playerToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
            }
        }
        if let project = store.audio.nowPlaying {
            let isStarred = store.starred[project.id] ?? false
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await store.toggleStarred(project) }
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .foregroundStyle(isStarred ? Color.yellow : .primary)
                }
                Button {
                    showAudioPicker = true
                } label: {
                    Image(systemName: "tray.full")
                }
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var blurredBackground: some View {
        if let project = store.audio.nowPlaying,
           let art = store.albumArt[project.id] {
            GeometryReader { geo in
                Image(uiImage: art)
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

    private var currentVersionLabel: String? {
        guard let parts = store.audio.currentVersion else { return nil }
        return "V" + parts.map(String.init).joined(separator: ".")
    }

    // MARK: - Timeline (waveform + pins)

    private func timeline(project: ProjectReference) -> some View {
        let bars = waveformBars(for: project)
        let allNotes = store.notes[project.id] ?? []
        let currentVersion = store.audio.currentVersion
        // Strict per-version display: only show notes captured against the
        // currently loaded bounce. Earlier versions stay in the file but
        // are hidden until a future version selector is added.
        let projectNotes = allNotes.filter { $0.version == currentVersion }
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
                        commentPin(note: note, project: project, totalH: totalH)
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

                // Unplayed silhouette — soft top-to-bottom fade so the
                // future portion of the song reads as faded glass.
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.26),
                                .white.opacity(0.10)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: geo.size.width, height: totalH)
                    .allowsHitTesting(false)

                // Played silhouette — full-canvas gradient that peaks
                // at the playhead, then masked to the played region.
                // Stops anchored at `progress` keep the brightest
                // band glued to the moving playhead.
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

    /// Build a closed waveform shape with smoothed edges. Each side of
    /// the waveform is traced as a series of quadratic curves between
    /// midpoints of adjacent samples — this softens the jagged
    /// straight-line silhouette into something that reads as an organic
    /// envelope.
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

        // Walk one edge of the waveform using midpoint smoothing:
        // line from midpoint(i-1,i) curving through anchor at index i to
        // midpoint(i,i+1). Endpoints anchor at the first/last sample.
        func appendSmoothed(side: CGFloat, indices: [Int], to path: inout Path, startsPath: Bool) {
            guard indices.count >= 2 else { return }
            let pts = indices.map { point(side: side, index: $0) }

            if startsPath {
                path.move(to: pts[0])
            } else {
                path.addLine(to: pts[0])
            }

            if pts.count == 2 {
                path.addLine(to: pts[1])
                return
            }

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                if duration > 0 { store.audio.seek(to: note.time) }
            }
            // `contextMenu(menuItems:preview:)` lifts the preview view
            // onto its own layer over a dimmed backdrop, giving the
            // menu buttons clear hit isolation from the underlying
            // note pin's interactive glass — which was the cause of
            // the "buttons hard to press" problem when we relied on
            // the plain `.contextMenu(menuItems:)` form.
            .contextMenu(menuItems: {
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
            }, preview: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(timecode(note.time))
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.6))
                        .tracking(0.4)
                    Text(note.text)
                        .font(.body)
                        .foregroundStyle(.white)
                    if !note.tags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(note.tags, id: \.self) { tag in
                                let color = NoteTags.color(for: tag)
                                Text(tag)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(color)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(color.opacity(0.18))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 300, alignment: .leading)
                .background(Color(white: 0.12))
            })
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

    @ViewBuilder
    private func transport(project: ProjectReference) -> some View {
        if speech.isRecording {
            recordingTransport(project: project)
        } else {
            idleTransport
        }
    }

    private var idleTransport: some View {
        // Single flat HStack so the play button is a sibling of the
        // surrounding combos — no overlay, no overlap, unambiguous hit
        // testing. Liquid Glass coordinates the three glass shapes via
        // the surrounding GlassEffectContainer.
        GlassEffectContainer(spacing: 8) {
            HStack {
                loopAndTrackCombo
                if showSkipButtons {
                    skipButton(seconds: -10, systemImage: "gobackward.10")
                }
                Spacer()
                playPauseButton
                Spacer()
                if showSkipButtons {
                    skipButton(seconds: 10, systemImage: "goforward.10")
                }
                voiceAndAddCombo
            }
        }
    }

    private func recordingTransport(project: ProjectReference) -> some View {
        HStack {
            Spacer()
            cancelRecordingButton
            Spacer()
            recordingMicButton(project: project)
            Spacer()
        }
    }

    /// Previous/next merged into a single glass capsule, mirroring the
    /// mic+plus combo on the right. Loop control was removed for now —
    /// `AudioService.isLooping` defaults to true. Reintroduce by adding a
    /// loop segment back at the head of this HStack and the divider after.
    private var loopAndTrackCombo: some View {
        HStack(spacing: 0) {
            // Button {
            //     store.audio.toggleLoop()
            // } label: {
            //     Image(systemName: "repeat")
            //         .font(.title2)
            //         .foregroundStyle(store.audio.isLooping ? .white : .white.opacity(0.85))
            //         .frame(width: 52, height: 52)
            //         .contentShape(Rectangle())
            // }
            // .buttonStyle(.plain)
            //
            // Rectangle()
            //     .fill(Color.white.opacity(0.15))
            //     .frame(width: 0.5, height: 28)

            Button {
                Task { await store.playPrevious() }
            } label: {
                Image(systemName: "backward.fill")
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 0.5, height: 28)

            Button {
                Task { await store.playNext() }
            } label: {
                Image(systemName: "forward.fill")
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var loopButton: some View {
        Button {
            store.audio.toggleLoop()
        } label: {
            Image(systemName: "repeat")
                .foregroundStyle(store.audio.isLooping ? .white : .white.opacity(0.5))
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var playPauseButton: some View {
        // `.glassEffect` applied OUTSIDE the Button (not on the Image
        // inside the label) — when stacked next to other interactive
        // glass elements in iOS 26, having the effect inside the label
        // causes taps to register visually but never fire the action.
        Button {
            store.audio.togglePlay()
        } label: {
            Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func skipButton(seconds: Double, systemImage: String) -> some View {
        Button {
            store.audio.skip(by: seconds)
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Mic + plus rendered as a single glass capsule, mirroring the
    /// home-screen toolbar combo. Each side is its own tap target.
    private var voiceAndAddCombo: some View {
        HStack(spacing: 0) {
            Button {
                startRecording()
            } label: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 60, height: 52)
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
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 60, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: - Voice note

    private func recordingMicButton(project: ProjectReference) -> some View {
        Button {
            finishRecording(project: project)
        } label: {
            Image(systemName: "stop.fill")
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
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
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private var transcriptBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(speech.lastErrorMessage != nil ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .symbolEffect(.pulse, options: .repeating, isActive: speech.isRecording)
            Text(transcriptBubbleText)
                .font(.system(size: 14))
                .foregroundStyle(speech.transcript.isEmpty ? .white.opacity(0.5) : .white)
                .multilineTextAlignment(.leading)
                .lineLimit(8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if speech.lastErrorMessage != nil { speech.clearError() }
        }
    }

    private var transcriptBubbleText: String {
        if let err = speech.lastErrorMessage { return "Error — \(err)" }
        if speech.isLoadingModel {
            return speech.isDownloadingModel ? "Downloading speech model…" : "Loading speech model…"
        }
        return speech.transcript.isEmpty ? "Listening…" : speech.transcript
    }

    private func startRecording() {
        Task { @MainActor in
            let granted = await speech.requestPermissions()
            guard granted else {
                store.audio.pause()
                showAddNote = true
                return
            }
            store.audio.pause()
            voiceNoteStartTime = store.audio.currentTime
            do {
                try await speech.start()
            } catch {
                // Error message is already on `speech.lastErrorMessage`
                // and shows in the bubble; user can dismiss with the
                // cancel button or fall back to the + sheet manually.
            }
        }
    }

    private func finishRecording(project: ProjectReference) {
        Task { @MainActor in
            let text = await speech.stop()
            guard !text.isEmpty else { return }
            let tags = NoteTags.matches(in: text)
            let note = Note(time: voiceNoteStartTime, text: text, tags: tags)
            await store.addNote(note, to: project)
        }
    }

    private func cancelRecording() {
        speech.cancel()
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
