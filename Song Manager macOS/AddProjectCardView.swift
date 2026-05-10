import SwiftUI

struct AddProjectCardView: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .light))
                Text("Add Project")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(0.82, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.quaternary)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
