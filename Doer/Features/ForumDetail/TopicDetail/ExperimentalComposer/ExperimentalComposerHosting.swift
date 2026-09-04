import UIKit

/// Shared install for the experimental block composer.
/// Flag off, or a parser trap, leaves the existing `UITextView` in place.
@MainActor
enum ExperimentalComposerHosting {
    static var isEnabled: Bool {
        AppSettings.shared.experimentalRichComposerEnabled
    }

    static func makeViewIfEnabled(
        pasteCoordinator: ComposerMarkdownCoordinator,
        imageBaseURL: String,
        placeholderText: String,
        onDocumentChanged: @escaping () -> Void,
        onEditingBegan: @escaping () -> Void,
        onSelectionChanged: (() -> Void)? = nil,
        onScroll: (() -> Void)? = nil
    ) -> ExperimentalComposerView? {
        guard isEnabled else { return nil }
        // Touch parse before swapping the body so a trap cannot hide the old editor.
        _ = ExperimentalComposerDocument.parse("")
        let view = ExperimentalComposerView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageBaseURL = imageBaseURL
        view.placeholderText = placeholderText
        view.pasteCoordinator = pasteCoordinator
        view.onDocumentChanged = onDocumentChanged
        view.onEditingBegan = onEditingBegan
        view.onSelectionChanged = onSelectionChanged
        view.onScroll = onScroll
        return view
    }

    static func pin(_ experimental: ExperimentalComposerView, over textView: UIView, in host: UIView) {
        host.insertSubview(experimental, aboveSubview: textView)
        NSLayoutConstraint.activate([
            experimental.topAnchor.constraint(equalTo: textView.topAnchor),
            experimental.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            experimental.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            experimental.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ])
        textView.isHidden = true
    }

    static func abandon(
        _ experimental: ExperimentalComposerView,
        revealing textView: UIView,
        modeButton: UIButton? = nil
    ) {
        experimental.removeFromSuperview()
        textView.isHidden = false
        modeButton?.isHidden = false
    }
}
