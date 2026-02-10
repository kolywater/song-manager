import SwiftUI

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

    @State private var showingMasterPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Album art / title area
            ZStack(alignment: .bottomLeading) {
                if let albumArt {
                    Image(nsImage: albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [.purple.opacity(0.6), .blue.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .aspectRatio(1, contentMode: .fill)
                }

                // Dark gradient fade at bottom
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
        .contextMenu {
            Button("Remove Project", role: .destructive, action: onRemove)
        }
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
