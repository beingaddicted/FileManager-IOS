import SwiftUI
#if canImport(Highlightr)
import Highlightr
#endif

// MARK: - Text Editor View

struct TextEditorView: View {
    let item: FileItem
    let initialContent: String
    var onSave: ((String) -> Void)?
    var isReadOnly: Bool = false

    @State private var text: String
    @State private var isDirty: Bool = false
    @State private var showSaveConfirm: Bool = false
    @State private var fontSize: CGFloat = 14
    @State private var wordWrap: Bool = true
    @State private var showLineNumbers: Bool = false
    @State private var showStats: Bool = false
    @Environment(\.dismiss) private var dismiss

    init(item: FileItem, content: String, isReadOnly: Bool = false, onSave: ((String) -> Void)? = nil) {
        self.item           = item
        self.initialContent = content
        self.isReadOnly     = isReadOnly
        self.onSave         = onSave
        self._text          = State(initialValue: content)
    }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    var lineCount: Int {
        text.components(separatedBy: "\n").count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Toolbar strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        editorToolbarButton("arrow.uturn.backward") {
                            text    = initialContent
                            isDirty = false
                        }
                        editorToolbarDivider
                        editorToolbarButton("minus") { fontSize = max(10, fontSize - 1) }
                        Text("\(Int(fontSize))pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38)
                        editorToolbarButton("plus") { fontSize = min(28, fontSize + 1) }
                        editorToolbarDivider
                        editorToolbarToggle("text.alignleft", isOn: $wordWrap)
                        editorToolbarToggle("list.number", isOn: $showLineNumbers)
                        editorToolbarDivider
                        editorToolbarButton("info.circle") { showStats.toggle() }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 40)
                .background(Color.secondaryBackground)

                Divider()

                // Stats bar
                if showStats {
                    HStack(spacing: 16) {
                        Label("\(lineCount) lines", systemImage: "arrow.up.and.down")
                        Label("\(wordCount) words", systemImage: "textformat")
                        Label("\(text.count) chars", systemImage: "character")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.secondaryBackground)
                    Divider()
                }

                // Editor
                if showLineNumbers {
                    LineNumberTextView(text: $text, fontSize: fontSize, isReadOnly: isReadOnly, wordWrap: wordWrap)
                        .onChange(of: text) { _ in isDirty = text != initialContent }
                } else {
                    plainEditor
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if isDirty {
                            showSaveConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                }
                if !isReadOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave?(text)
                            isDirty = false
                            dismiss()
                        }
                        .bold()
                        .disabled(!isDirty)
                    }
                }
            }
            .alert("Unsaved Changes", isPresented: $showSaveConfirm) {
                Button("Save & Close") {
                    onSave?(text)
                    dismiss()
                }
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
    }

    // MARK: - Plain editor

    private var plainEditor: some View {
        HighlightedTextViewRepresentable(
            text: $text,
            fontSize: fontSize,
            isReadOnly: isReadOnly,
            wordWrap: wordWrap,
            languageHint: languageHint
        )
        .onChange(of: text) { _ in isDirty = text != initialContent }
    }

    private var languageHint: String {
        let ext = item.fileExtension.lowercased()
        switch ext {
        case "json":
            return "json"
        case "yaml", "yml":
            return "yaml"
        case "xml":
            return "xml"
        case "html", "htm":
            return "html"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "swift":
            return "swift"
        case "py":
            return "python"
        case "md", "markdown":
            return "markdown"
        case "java":
            return "java"
        case "kt":
            return "kotlin"
        case "c", "h":
            return "c"
        case "cpp", "cc", "hpp":
            return "cpp"
        case "css":
            return "css"
        case "sh", "zsh", "bash":
            return "bash"
        case "sql":
            return "sql"
        default:
            return "plaintext"
        }
    }

    // MARK: - Toolbar helpers

    private func editorToolbarButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 36, height: 36)
        }
        .foregroundStyle(.primary)
    }

    private func editorToolbarToggle(_ icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 36, height: 36)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .foregroundColor(isOn.wrappedValue ? .accentColor : .primary)
    }

    private var editorToolbarDivider: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 4)
    }
}

// MARK: - Line Number Text View (UIViewRepresentable)

struct LineNumberTextView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var isReadOnly: Bool
    var wordWrap: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv            = UITextView()
        tv.delegate       = context.coordinator
        tv.font           = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.isEditable     = !isReadOnly
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 44, bottom: 12, right: 12)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.isScrollEnabled = true
        tv.textContainer.lineBreakMode = wordWrap ? .byWordWrapping : .byClipping
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LineNumberTextView
        init(_ parent: LineNumberTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
        }
    }
}

// MARK: - Highlighted Text View

struct HighlightedTextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var isReadOnly: Bool
    var wordWrap: Bool
    var languageHint: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isEditable = !isReadOnly
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        context.coordinator.apply(text: text, to: textView, languageHint: languageHint)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isEditable = !isReadOnly
        textView.textContainer.lineBreakMode = wordWrap ? .byWordWrapping : .byClipping

        if context.coordinator.lastRenderedText != text || context.coordinator.lastLanguageHint != languageHint {
            context.coordinator.apply(text: text, to: textView, languageHint: languageHint)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightedTextViewRepresentable
        var lastRenderedText: String = ""
        var lastLanguageHint: String = ""

#if canImport(Highlightr)
        private let highlightr: Highlightr?
#endif

        init(parent: HighlightedTextViewRepresentable) {
            self.parent = parent
#if canImport(Highlightr)
            let instance = Highlightr()
            instance?.setTheme(to: "atom-one-dark")
            self.highlightr = instance
#endif
        }

        func apply(text: String, to textView: UITextView, languageHint: String) {
            lastRenderedText = text
            lastLanguageHint = languageHint

#if canImport(Highlightr)
            if let highlightr,
               let highlighted = highlightr.highlight(text, as: languageHint) {
                let mutable = NSMutableAttributedString(attributedString: highlighted)
                mutable.addAttributes(
                    [.font: UIFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)],
                    range: NSRange(location: 0, length: mutable.length)
                )
                textView.attributedText = mutable
                return
            }
#endif
            textView.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            lastRenderedText = textView.text
        }
    }
}
