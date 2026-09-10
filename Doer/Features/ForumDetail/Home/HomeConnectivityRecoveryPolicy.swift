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

    /// v1.8.4 reloaded as soon as the path was back. Waiting for Encrypted DNS
    /// left the list on waitNet=true across Wi‑Fi changes.
    static func shouldWaitForDoHRecovery(dohEnabled: Bool) -> Bool {
        _ = dohEnabled
        return false
    }
}
