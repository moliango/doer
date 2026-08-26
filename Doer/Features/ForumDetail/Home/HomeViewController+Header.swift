import Combine
import Network
import UIKit

// MARK: - Header
extension HomeViewController {
    func setupHeader() {
        // Full search bar under filter; collapses on scroll → 🔍 in top chrome.
        searchRowStackView.addSubview(searchButton)

        // TOP-row trailing chrome, fixed order: 搜索 | 分类 | 小程序 | 铃铛
        trailingChromeStack.addArrangedSubview(compactSearchButton)
        trailingChromeStack.addArrangedSubview(categoryManagerButton)
        trailingChromeStack.addArrangedSubview(miniProgramButton)
        trailingChromeStack.addArrangedSubview(notificationButton)
        notificationButton.addSubview(notificationBadgeView)

        categoryScrollView.addSubview(categoryStackView)
        headerContainer.addSubview(categoryScrollView)
        headerContainer.addSubview(trailingChromeStack)
        headerContainer.addSubview(filterStackView)
        headerContainer.addSubview(searchRowStackView)

        // Header order (top → bottom):
        // 1) category chips + trailing chrome [搜索 | 分类三线 | 小程序 | 铃铛]
        // 2) filter「最新」/分类 dropdown only (no action icons)
        // 3) full search bar「搜索话题…」(scroll → 🔍 stays in top chrome)
        //
        // Drawer mode: chips + 三线 hidden; chrome (搜索/小程序/铃铛) stays on top
        // with the filter row (centerY to filter).
        NSLayoutConstraint.activate([
            categoryScrollView.topAnchor.constraint(
                equalTo: headerContainer.safeAreaLayoutGuide.topAnchor,
                constant: 2
            ),
            categoryScrollView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            categoryScrollView.trailingAnchor.constraint(
                equalTo: trailingChromeStack.leadingAnchor,
                constant: -4
            ),

            trailingChromeStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -10),

            compactSearchButton.widthAnchor.constraint(equalToConstant: 36),
            compactSearchButton.heightAnchor.constraint(equalToConstant: 36),
            categoryManagerButton.widthAnchor.constraint(equalToConstant: 36),
            categoryManagerButton.heightAnchor.constraint(equalToConstant: 36),
            miniProgramButton.widthAnchor.constraint(equalToConstant: 36),
            miniProgramButton.heightAnchor.constraint(equalToConstant: 36),
            notificationButton.widthAnchor.constraint(equalToConstant: 36),
            notificationButton.heightAnchor.constraint(equalToConstant: 36),

            categoryStackView.topAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.topAnchor),
            categoryStackView.leadingAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            categoryStackView.trailingAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            categoryStackView.bottomAnchor.constraint(equalTo: categoryScrollView.contentLayoutGuide.bottomAnchor),
            categoryStackView.heightAnchor.constraint(equalTo: categoryScrollView.frameLayoutGuide.heightAnchor),

            filterStackView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            filterStackView.heightAnchor.constraint(equalToConstant: 36),

            searchRowStackView.topAnchor.constraint(
                equalTo: filterStackView.bottomAnchor,
                constant: Self.filterToSearchSpacing
            ),
            searchRowStackView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            searchRowStackView.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),

            searchButton.topAnchor.constraint(equalTo: searchRowStackView.topAnchor),
            searchButton.bottomAnchor.constraint(equalTo: searchRowStackView.bottomAnchor),
            searchButton.leadingAnchor.constraint(equalTo: searchRowStackView.leadingAnchor),
            searchButton.trailingAnchor.constraint(equalTo: searchRowStackView.trailingAnchor),

            notificationBadgeView.topAnchor.constraint(equalTo: notificationButton.topAnchor, constant: 5),
            notificationBadgeView.trailingAnchor.constraint(equalTo: notificationButton.trailingAnchor, constant: -5),
            notificationBadgeView.widthAnchor.constraint(equalToConstant: 9),
            notificationBadgeView.heightAnchor.constraint(equalToConstant: 9),
        ])
        categoryScrollHeightConstraint = categoryScrollView.heightAnchor.constraint(equalToConstant: Self.categoryRowHeight)
        categoryScrollHeightConstraint?.isActive = true
        filterTopToCategoryConstraint = filterStackView.topAnchor.constraint(
            equalTo: categoryScrollView.bottomAnchor,
            constant: Self.categoryToFilterSpacing
        )
        filterTopToSafeAreaConstraint = filterStackView.topAnchor.constraint(
            equalTo: headerContainer.safeAreaLayoutGuide.topAnchor,
            constant: Self.filterTopInDrawerSpacing
        )
        // Chip mode: chrome is on the top row → filter uses full width.
        filterTrailingToHeaderConstraint = filterStackView.trailingAnchor.constraint(
            lessThanOrEqualTo: headerContainer.trailingAnchor,
            constant: -12
        )
        // Drawer mode: chrome sits with filter (chips gone) → leave room for icons.
        filterTrailingToChromeConstraint = filterStackView.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingChromeStack.leadingAnchor,
            constant: -8
        )
        trailingChromeCenterYToCategoryConstraint = trailingChromeStack.centerYAnchor.constraint(
            equalTo: categoryScrollView.centerYAnchor
        )
        trailingChromeCenterYToFilterConstraint = trailingChromeStack.centerYAnchor.constraint(
            equalTo: filterStackView.centerYAnchor
        )
        filterTopToCategoryConstraint?.isActive = true
        // Default (chip mode): four icons on the top category row.
        trailingChromeCenterYToCategoryConstraint?.isActive = true
        trailingChromeCenterYToFilterConstraint?.isActive = false
        filterTrailingToHeaderConstraint?.isActive = true
        filterTrailingToChromeConstraint?.isActive = false

        searchRowHeightConstraint = searchRowStackView.heightAnchor.constraint(equalToConstant: Self.searchRowExpandedHeight)
        searchRowHeightConstraint?.isActive = true

        setupFilterBar()
        rebuildCategoryTabs()
        hideHomeScrollIndicators()
        updateMiniProgramButtonVisibility()
        updateCompactSearchChrome(animated: false)
        updateCategoryDrawerModeUI()
    }

    func hideHomeScrollIndicators() {
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        categoryScrollView.showsVerticalScrollIndicator = false
        categoryScrollView.showsHorizontalScrollIndicator = false
    }

    func applyThemeStyle() {
        let themeStyle = AppSettings.shared.themeStyle
        let pageBackground = themeStyle.topicListBackgroundColor
        view.backgroundColor = pageBackground
        tableView.backgroundColor = pageBackground
        tableView.estimatedRowHeight = topicListLayout.estimatedRowHeight
        headerContainer.backgroundColor = pageBackground
        if var config = searchButton.configuration {
            if themeStyle == .telegram {
                // Telegram search capsule: light gray pill on white list.
                config.background.backgroundColor = UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(red: 0.14, green: 0.17, blue: 0.20, alpha: 1)
                        : UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
                }
                config.baseForegroundColor = .secondaryLabel
                config.cornerStyle = .capsule
            } else {
                config.background.backgroundColor = themeStyle.topicChipBackgroundColor
            }
            searchButton.configuration = config
        }
        if themeStyle == .telegram {
            // Official Telegram compose FAB: white disc + blue pencil, soft black shadow.
            floatingActionButton.backgroundColor = UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.14, green: 0.17, blue: 0.21, alpha: 1)
                    : .white
            }
            floatingActionButton.tintColor = themeStyle.accentColor
            floatingActionButton.layer.shadowColor = UIColor.black.cgColor
            floatingActionButton.layer.shadowOpacity = 0.18
            floatingActionButton.layer.shadowRadius = 8
            floatingActionButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        } else {
            floatingActionButton.backgroundColor = themeStyle.accentColor
            floatingActionButton.tintColor = .white
            floatingActionButton.layer.shadowColor = themeStyle.accentColor.cgColor
            floatingActionButton.layer.shadowOpacity = 0.22
            floatingActionButton.layer.shadowRadius = 10
            floatingActionButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        }
        createMenuContainer.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        configureCreateMenuButton(createTopicMenuButton, accentColor: themeStyle.accentColor)
        configureCreateMenuButton(draftsMenuButton, accentColor: themeStyle.accentColor)
        applyIncomingTopicsBannerLayout()
        loadingSkeletonView.applyThemeStyle()
        loadingSkeletonTopConstraint?.constant = tableTopSpacing
        emptyStateView.applyThemeStyle()
        loginPromptCard.backgroundColor = themeStyle.topicCardBackgroundColor.withAlphaComponent(0.94)
        loginPromptCard.layer.borderWidth = 1
        loginPromptCard.layer.borderColor = themeStyle.accentColor.withAlphaComponent(0.12).cgColor
        loginPromptCard.layer.shadowColor = themeStyle.accentColor.cgColor
        loginPromptCard.layer.shadowOpacity = 0.09
        loginPromptCard.layer.shadowRadius = 26
        loginPromptCard.layer.shadowOffset = CGSize(width: 0, height: 12)
        loginTitleLabel.textColor = .label
        loginBenefitsStack.arrangedSubviews.compactMap { $0 as? UIButton }.forEach { item in
            var configuration = item.configuration ?? .tinted()
            configuration.baseForegroundColor = themeStyle.accentColor
            configuration.baseBackgroundColor = themeStyle.accentColor.withAlphaComponent(0.12)
            item.configuration = configuration
        }
        var loginConfiguration = loginButton.configuration ?? .filled()
        loginConfiguration.baseBackgroundColor = themeStyle.accentColor
        loginConfiguration.baseForegroundColor = .white
        loginButton.configuration = loginConfiguration
    }

    func setupFilterBar() {
        filterStackView.arrangedSubviews.forEach { view in
            filterStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        filterStackView.addArrangedSubview(filterButton)
        filterStackView.addArrangedSubview(categoryButton)
        filterButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        newSubsetButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        categoryButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        updateFilterButton()
    }

    func applyDropdownStyle(to button: UIButton, title: String, selected: Bool = false) {
        let themeStyle = AppSettings.shared.themeStyle
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 3
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 8)
        config.background.backgroundColor = selected ? themeStyle.accentColor.withAlphaComponent(0.14) : themeStyle.topicChipBackgroundColor
        config.background.cornerRadius = 8
        config.baseForegroundColor = selected ? themeStyle.accentColor : .label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            return a
        }
        button.configuration = config
    }

    func makeCategoryTabButton(title: String, categoryId: Int?) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            return a
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in
            self?.selectCategory(categoryId)
        }, for: .touchUpInside)
        return button
    }
}
