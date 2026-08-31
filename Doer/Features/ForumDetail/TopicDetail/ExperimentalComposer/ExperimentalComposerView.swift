import UIKit

/// Vertical block list used when the experimental WYSIWYG setting is on.
/// Hosts keep send / draft / pangu on `markdown`; this view never owns Discourse cook.
@MainActor
final class ExperimentalComposerView: UIView, UITextViewDelegate {
    var pasteCoordinator: ComposerMarkdownCoordinator? {
        didSet { applyPasteCoordinator() }
    }
    var imageBaseURL: String = ""

    var onDocumentChanged: (() -> Void)?
    var onEditingBegan: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onScroll: (() -> Void)?

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        return scroll
    }()

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        return stack
    }()

    private var blockViews: [ExperimentalComposerBlockView] = []
    private var focusedIndex = 0
    private var isRebuilding = false

    private(set) var document = ExperimentalComposerDocument(blocks: [.paragraph("")])

    var markdown: String {
        syncDocumentFromViews()
        return document.markdown
    }

    var isBodyEmpty: Bool {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEditable: Bool = true {
        didSet {
            blockViews.forEach { $0.textView.isEditable = isEditable }
        }
    }

    var activeTextView: UITextView {
        if focusedIndex >= 0, focusedIndex < blockViews.count {
            return blockViews[focusedIndex].textView
        }
        return blockViews.first?.textView ?? UITextView()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ComposerTypography.backgroundColor
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        scrollView.delegate = self
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
        rebuild(from: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        activeTextView.becomeFirstResponder()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        blockViews.reduce(false) { $0 || $1.textView.resignFirstResponder() }
    }

    func load(markdown raw: String) {
        document = ExperimentalComposerDocument.parse(raw)
        rebuild(from: document)
        onDocumentChanged?()
    }

    func insertRaw(_ text: String) {
        let parsed = ExperimentalComposerDocument.parse(text)
        let shouldInsertBlocks: Bool
        if parsed.blocks.count > 1 {
            shouldInsertBlocks = true
        } else if parsed.blocks.count == 1 {
            switch parsed.blocks[0] {
            case .paragraph:
                shouldInsertBlocks = false
            case .code, .literal, .heading, .quote, .listItem, .image, .quoteCard:
                shouldInsertBlocks = true
            }
        } else {
            shouldInsertBlocks = false
        }

        if shouldInsertBlocks, !parsed.blocks.isEmpty {
            syncDocumentFromViews()
            let insertAt = min(focusedIndex + 1, document.blocks.count)
            document.blocks.insert(contentsOf: parsed.blocks, at: insertAt)
            rebuild(from: document)
            focusedIndex = min(insertAt + parsed.blocks.count - 1, blockViews.count - 1)
            blockViews[safe: focusedIndex]?.textView.becomeFirstResponder()
            onDocumentChanged?()
            return
        }

        insertInline(text)
    }

    func selectedRawText() -> String {
        guard let blockView = blockViews[safe: focusedIndex] else { return "" }
        let selection = blockView.textView.selectedRange
        guard selection.length > 0 else { return "" }
        return blockView.rawText(inDisplayRange: selection)
    }

    func wrapSelection(start: String, end: String, placeholder: String) {
        guard let blockView = blockViews[safe: focusedIndex] else { return }
        let selection = blockView.textView.selectedRange
        let selected = selection.length > 0 ? blockView.rawText(inDisplayRange: selection) : placeholder
        blockView.replaceDisplayRange(selection, withRaw: "\(start)\(selected)\(end)")
        syncDocumentFromViews()
        onDocumentChanged?()
    }

    func replaceActiveDisplayRange(_ range: NSRange, withRaw raw: String) {
        guard let blockView = blockViews[safe: focusedIndex] else { return }
        blockView.replaceDisplayRange(range, withRaw: raw)
        syncDocumentFromViews()
        onDocumentChanged?()
    }

    func applyLinePrefix(_ prefix: String) {
        syncDocumentFromViews()
        guard focusedIndex >= 0, focusedIndex < document.blocks.count else { return }
        let current = document.blocks[focusedIndex]
        let inner = current.innerMarkdown
        let next: ExperimentalComposerBlock
        if prefix.hasPrefix("#") {
            let level = prefix.filter { $0 == "#" }.count
            if case .heading(let existing, _) = current, existing == level {
                next = .paragraph(inner)
            } else {
                next = .heading(min(max(level, 1), 6), inner)
            }
        } else if prefix.hasPrefix("> ") {
            if case .quote = current {
                next = .paragraph(inner)
            } else {
                next = .quote(inner)
            }
        } else if prefix == "- " {
            if case .listItem(ordered: false, _) = current {
                next = .paragraph(inner)
            } else {
                next = .listItem(ordered: false, text: inner)
            }
        } else if prefix.hasSuffix(". ") {
            if case .listItem(ordered: true, _) = current {
                next = .paragraph(inner)
            } else {
                next = .listItem(ordered: true, text: inner)
            }
        } else {
            insertInline(prefix)
            return
        }
        document.blocks[focusedIndex] = next
        rebuild(from: document)
        blockViews[safe: focusedIndex]?.textView.becomeFirstResponder()
        onDocumentChanged?()
    }

    func replaceFullRaw(_ raw: String) {
        load(markdown: raw)
    }

    private func insertInline(_ text: String) {
        guard let blockView = blockViews[safe: focusedIndex] else { return }
        blockView.replaceDisplayRange(blockView.textView.selectedRange, withRaw: text)
        syncDocumentFromViews()
        onDocumentChanged?()
    }

    private func rebuild(from document: ExperimentalComposerDocument) {
        isRebuilding = true
        blockViews.forEach { $0.removeFromSuperview() }
        blockViews.removeAll()
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let blocks = document.blocks.isEmpty ? [.paragraph("")] : document.blocks
        self.document.blocks = blocks
        for (index, block) in blocks.enumerated() {
            let ordinal = ExperimentalComposerDocument.orderedOrdinal(in: blocks, at: index)
            let blockView = ExperimentalComposerBlockView(
                block: block,
                orderedIndex: ordinal ?? 1,
                imageBaseURL: imageBaseURL
            )
            blockView.textView.delegate = self
            blockView.textView.pasteCoordinator = pasteCoordinator
            blockView.textView.isEditable = isEditable && {
                if case .image = block { return false }
                return true
            }()
            blockView.textView.tag = index
            stackView.addArrangedSubview(blockView)
            blockViews.append(blockView)
        }
        focusedIndex = min(focusedIndex, max(blockViews.count - 1, 0))
        isRebuilding = false
    }

    private func applyPasteCoordinator() {
        blockViews.forEach { $0.textView.pasteCoordinator = pasteCoordinator }
    }

    func syncDocumentFromViews() {
        guard !blockViews.isEmpty else { return }
        blockViews.forEach { $0.harvestFromTextView() }
        document.blocks = blockViews.map(\.block)
    }

    @objc private func backgroundTapped() {
        guard let last = blockViews.last else { return }
        last.textView.becomeFirstResponder()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        focusedIndex = textView.tag
        onEditingBegan?()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isRebuilding else { return }
        blockViews[safe: textView.tag]?.harvestFromTextView()
        onDocumentChanged?()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isRebuilding else { return }
        focusedIndex = textView.tag
        onSelectionChanged?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?()
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard !isRebuilding, let blockView = blockViews[safe: textView.tag] else { return true }
        switch blockView.block {
        case .code, .literal, .quoteCard:
            return true
        case .image:
            return false
        default:
            break
        }

        if text == "\n" {
            splitBlock(at: textView.tag, caret: range)
            return false
        }

        if text.isEmpty, range.location == 0, range.length == 0, textView.tag > 0 {
            mergeBlock(at: textView.tag)
            return false
        }

        return true
    }

    private func splitBlock(at index: Int, caret: NSRange) {
        guard let blockView = blockViews[safe: index] else { return }
        let prefixRaw = blockView.rawText(inDisplayRange: NSRange(location: 0, length: caret.location))
        let attributedLength = blockView.textView.attributedText?.length ?? blockView.textView.text?.utf16.count ?? 0
        let suffixStart = min(caret.location + caret.length, attributedLength)
        let suffixRaw = blockView.rawText(
            inDisplayRange: NSRange(location: suffixStart, length: max(attributedLength - suffixStart, 0))
        )
        syncDocumentFromViews()
        var kind = document.blocks[index]

        if case .paragraph = kind, let marker = ExperimentalComposerDocument.listLineMatch(prefixRaw) {
            kind = .listItem(ordered: marker.ordered, text: marker.text)
        }

        if case .listItem = kind,
           prefixRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           suffixRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           index > 0,
           case .listItem = document.blocks[index - 1] {
            document.blocks[index] = .paragraph("")
            rebuild(from: document)
            focusedIndex = index
            blockViews[safe: focusedIndex]?.textView.becomeFirstResponder()
            onDocumentChanged?()
            return
        }

        document.blocks[index] = kind.replacingInner(currentInnerAfterSplit(kind: kind, prefixRaw: prefixRaw))
        let newBlock: ExperimentalComposerBlock
        switch kind {
        case .listItem(let ordered, _):
            let suffixInner = ExperimentalComposerDocument.listLineMatch(suffixRaw)?.text ?? suffixRaw
            newBlock = .listItem(ordered: ordered, text: suffixInner)
        case .quote:
            newBlock = suffixRaw.isEmpty ? .paragraph("") : .quote(suffixRaw)
        default:
            newBlock = .paragraph(suffixRaw)
        }
        document.blocks.insert(newBlock, at: index + 1)
        rebuild(from: document)
        focusedIndex = index + 1
        blockViews[safe: focusedIndex]?.textView.becomeFirstResponder()
        onDocumentChanged?()
    }

    private func currentInnerAfterSplit(kind: ExperimentalComposerBlock, prefixRaw: String) -> String {
        if case .listItem = kind, let marker = ExperimentalComposerDocument.listLineMatch(prefixRaw) {
            return marker.text
        }
        return prefixRaw
    }

    private func mergeBlock(at index: Int) {
        guard index > 0, index < document.blocks.count else { return }
        syncDocumentFromViews()
        let previous = document.blocks[index - 1]
        let current = document.blocks[index]
        if previous.isAtomicIsland {
            document.blocks.remove(at: index - 1)
            rebuild(from: document)
            focusedIndex = index - 1
            blockViews[safe: focusedIndex]?.textView.becomeFirstResponder()
            onDocumentChanged?()
            return
        }
        let mergedInner: String
        if previous.innerMarkdown.isEmpty {
            mergedInner = current.innerMarkdown
        } else if current.innerMarkdown.isEmpty {
            mergedInner = previous.innerMarkdown
        } else {
            mergedInner = previous.innerMarkdown + current.innerMarkdown
        }
        document.blocks[index - 1] = previous.replacingInner(mergedInner)
        document.blocks.remove(at: index)
        rebuild(from: document)
        focusedIndex = index - 1
        let tv = blockViews[safe: focusedIndex]?.textView
        tv?.becomeFirstResponder()
        if let tv {
            let end = tv.attributedText?.length ?? tv.text?.utf16.count ?? 0
            tv.selectedRange = NSRange(location: end, length: 0)
        }
        onDocumentChanged?()
    }
}

private extension ExperimentalComposerBlock {
    var innerMarkdown: String {
        switch self {
        case .paragraph(let text), .quote(let text), .literal(let text):
            return text
        case .heading(_, let text), .listItem(_, let text):
            return text
        case .code(_, let code):
            return code
        case .image(let alt, _, _):
            return alt
        case .quoteCard(_, _, _, _, _, let inner):
            return inner
        }
    }

    var isAtomicIsland: Bool {
        switch self {
        case .image, .quoteCard:
            return true
        default:
            return false
        }
    }

    func replacingInner(_ text: String) -> ExperimentalComposerBlock {
        switch self {
        case .paragraph:
            return .paragraph(text)
        case .heading(let level, _):
            return .heading(level, text)
        case .quote:
            return .quote(text)
        case .listItem(let ordered, _):
            return .listItem(ordered: ordered, text: text)
        case .code(let language, _):
            return .code(language: language, code: text)
        case .image(_, let url, let title):
            return .image(alt: text, url: url, title: title)
        case .quoteCard(let username, let displayName, let postNumber, let topicId, let full, _):
            return .quoteCard(
                username: username,
                displayName: displayName,
                postNumber: postNumber,
                topicId: topicId,
                full: full,
                inner: text
            )
        case .literal:
            return .literal(text)
        }
    }
}

private final class ExperimentalComposerBlockView: UIView {
    private(set) var block: ExperimentalComposerBlock
    private let orderedIndex: Int
    private let imageBaseURL: String
    let textView = ComposerBodyTextView()
    private let chrome = UIView()
    private let quoteHeader = UILabel()
    private let imageView = UIImageView()
    private var imageHeightConstraint: NSLayoutConstraint!
    private let rowStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 6
        return stack
    }()
    private let markerColumn = UIView()
    private let markerLabel = UILabel()
    private var isApplying = false
    private var markerWidthConstraint: NSLayoutConstraint!
    init(block: ExperimentalComposerBlock, orderedIndex: Int = 1, imageBaseURL: String = "") {
        self.block = block
        self.orderedIndex = orderedIndex
        self.imageBaseURL = imageBaseURL
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        markerColumn.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteHeader.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.returnKeyType = .default
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        chrome.layer.cornerRadius = 10
        chrome.layer.cornerCurve = .continuous
        chrome.clipsToBounds = true

        quoteHeader.font = AppSettings.shared.appInterfaceFont(
            ofSize: 13,
            weight: .semibold,
            fallback: .systemFont(ofSize: 13, weight: .semibold)
        )
        quoteHeader.textColor = .secondaryLabel
        quoteHeader.adjustsFontForContentSizeCategory = true
        quoteHeader.isHidden = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = UIColor.secondarySystemFill
        imageView.layer.cornerRadius = 8
        imageView.isHidden = true
        imageView.isUserInteractionEnabled = false

        markerColumn.setContentHuggingPriority(.required, for: .horizontal)
        markerColumn.setContentCompressionResistancePriority(.required, for: .horizontal)
        markerLabel.font = ComposerTypography.bodyFont
        markerLabel.textColor = .label
        markerLabel.textAlignment = .right
        markerLabel.adjustsFontForContentSizeCategory = true
        markerLabel.setContentHuggingPriority(.required, for: .horizontal)
        markerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let contentStack = UIStackView(arrangedSubviews: [quoteHeader, imageView, rowStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 6

        addSubview(chrome)
        chrome.addSubview(contentStack)
        markerColumn.addSubview(markerLabel)
        rowStack.addArrangedSubview(markerColumn)
        rowStack.addArrangedSubview(textView)
        markerWidthConstraint = markerColumn.widthAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -6),
            imageHeightConstraint,
            markerLabel.topAnchor.constraint(equalTo: markerColumn.topAnchor, constant: 4),
            markerLabel.leadingAnchor.constraint(equalTo: markerColumn.leadingAnchor),
            markerLabel.trailingAnchor.constraint(equalTo: markerColumn.trailingAnchor),
            markerLabel.bottomAnchor.constraint(equalTo: markerColumn.bottomAnchor),
            markerWidthConstraint,
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.listRowMinHeight),
        ])
        applyChrome()
        applyContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func harvestFromTextView() {
        guard !isApplying else { return }
        switch block {
        case .code(let language, _):
            block = .code(language: language, code: textView.text ?? "")
        case .literal:
            block = .literal(textView.text ?? "")
        case .image:
            break
        case .quoteCard(let username, let displayName, let postNumber, let topicId, let full, _):
            let raw = ComposerMarkdownCodec.markdown(from: textView.attributedText ?? NSAttributedString())
            block = .quoteCard(
                username: username,
                displayName: displayName,
                postNumber: postNumber,
                topicId: topicId,
                full: full,
                inner: raw.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            )
        default:
            let raw = ComposerMarkdownCodec.markdown(from: textView.attributedText ?? NSAttributedString())
            block = block.replacingInner(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\n")))
        }
    }

    func rawText(inDisplayRange range: NSRange) -> String {
        switch block {
        case .image:
            return ""
        case .code, .literal:
            let text = (textView.text ?? "") as NSString
            let length = text.length
            let location = min(max(range.location, 0), length)
            let lengthClamped = min(max(range.length, 0), length - location)
            return text.substring(with: NSRange(location: location, length: lengthClamped))
        default:
            let attributed = textView.attributedText ?? NSAttributedString()
            let length = attributed.length
            guard length > 0, range.length > 0 else { return "" }
            let location = min(max(range.location, 0), length)
            let lengthClamped = min(max(range.length, 0), length - location)
            let slice = attributed.attributedSubstring(from: NSRange(location: location, length: lengthClamped))
            return ComposerMarkdownCodec.markdown(from: slice)
        }
    }

    func replaceDisplayRange(_ range: NSRange, withRaw raw: String) {
        switch block {
        case .image:
            return
        case .code, .literal:
            let text = NSMutableString(string: textView.text ?? "")
            let length = text.length
            let location = min(max(range.location, 0), length)
            let lengthClamped = min(max(range.length, 0), length - location)
            text.replaceCharacters(in: NSRange(location: location, length: lengthClamped), with: raw)
            isApplying = true
            textView.text = text as String
            let caret = location + (raw as NSString).length
            textView.selectedRange = NSRange(location: min(caret, text.length), length: 0)
            isApplying = false
            harvestFromTextView()
        default:
            let attributed = NSMutableAttributedString(
                attributedString: textView.attributedText ?? NSAttributedString(string: "", attributes: ComposerTypography.typingAttributes)
            )
            let length = attributed.length
            let location = min(max(range.location, 0), length)
            let lengthClamped = min(max(range.length, 0), length - location)
            let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: location))
            let suffix = attributed.attributedSubstring(
                from: NSRange(location: location + lengthClamped, length: length - location - lengthClamped)
            )
            let prefixRaw = ComposerMarkdownCodec.markdown(from: prefix)
            let suffixRaw = ComposerMarkdownCodec.markdown(from: suffix)
            let combined = prefixRaw + raw + suffixRaw
            block = block.replacingInner(combined)
            applyContent()
            let caretRaw = prefixRaw + raw
            let caretDisplay = displayedAttributedString(from: caretRaw).length
            textView.selectedRange = NSRange(
                location: min(caretDisplay, textView.attributedText?.length ?? 0),
                length: 0
            )
        }
    }

    private func applyChrome() {
        markerLabel.text = nil
        markerColumn.isHidden = true
        chrome.backgroundColor = .clear
        chrome.layer.borderWidth = 0
        markerWidthConstraint.constant = 0
        quoteHeader.isHidden = true
        quoteHeader.text = nil
        imageView.isHidden = true
        imageHeightConstraint.constant = 0
        textView.isHidden = false
        textView.isEditable = true
        switch block {
        case .paragraph:
            break
        case .heading:
            break
        case .quote:
            chrome.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.35)
            chrome.layer.borderWidth = 3
            chrome.layer.borderColor = ComposerTypography.accentColor.withAlphaComponent(0.45).cgColor
        case .listItem(let ordered, _):
            markerColumn.isHidden = false
            markerLabel.text = ordered ? "\(orderedIndex)." : "•"
            markerWidthConstraint.constant = ordered ? 32 : 18
        case .code:
            chrome.backgroundColor = ComposerTypography.mutedFill
            textView.font = ComposerTypography.codeFont
        case .literal:
            chrome.backgroundColor = ComposerTypography.mutedFill
            textView.font = ComposerTypography.codeFont
        case .image:
            chrome.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.4)
            imageView.isHidden = false
            imageHeightConstraint.constant = 180
            textView.isHidden = true
            textView.isEditable = false
        case .quoteCard(let username, let displayName, let postNumber, _, _, _):
            chrome.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.4)
            chrome.layer.borderWidth = 0
            quoteHeader.isHidden = false
            var title = displayName?.isEmpty == false ? displayName! : username
            if title.isEmpty { title = String(localized: "topic.quote", defaultValue: "引用") }
            if let postNumber {
                title += " · #\(postNumber)"
            }
            quoteHeader.text = title
        }
    }

    private func applyContent() {
        isApplying = true
        switch block {
        case .code(_, let code), .literal(let code):
            textView.typingAttributes = [
                .font: ComposerTypography.codeFont,
                .foregroundColor: UIColor.label,
            ]
            textView.attributedText = NSAttributedString(
                string: code,
                attributes: [
                    .font: ComposerTypography.codeFont,
                    .foregroundColor: UIColor.label,
                ]
            )
        case .image(_, let url, _):
            imageView.image = UIImage(systemName: "photo")
            imageView.tintColor = .tertiaryLabel
            imageView.contentMode = .center
            if let parsed = ExperimentalComposerDocument.previewImageURL(from: url, baseURL: imageBaseURL) {
                ForumImageLoader.setImage(
                    on: imageView,
                    url: parsed,
                    placeholder: UIImage(systemName: "photo"),
                    cloudflareBaseURL: imageBaseURL
                ) { [weak self] image, _, _, _ in
                    guard let self, image != nil else { return }
                    self.imageView.contentMode = .scaleAspectFill
                    self.imageView.tintColor = nil
                }
            }
        case .quoteCard:
            let styled = displayedAttributedString(from: block.innerMarkdown)
            textView.attributedText = styled
            textView.typingAttributes = ComposerTypography.typingAttributes
        default:
            let styled = displayedAttributedString(from: block.innerMarkdown)
            textView.attributedText = styled
            if styled.length > 0 {
                textView.typingAttributes = ComposerMarkdownCodec.typingAttributes(
                    at: max(styled.length - 1, 0),
                    in: styled
                )
            } else if case .listItem = block {
                textView.typingAttributes = [
                    .font: ComposerTypography.bodyFont,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: Self.listParagraphStyle,
                ]
            } else {
                textView.typingAttributes = ComposerTypography.typingAttributes
            }
        }
        isApplying = false
    }

    private func displayedAttributedString(from inner: String) -> NSMutableAttributedString {
        let styled = ComposerMarkdownCodec.richAttributedString(from: inner)
        if styled.string.hasSuffix("\n"), styled.length > 0 {
            styled.deleteCharacters(in: NSRange(location: styled.length - 1, length: 1))
        }
        switch block {
        case .heading(let level, _):
            let font = ComposerTypography.headingFont(level: level)
            styled.addAttribute(.font, value: font, range: NSRange(location: 0, length: styled.length))
        case .quote:
            styled.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: styled.length))
        case .listItem:
            if styled.length > 0 {
                styled.addAttribute(.paragraphStyle, value: Self.listParagraphStyle, range: NSRange(location: 0, length: styled.length))
            }
        default:
            break
        }
        return styled
    }

    private static var listParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1
        style.paragraphSpacing = 0
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static var listRowMinHeight: CGFloat {
        ceil(ComposerTypography.bodyFont.lineHeight) + 8
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
