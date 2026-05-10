import SwiftUI

struct SongCard: View {
    let project: ProjectReference

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            placeholderArt
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                if let version = project.latestVersionString {
                    Text(version.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(project.displayName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.55),
                    Color(hue: hue, saturation: 0.45, brightness: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.18))
        }
    }

    private var hue: Double {
        if let h = project.gradientHue { return h }
        // Stable hash → hue in [0, 1)
        let h = abs(project.id.uuidString.hashValue) % 360
        return Double(h) / 360.0
    }

    private var initial: String {
        String(project.displayName.first.map { String($0) } ?? "·").uppercased()
    }
}
