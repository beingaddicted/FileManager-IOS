import SwiftUI

// MARK: - Image Preview with zoom & pan

struct ImagePreviewView: View {
    let url: URL

    @State private var scale: CGFloat     = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize     = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var isLoading: Bool    = true
    @State private var showInfo: Bool     = false

    private let minScale: CGFloat = 0.5
    private let maxScale: CGFloat = 8.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { val in
                                    scale = min(maxScale, max(minScale, lastScale * val))
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale < 1 {
                                        withAnimation(.spring()) { scale = 1; offset = .zero }
                                        lastScale = 1; lastOffset = .zero
                                    }
                                },
                            DragGesture()
                                .onChanged { val in
                                    guard scale > 1 else { return }
                                    offset = CGSize(
                                        width:  lastOffset.width  + val.translation.width,
                                        height: lastOffset.height + val.translation.height
                                    )
                                }
                                .onEnded { _ in lastOffset = offset }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1 {
                                scale = 1; offset = .zero; lastScale = 1; lastOffset = .zero
                            } else {
                                scale = 3; lastScale = 3
                            }
                        }
                    }
                    .onTapGesture { showInfo.toggle() }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Cannot display image")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Info overlay
            if showInfo, let img = image {
                VStack {
                    Spacer()
                    HStack(spacing: 20) {
                        Label("\(Int(img.size.width)) × \(Int(img.size.height))", systemImage: "aspectratio")
                        Label(url.pathExtension.uppercased(), systemImage: "doc")
                        if let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                            Label(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file),
                                  systemImage: "doc.badge.ellipsis")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassStyle()
                    .padding(.bottom, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: showInfo)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.white)
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }
        await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)
        }.value.map { img in
            Task { @MainActor in image = img }
        }
    }
}

// MARK: - UIImage optional helper

extension Optional where Wrapped == UIImage {
    func map<T>(_ transform: (UIImage) -> T) -> T? {
        switch self {
        case .some(let img): return transform(img)
        case .none:          return nil
        }
    }
}
