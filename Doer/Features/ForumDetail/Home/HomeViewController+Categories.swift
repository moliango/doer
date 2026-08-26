import Combine
import Network
import UIKit

// MARK: - Categories
extension HomeViewController {
    func startIncomingTopicsPolling() {
        stopIncomingTopicsPolling()
        pollIncomingTopics()
        let timer = Timer(timeInterval: 30, target: self, selector: #selector(pollIncomingTopics), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        incomingTopicsPollTimer = timer
    }

    func stopIncomingTopicsPolling() {
        incomingTopicsPollTimer?.invalidate()
        incomingTopicsPollTimer = nil
    }

    func buildFilterMenuElements() -> [UIMenuElement] {
        HomeListMode.allCases.map { mode in
            UIAction(
                title: title(for: mode),
                image: UIImage(systemName: imageName(for: mode)),
                state: viewModel.listMode == mode ? .on : .off
            ) { [weak self] _ in
                self?.selectListMode(mode)
            }
        }
    }

    func buildNewSubsetMenuElements() -> [UIMenuElement] {
        HomeNewSubset.allCases.map { subset in
            UIAction(
                title: subset.title,
                state: viewModel.newSubset == subset ? .on : .off
            ) { [weak self] _ in
                self?.selectNewSubset(subset)
            }
        }
    }

    func title(for mode: HomeListMode) -> String {
        switch mode {
        case .latest:
            return String(localized: "home.latest")
        case .newTopics:
            return String(localized: "home.new_topics")
        case .unread:
            return String(localized: "home.updated_topics")
        case .hot:
            return String(localized: "home.hot")
        case .top:
            return String(localized: "home.top")
        }
    }

    func imageName(for mode: HomeListMode) -> String {
        switch mode {
        case .latest:
            return "clock"
        case .newTopics:
            return "sparkles"
        case .unread:
            return "text.bubble"
        case .hot:
            return "flame"
        case .top:
            return "chart.bar"
        }
    }

    func rebuildCategoryTabs() {
        let pinnedCategories = viewModel.pinnedCategories(for: AppSettings.shared.homePinnedCategoryIds)
        let nextOrder: [Int?] = [nil] + pinnedCategories.map { Optional($0.id) }
        guard categoryTabOrder != nextOrder else {
            updateCategoryTabs()
            if isCategoryDrawerMode {
                refreshCategoryDrawerContent()
            }
            return
        }

        categoryTabOrder = nextOrder
        categoryTabButtons.removeAll()
        categoryStackView.arrangedSubviews.forEach { view in
            categoryStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let allButton = makeCategoryTabButton(title: String(localized: "home.filter.all_categories"), categoryId: nil)
        categoryTabButtons[nil] = allButton
        categoryStackView.addArrangedSubview(allButton)

        for category in pinnedCategories {
            let button = makeCategoryTabButton(title: viewModel.categoryDisplayName(for: category) ?? category.name, categoryId: category.id)
            categoryTabButtons[category.id] = button
            categoryStackView.addArrangedSubview(button)
        }

        updateCategoryTabs()
        if isCategoryDrawerMode {
            refreshCategoryDrawerContent()
        }
    }

    func updateCategoryTabs() {
        let themeStyle = AppSettings.shared.themeStyle
        for (categoryId, button) in categoryTabButtons {
            let selected = categoryId == viewModel.selectedCategoryId
            var config = button.configuration ?? UIButton.Configuration.plain()
            if let categoryId, let category = viewModel.category(id: categoryId) {
                config.title = viewModel.categoryDisplayName(for: category) ?? category.name
            } else {
                config.title = String(localized: "home.filter.all_categories")
            }
            config.baseForegroundColor = selected ? themeStyle.accentColor : .secondaryLabel
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = UIFont.systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
                return a
            }
            button.configuration = config
            button.layer.sublayers?
                .filter { $0.name == "selectionIndicator" }
                .forEach { $0.removeFromSuperlayer() }
            if selected {
                let indicator = CALayer()
                indicator.name = "selectionIndicator"
                indicator.backgroundColor = themeStyle.accentColor.cgColor
                indicator.cornerRadius = 1
                button.layer.addSublayer(indicator)
                button.setNeedsLayout()
            }
        }
        layoutCategorySelectionIndicators()
    }

    func layoutCategorySelectionIndicators() {
        for button in categoryTabButtons.values {
            guard let indicator = button.layer.sublayers?.first(where: { $0.name == "selectionIndicator" }) else { continue }
            indicator.frame = CGRect(x: 0, y: button.bounds.height - 3, width: button.bounds.width, height: 2)
        }
    }

    func buildCategoryMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []

        let allAction = UIAction(
            title: String(localized: "home.filter.all_categories"),
            state: viewModel.selectedCategoryId == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectCategory(nil)
        }
        elements.append(allAction)

        for cat in viewModel.categories {
            let state: UIMenuElement.State = viewModel.selectedCategoryId == cat.id ? .on : .off
            let catColor = Self.color(fromHex: cat.color)
            let catImage = Self.colorDotImage(color: catColor)
            let catTitle = viewModel.categoryDisplayName(for: cat) ?? cat.name
            let catAction = UIAction(title: catTitle, image: catImage, state: state) { [weak self] _ in
                self?.selectCategory(cat.id)
            }
            if let subs = cat.subcategoryList, !subs.isEmpty {
                var groupChildren: [UIMenuElement] = [catAction]
                for sub in subs {
                    let subState: UIMenuElement.State = viewModel.selectedCategoryId == sub.id ? .on : .off
                    let subColor = Self.color(fromHex: sub.color)
                    let subImage = Self.colorDotImage(color: subColor)
                    let subTitle = viewModel.categoryDisplayName(for: sub) ?? sub.name
                    let subAction = UIAction(title: subTitle, image: subImage, state: subState) { [weak self] _ in
                        self?.selectCategory(sub.id)
                    }
                    groupChildren.append(subAction)
                }
                elements.append(UIMenu(title: catTitle, image: catImage, children: groupChildren))
            } else {
                elements.append(catAction)
            }
        }
        return elements
    }

    func selectCategory(_ categoryId: Int?) {
        viewModel.selectedCategoryId = categoryId
        updateCategoryButton()
        updateCategoryTabs()
        if isCategoryDrawerMode {
            refreshCategoryDrawerContent()
        }
        reloadTopics()
    }

    static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static func colorDotImage(color: UIColor?) -> UIImage? {
        guard let color else { return nil }
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }
}
