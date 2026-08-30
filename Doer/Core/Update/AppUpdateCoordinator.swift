import UIKit

extension Notification.Name {
    static let appUpdateDidBecomeAvailable = Notification.Name("AppUpdateDidBecomeAvailable")
}

@MainActor
final class AppUpdateCoordinator {
    static let shared = AppUpdateCoordinator()
    static let releasesURL = URL(string: "https://github.com/moliango/doer/releases")!

    private let service: AppUpdateService
    private var automaticCheckTask: Task<Void, Never>?
    private var hasScheduledAutomaticCheck = false
    private var isPresentingUpdate = false
    private var presentedTags = Set<String>()
    private(set) var pendingRelease: AppRelease?

    init(service: AppUpdateService? = nil) {
        self.service = service ?? .shared
    }

    func scheduleAutomaticCheckIfNeeded() {
        guard AppSettings.shared.autoCheckForUpdates else { return }
        guard !hasScheduledAutomaticCheck else { return }
        hasScheduledAutomaticCheck = true

        automaticCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self else { return }
            guard AppSettings.shared.autoCheckForUpdates else { return }
            do {
                let release = try await service.check(mode: .automatic)
                guard !Task.isCancelled, AppSettings.shared.autoCheckForUpdates else { return }
                guard release.isUpdateAvailable(comparedTo: AppVersion.installed()) else { return }
                pendingRelease = release
                NotificationCenter.default.post(name: .appUpdateDidBecomeAvailable, object: self)
            } catch {
                // Automatic update checks never interrupt startup.
            }
        }
    }

    func automaticCheckPreferenceDidChange() {
        guard AppSettings.shared.autoCheckForUpdates else {
            automaticCheckTask?.cancel()
            automaticCheckTask = nil
            hasScheduledAutomaticCheck = false
            pendingRelease = nil
            return
        }
        scheduleAutomaticCheckIfNeeded()
    }

    func presentPendingIfPossible(from presenter: UIViewController) {
        guard let release = pendingRelease,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil,
              UIApplication.shared.applicationState == .active,
              !isPresentingUpdate,
              !presentedTags.contains(release.tagName)
        else { return }

        isPresentingUpdate = true
        present(release: release, from: presenter) { [weak self] didPresent in
            guard let self else { return }
            self.isPresentingUpdate = false
            guard didPresent else { return }
            self.pendingRelease = nil
            self.presentedTags.insert(release.tagName)
        }
    }

    func checkManually(from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        let loading = UIAlertController(
            title: String(localized: "update.checking.title", defaultValue: "正在检查更新"),
            message: String(localized: "update.checking.message", defaultValue: "正在连接 GitHub Releases…") + "\n\n",
            preferredStyle: .alert
        )
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        loading.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: loading.view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loading.view.centerYAnchor, constant: 26),
        ])
        presenter.present(loading, animated: true) { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            Task { [weak self, weak presenter] in
                guard let self else { return }
                do {
                    let release = try await service.check(mode: .manual)
                    guard let presenter else { return }
                    loading.dismiss(animated: true) { [weak self, weak presenter] in
                        guard let self, let presenter, presenter.viewIfLoaded?.window != nil else { return }
                        if release.isUpdateAvailable(comparedTo: AppVersion.installed()) {
                            self.present(release: release, from: presenter)
                        } else {
                            self.presentLatestVersion(from: presenter)
                        }
                    }
                } catch {
                    guard let presenter else { return }
                    loading.dismiss(animated: true) { [weak self, weak presenter] in
                        guard let self, let presenter, presenter.viewIfLoaded?.window != nil else { return }
                        self.presentManualError(from: presenter)
                    }
                }
            }
        }
    }

    static func openReleasePage() {
        openReleasePage(releasesURL)
    }

    static func openReleasePage(_ url: URL) {
        let prefix = UserDefaults.standard.string(forKey: "githubProxyPrefix") ?? ""
        let destination: URL
        do {
            destination = try GitHubProxy.applyIfValid(to: url, prefix: prefix)
        } catch {
            UIApplication.shared.open(url)
            return
        }
        UIApplication.shared.open(destination)
    }

    private func present(
        release: AppRelease,
        from presenter: UIViewController,
        completion: ((Bool) -> Void)? = nil
    ) {
        let viewController = AppUpdateViewController(
            currentVersion: AppVersion.installed(),
            release: release
        )
        let navigationController = UINavigationController(rootViewController: viewController)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        presenter.present(navigationController, animated: true) {
            completion?(navigationController.presentingViewController != nil)
        }
    }

    private func presentLatestVersion(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: String(localized: "update.latest.title", defaultValue: "已是最新版本"),
            message: String.localizedStringWithFormat(
                String(localized: "update.latest.message %@", defaultValue: "当前版本 %@ 已是最新版本。"),
                AppVersion.installed().displayString
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.done"), style: .default))
        presenter.present(alert, animated: true)
    }

    private func presentManualError(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: String(localized: "update.error.title", defaultValue: "检查更新失败"),
            message: String(
                localized: "update.error.message",
                defaultValue: "无法连接 GitHub Releases，请检查网络后重试。"
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.done"), style: .default))
        presenter.present(alert, animated: true)
    }
}
