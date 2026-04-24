import SwiftUI
import PDFKit

// MARK: - PDF Preview

struct PDFPreviewView: View {
    let url: URL

    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var searchText: String = ""
    @State private var showSearch: Bool = false
    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .bottom) {
            PDFKitRepresented(
                url:          url,
                searchText:   searchText,
                currentPage:  $currentPage,
                totalPages:   $totalPages
            )
            .ignoresSafeArea(edges: .bottom)

            // Page indicator
            if totalPages > 1 {
                HStack {
                    Spacer()
                    Text("\(currentPage) / \(totalPages)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassStyle()
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .toolbar {
            if showSearch {
                ToolbarItem(placement: .navigationBarBottom) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search in PDF…", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.secondaryBackground)
                    .clipShape(Capsule())
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSearch.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
    }
}

// MARK: - PDFKit UIViewRepresentable

struct PDFKitRepresented: UIViewRepresentable {
    let url: URL
    var searchText: String
    @Binding var currentPage: Int
    @Binding var totalPages: Int

    func makeUIView(context: Context) -> PDFView {
        let pdfView                     = PDFView()
        pdfView.autoScales              = true
        pdfView.displayMode             = .singlePageContinuous
        pdfView.displayDirection        = .vertical
        pdfView.usePageViewController(false)
        pdfView.pageShadowsEnabled      = true
        pdfView.backgroundColor         = UIColor.systemGroupedBackground

        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
            totalPages       = doc.pageCount
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        context.coordinator.pdfView      = pdfView
        context.coordinator.totalPages   = $totalPages
        context.coordinator.currentPage  = $currentPage

        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if !searchText.isEmpty {
            pdfView.document?.cancelFindString()
            pdfView.document?.beginFindString(searchText, withOptions: .caseInsensitive)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var pdfView: PDFView?
        var currentPage: Binding<Int>?
        var totalPages: Binding<Int>?

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let page    = pdfView.currentPage,
                  let doc     = pdfView.document else { return }
            DispatchQueue.main.async {
                self.currentPage?.wrappedValue = doc.index(for: page) + 1
            }
        }
    }
}
