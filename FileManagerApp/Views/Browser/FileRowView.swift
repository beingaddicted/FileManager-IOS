import SwiftUI

// MARK: - File Row (list mode)

struct FileRowView: View {
    let item: FileItem
    let isSelected: Bool
    let showThumbnail: Bool
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}

    @State private var thumbnail: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 12) {
                // Icon / Thumbnail
                iconView
                    .frame(width: 44, height: 44)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        if !item.isDirectory && item.size > 0 {
                            Text(item.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !item.isDirectory {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(item.formattedDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Trailing
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.title3)
                } else if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture().onEnded { _ in onLongPress() }
        )
        .task(id: item.id) {
            guard showThumbnail else { return }
            thumbnail = await ThumbnailService.shared.thumbnail(
                for: item,
                size: CGSize(width: 88, height: 88)
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
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(item.accentColor.opacity(0.12))
                Image(systemName: item.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(item.accentColor)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    List {
        FileRowView(
            item: FileItem(
                id: "1", name: "Documents", path: "/Documents",
                size: 0, modifiedDate: Date(),
                isDirectory: true, isHidden: false, isSymlink: false,
                itemType: .folder, providerType: .local
            ),
            isSelected: false, showThumbnail: true
        )
        FileRowView(
            item: FileItem(
                id: "2", name: "Report Q4 2024.pdf", path: "/Report.pdf",
                size: 1_200_000, modifiedDate: Date().addingTimeInterval(-86400),
                isDirectory: false, isHidden: false, isSymlink: false,
                itemType: .pdf, providerType: .local
            ),
            isSelected: true, showThumbnail: true
        )
    }
    .listStyle(.plain)
}
#endif
