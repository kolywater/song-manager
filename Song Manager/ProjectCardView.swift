import SwiftUI
import UniformTypeIdentifiers

struct ProjectCardView: View {
    let project: ProjectReference
    let albumArt: NSImage?
    var masterFilenames: [String]
    var onListen: () -> Void
    var onSelectMaster: (String) -> Void
    var onNewVersion: () -> Void
    var onShowInFinder: () -> Void
    var onOpenProject: () -> Void
    var onRemove: () -> Void
    var onChangeColor: () -> Void
    var onDropAlbumArt: ([NSItemProvider]) -> Void

    @State private var showingMasterPicker = false
    @State private var isDroppingImage = false

    var body: some View {
        VStack(spacing: 0) {
            // Album art / title area
            ZStack {
                if let albumArt {
                    Image(nsImage: albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: gradientColors(for: project.id),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .aspectRatio(1, contentMode: .fill)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 80)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.displayName)
                                .font(.title.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let version = project.latestVersionString {
                                Text("v\(version)")
                                    .font(.body)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack {
                    HStack {
                        Spacer()
                        Menu {
                            Button("Change Color", action: onChangeColor)
                            Button("Remove Song", role: .destructive, action: onRemove)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .padding(10)
                    }
                    Spacer()
                }
            }
            .overlay {
                if isDroppingImage {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.blue.opacity(0.3))
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 32))
                                Text("Set Album Art")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                        }
                }
            }
            .onDrop(of: [.image], isTargeted: $isDroppingImage) { providers in
                onDropAlbumArt(providers)
                return true
            }
            .clipped()

            // Action buttons
            HStack(spacing: 0) {
                actionButton(icon: "folder", label: "Finder", action: onShowInFinder)
                Divider().frame(height: 28)
                listenButton
                Divider().frame(height: 28)
                actionButton(icon: "square.fill.text.grid.1x2", label: "Open", action: onOpenProject)
                Divider().frame(height: 28)
                actionButton(icon: "plus.square.on.square", label: "New Ver.", action: onNewVersion)
            }
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    private var listenButton: some View {
        let needsPicker = !masterFilenames.isEmpty && project.selectedMasterFilename == nil
        return Button(action: {
            if needsPicker {
                showingMasterPicker = true
            } else {
                onListen()
            }
        }) {
            VStack(spacing: 3) {
                Image(systemName: "headphones")
                    .font(.system(size: 16))
                Text("Listen")
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: $showingMasterPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Choose Master")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(masterFilenames, id: \.self) { filename in
                    Button {
                        showingMasterPicker = false
                        onSelectMaster(filename)
                    } label: {
                        Text(filename.replacingOccurrences(of: ".\(filename.split(separator: ".").last ?? "")", with: ""))
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: 200)
        }
    }

    private func gradientColors(for id: UUID) -> [Color] {
        let hue: Double
        if let stored = project.gradientHue {
            hue = stored
        } else {
            let uuid = id.uuid
            let byte = Int(uuid.0) &+ Int(uuid.6) &* 7
            hue = Double(byte % 256) / 256.0
        }
        return [
            Color(hue: hue, saturation: 0.6, brightness: 0.7),
            Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1.0), saturation: 0.5, brightness: 0.5)
        ]
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
