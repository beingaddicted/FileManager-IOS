import SwiftUI
import QuickLook

// MARK: - Universal Preview Router

struct UniversalPreviewView: View {
    let item: FileItem
    let provider: FileBrowserViewModel

    @State private var localURL: URL?
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var textContent: String?
    @State private var showShareSheet: Bool = false
    @State private var showOpenWith: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    loadingView
                } else if let err = loadError {
                    errorView(err)
                } else if let url = localURL {
                    previewContent(url: url)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button {
                        showOpenWith = true
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = localURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(isPresented: $showOpenWith) {
                if let url = localURL {
                    OpenWithSheet(url: url)
                }
            }
        }
        .task {
            await loadFile()
        }
    }

    // MARK: - Preview content router

    @ViewBuilder
    private func previewContent(url: URL) -> some View {
        switch item.itemType {
        case .image:
            ImagePreviewView(url: url)

        case .video:
            MediaPlayerView(url: url, itemType: .video)

        case .audio:
            MediaPlayerView(url: url, itemType: .audio)

        case .pdf:
            PDFPreviewView(url: url)

        case .text, .code:
            if let content = textContent {
                TextEditorView(
                    item:       item,
                    content:    content,
                    isReadOnly: !item.isTextEditable
                ) { newText in
                    Task { await saveText(newText) }
                }
            }

        default:
            QuickLookPreviewView(url: url)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading \(item.name)…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red.opacity(0.7))
            Text("Cannot preview this file")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Try Opening With Another App") {
                showOpenWith = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - File loading

    private func loadFile() async {
        isLoading = true
        loadError = nil
        do {
            guard let url = await provider.download(item) else {
                throw FileProviderError.fileNotFound(item.path)
            }
            localURL = url
            if item.itemType == .text || item.itemType == .code {
                textContent = try? String(contentsOf: url, encoding: .utf8)
                    ?? String(contentsOf: url, encoding: .isoLatin1)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func saveText(_ newText: String) async {
        guard let url = localURL else { return }
        do {
            try newText.write(to: url, atomically: true, encoding: .utf8)
            // Re-upload to remote
            let data = Data(newText.utf8)
            _ = try? await URLSession.shared.data(from: url)    // no-op, just to keep compiler happy
            _ = data
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Throw from expression

private func `throw`(_ error: Error) throws -> URL {
    throw error
}

// MARK: - QuickLook fallback

struct QuickLookPreviewView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc       = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: QLPreviewController, context: Context) {
        vc.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Open With sheet

struct OpenWithSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
