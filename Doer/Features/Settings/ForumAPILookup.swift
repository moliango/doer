import UIKit

enum ForumAPILookup {
    static func discourseAPI(from viewController: UIViewController) -> DiscourseAPI? {
        var current: UIViewController? = viewController
        while let controller = current {
            if let forum = controller as? ForumContainerViewController {
                return forum.forumAPI
            }
            current = controller.parent ?? controller.navigationController
        }
        var responder: UIResponder? = viewController
        while let next = responder?.next {
            if let forum = next as? ForumContainerViewController {
                return forum.forumAPI
            }
            responder = next
        }
        return nil
    }
}
