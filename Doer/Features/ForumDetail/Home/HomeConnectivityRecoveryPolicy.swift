import Foundation

enum HomeConnectivityRecoveryPolicy {
    /// Reconnect should unstick an empty, failed, or offline-skipped list.
    /// A healthy in-memory list is left alone so flapping Wi-Fi does not rebuild it.
    static func shouldReloadTopicList(
        topicsEmpty: Bool,
        hasError: Bool,
        isWaitingForNetwork: Bool = false,
        isLoading: Bool = false
    ) -> Bool {
        topicsEmpty || hasError || isWaitingForNetwork || isLoading
    }
}
