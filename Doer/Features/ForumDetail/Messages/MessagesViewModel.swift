import Foundation

final class MessagesViewModel: DoerObservableObject {
    var messages: [DiscourseTopicList.Topic] = []
    var usersById: [Int: DiscourseTopicList.User] = [:]
    var selectedFilter: PrivateMessageFilter = .inbox
    var isLoading = false
    var errorMessage: String?
    var requiresLogin = false

    private let api: DiscourseAPI

    init(api: DiscourseAPI) {
        self.api = api
    }

    func loadMessages(username: String, filter: PrivateMessageFilter? = nil) async {
        if let filter {
            selectedFilter = filter
        }
        isLoading = true
        errorMessage = nil
        requiresLogin = false
        notifyChanged()
        do {
            let result = try await api.fetchPrivateMessages(username: username, filter: selectedFilter)
            messages = result.topicList.topics
            usersById = Dictionary(uniqueKeysWithValues: (result.users ?? []).map { ($0.id, $0) })
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                requiresLogin = true
            }
            errorMessage = error.localizedDescription
        }
        isLoading = false
        notifyChanged()
    }

    func avatarURL(for topic: DiscourseTopicList.Topic, baseURL: String) -> URL? {
        guard let userId = topic.posters?.first?.userId,
              let template = usersById[userId]?.avatarTemplate else { return nil }
        return AvatarImageLoader.url(from: template, baseURL: baseURL, size: AvatarImageLoader.primaryAvatarPixelSize)
    }
}
