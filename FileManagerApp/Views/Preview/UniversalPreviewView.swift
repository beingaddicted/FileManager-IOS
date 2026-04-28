import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Universal Preview Router

struct UniversalPreviewView: View {
    let item: FileItem
    let provider: FileBrowserViewModel

    @State private var localURL: URL?
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var textContent: String?
    @State private var resolvedType: FileItemType?
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
        switch resolvedType ?? item.itemType {
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
            resolvedType = await resolvePreferredType(using: url)
            if (resolvedType == .text || resolvedType == .code || item.itemType == .text || item.itemType == .code) {
                textContent = try decodeTextFile(at: url)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func saveText(_ newText: String) async {
        do {
            try await provider.saveText(newText, for: item)
            if let refreshed = await provider.download(item) {
                localURL = refreshed
            }
            textContent = newText
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func decodeTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        // Pattern inspired by mature text editors: try BOM-aware and common legacy encodings.
        let candidates: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            .utf32, .unicode, .windowsCP1252, .isoLatin1
        ]

        for encoding in candidates {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        if let fallback = String(data: data, encoding: .ascii) {
            return fallback
        }
        throw FileProviderError.transferFailed("Unsupported text encoding.")
    }

    private func resolvePreferredType(using localURL: URL) async -> FileItemType {
        if let mediaKind = await detectMediaKind(from: localURL) {
            return mediaKind
        }

        if let mime = item.mimeType?.lowercased() {
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime == "application/pdf" { return .pdf }
            if mime.hasPrefix("text/") { return .text }
        }

        let nameExt = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        if let byName = FileTypeHelper.typeFromExtension(nameExt) {
            return byName
        }

        let localExt = localURL.pathExtension.lowercased()
        if let byLocal = FileTypeHelper.typeFromExtension(localExt) {
            return byLocal
        }

        if let type = UTType(filenameExtension: nameExt.isEmpty ? localExt : nameExt) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .text) { return .text }
            if type.conforms(to: .sourceCode) { return .code }
        }

        if [.image, .video, .audio, .pdf, .text, .code].contains(item.itemType) {
            return item.itemType
        }

        return .unknown
    }

    private func detectMediaKind(from localURL: URL) async -> FileItemType? {
        let asset = AVURLAsset(url: localURL)
        if let hasVideo = try? await asset.loadTracks(withMediaType: .video), !hasVideo.isEmpty {
            return .video
        }
        if let hasAudio = try? await asset.loadTracks(withMediaType: .audio), !hasAudio.isEmpty {
            return .audio
        }
        return nil
    }
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
