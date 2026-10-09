import UIKit

/// Download a forum attachment then present the system share sheet.
/// Shared by classic topic detail, nested replies, and chat-style comments.
@MainActor
enum ForumAttachmentShareFlow {
    static func downloadAndShare(
        url: URL,
        baseURL: String,
        from host: UIViewController,
        store: @escaping (URL) -> Void,
        remove: @escaping (URL) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        let progressAlert = makeDownloadAlert()
        host.present(progressAlert, animated: true)

        Task { @MainActor in
            do {
                let fileURL = try await ForumAttachmentDownloader.download(url: url, baseURL: baseURL)
                store(fileURL)
                progressAlert.dismiss(animated: true) {
                    presentShareSheet(fileURL, from: host, remove: remove)
                }
            } catch {
                progressAlert.dismiss(animated: true) {
                    onError(error)
                }
            }
        }
    }

    private static func makeDownloadAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "attachment.downloading"),
            message: "\n\n",
            preferredStyle: .alert
        )
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        alert.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -22),
        ])
        return alert
    }

    private static func presentShareSheet(
        _ fileURL: URL,
        from host: UIViewController,
        remove: @escaping (URL) -> Void
    ) {
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = host.view
        activity.popoverPresentationController?.sourceRect = host.view.bounds
        activity.completionWithItemsHandler = { _, _, _, _ in
            remove(fileURL)
            ForumAttachmentDownloader.cleanupDownloadedFile(fileURL)
        }
        host.present(activity, animated: true)
    }
}
