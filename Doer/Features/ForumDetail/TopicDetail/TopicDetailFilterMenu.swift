import UIKit

/// FluxDo-style topic content filters: author-only, top-level-only, nested tree.
enum TopicDetailFilterMenu {
    static func makeMenu(
        viewModel: TopicDetailViewModel,
        onChanged: @escaping () -> Void
    ) -> UIMenu {
        let author = UIAction(
            title: String(localized: "topic.filter_op", defaultValue: "只看题主"),
            image: UIImage(systemName: "person"),
            state: viewModel.isFilteringByOP ? .on : .off
        ) { _ in
            viewModel.setFilteringByOP(!viewModel.isFilteringByOP)
            onChanged()
        }

        var filterActions: [UIMenuElement] = [author]
        if let username = viewModel.filterUsername, !viewModel.isFilteringByOP {
            filterActions.append(UIAction(
                title: String(format: String(localized: "topic.filter_user", defaultValue: "只看 %@"), username),
                image: UIImage(systemName: "person.crop.circle.badge.checkmark"),
                state: .on
            ) { _ in
                viewModel.toggleFilterUsername(username)
                onChanged()
            })
        }

        let topLevel = UIAction(
            title: String(localized: "topic.filter_top_level", defaultValue: "只看顶层"),
            image: UIImage(systemName: "arrow.triangle.branch"),
            state: viewModel.isFilteringTopLevel ? .on : .off
        ) { _ in
            viewModel.setFilteringTopLevel(!viewModel.isFilteringTopLevel)
            onChanged()
        }

        // FluxDo: nested sits below a divider, separate from flat filters.
        let nested = UIAction(
            title: String(localized: "topic.filter_nested", defaultValue: "树形视图"),
            image: UIImage(systemName: "bubble.left.and.bubble.right"),
            state: viewModel.isNestedViewEnabled ? .on : .off
        ) { _ in
            let enabled = !viewModel.isNestedViewEnabled
            AppSettings.shared.nestedReplyViewEnabled = enabled
            viewModel.setNestedViewEnabled(enabled)
            onChanged()
        }

        var children: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: filterActions),
            topLevel,
            UIMenu(options: .displayInline, children: [nested]),
        ]

        // FluxDo: cancel appears whenever any filter (including nested) is active.
        if viewModel.hasActiveTopicFilter {
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "topic.filter_clear", defaultValue: "取消筛选"),
                    image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
                    attributes: .destructive
                ) { _ in
                    AppSettings.shared.nestedReplyViewEnabled = false
                    viewModel.clearTopicFilters()
                    onChanged()
                }
            ]))
        }

        return UIMenu(
            title: String(localized: "topic.filter", defaultValue: "筛选"),
            children: children
        )
    }

    static func makeBarButton(
        viewModel: TopicDetailViewModel,
        onChanged: @escaping () -> Void
    ) -> UIBarButtonItem {
        // FluxDo: filled/primary when any filter including nested is on.
        let active = viewModel.hasActiveTopicFilter
        let imageName = active
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        let button = UIBarButtonItem(
            image: UIImage(systemName: imageName),
            menu: makeMenu(viewModel: viewModel, onChanged: onChanged)
        )
        button.accessibilityLabel = String(localized: "topic.filter", defaultValue: "筛选")
        return button
    }
}
