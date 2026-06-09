import SwiftUI
import UniformTypeIdentifiers

/// A square card showing a song's album art (or a placeholder with the
/// song's initial if there's no art). Star top-right, big title top-left
/// with a drop shadow, glass play button bottom-right. Dropping an
/// image onto the card replaces the album art on Dropbox.
struct SongCard: View {
    let project: ProjectReference
    var store: SongStore
    /// Closure invoked when the "Create New Version" tile-button is
    /// tapped. The alert it presents is owned by ContentView, so the
    /// card hands the action up rather than driving the sheet itself.
    var onCreateNewVersion: () -> Void = {}
    @State private var isDropTargeted = false
    @State private var showActionsMenu = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artLayer }
            .overlay(alignment: .topLeading) { titleOverlay }
            .overlay(alignment: .topTrailing) { starOverlay }
            // .overlay(alignment: .bottomLeading) { actionsOverlay }  // hidden for now; helpers kept below
            .overlay(alignment: .bottomTrailing) { playButtonOverlay }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.accentColor.opacity(0.18))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                Task { await store.play(project) }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .task(id: project.id) {
                await store.loadAlbumArt(for: project)
            }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var artLayer: some View {
        if let nsImage = store.albumArt[project.id] {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.55),
                    Color(hue: hue, saturation: 0.45, brightness: 0.25),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.18))
        }
    }

    @ViewBuilder
    private var titleOverlay: some View {
        if store.hideTitle[project.id] != true {
            Text(project.displayTitle)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 1)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 18)
                .padding(.horizontal, 20)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var starOverlay: some View {
        if store.starred[project.id] == true {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.yellow)
                .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                .padding(.top, 18)
                .padding(.trailing, 16)
                .allowsHitTesting(false)
        }
    }

    /// Bottom-left overflow affordance — single glass circle with an
    /// ellipsis that opens a popover containing the three file actions.
    /// Uses the proven `playButtonOverlay` recipe (bare Image +
    /// `.glassEffect` + `.highPriorityGesture`) so the symbol stays full
    /// white AND the tap wins over the card-level "open full player"
    /// gesture. A `Menu` here doesn't work — its internal tap loses to
    /// the card's `.onTapGesture`, so taps would fall through to play.
    @ViewBuilder
    private var actionsOverlay: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .symbolRenderingMode(.monochrome)
            .frame(width: 40, height: 40)
            .compatGlass(.clear, in: Circle())
            .contentShape(Circle())
            .highPriorityGesture(
                TapGesture().onEnded { showActionsMenu.toggle() }
            )
            .popover(isPresented: $showActionsMenu, arrowEdge: .top) {
                actionsPopoverContent
            }
            .padding(12)
    }

    /// Popover body rendered when the ellipsis is tapped. Three rows,
    /// each greyed out when the song folder isn't synced locally.
    @ViewBuilder
    private var actionsPopoverContent: some View {
        let enabled = SongStore.localFolderURL(for: project) != nil
        VStack(alignment: .leading, spacing: 0) {
            actionRow(systemName: "folder", title: "Reveal in Finder", enabled: enabled) {
                store.showInFinder(project)
            }
            actionRow(systemName: "music.note", title: "Open Latest .als", enabled: enabled) {
                store.openLatestALS(for: project)
            }
            actionRow(systemName: "plus.square.on.square", title: "Create New Version…", enabled: enabled) {
                onCreateNewVersion()
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 200)
    }

    private func actionRow(systemName: String, title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            showActionsMenu = false
            action()
        } label: {
            Label(title, systemImage: systemName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Bottom-right play affordance. Stops the card-level tap (which
    /// opens the full player) and starts playback immediately instead.
    private var playButtonOverlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .compatGlass(.clear, in: Circle())
            .contentShape(Circle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    Task { await store.play(project, autoStart: true, showPlayer: false) }
                }
            )
            .padding(12)
    }

    // MARK: - Placeholder color

    /// Stable hue across launches. Prefers `project.gradientHue` if the
    /// user has set one; otherwise derives from the UUID's first byte
    /// (NOT `hashValue` — that's randomized per process and would make
    /// the placeholder flicker color on each launch).
    private var hue: Double {
        if let h = project.gradientHue { return h }
        return Double(project.id.uuid.0) / 256.0
    }

    private var initial: String {
        String(project.displayName.first.map { String($0) } ?? "·").uppercased()
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? "public.image"
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            // The provided URL is only valid for the duration of this
            // callback, so read the bytes synchronously here rather than
            // copying to a temp file and racing an async upload against
            // its own cleanup.
            guard let url, let data = try? Data(contentsOf: url) else { return }
            let ext = url.pathExtension.lowercased()
            DispatchQueue.main.async {
                store.setAlbumArt(for: project, imageData: data, fileExtension: ext)
            }
        }
        return true
    }
}
