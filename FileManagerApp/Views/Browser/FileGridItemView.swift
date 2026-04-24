import SwiftUI

// MARK: - File Grid Item (grid mode)

struct FileGridItemView: View {
    let item: FileItem
    let isSelected: Bool
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}

    @State private var thumbnail: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    private let cellSize: CGFloat = 100

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(spacing: 6) {
                // Thumbnail / Icon
                ZStack(alignment: .topTrailing) {
                    iconView
                        .frame(width: cellSize, height: cellSize)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .tint)
                            .padding(4)
                    }
                }

                // Name
                Text(item.name)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: cellSize)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture().onEnded { _ in onLongPress() }
        )
        .task(id: item.id) {
            thumbnail = await ThumbnailService.shared.thumbnail(
                for: item,
                size: CGSize(width: cellSize * 2, height: cellSize * 2)
            )
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        if let img = thumbnail {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.accentColor.opacity(0.12))

                if item.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(item.accentColor)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 32))
                            .foregroundStyle(item.accentColor)

                        if !item.fileExtension.isEmpty {
                            Text(item.fileExtension.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(item.accentColor.opacity(0.7))
                        }
                    }
                }
            }
        }
    }
}
