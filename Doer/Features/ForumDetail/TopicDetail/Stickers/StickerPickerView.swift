import SDWebImage
import UIKit

final class StickerPickerView: UIView {
    var onStickerSelected: ((StickerItem) -> Void)?
    var onRequestMarket: (() -> Void)?

    private var details: [StickerGroupDetail] = []
    private var recent: [StickerItem] = []

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 16, right: 12)
        layout.headerReferenceSize = CGSize(width: 1, height: 32)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemBackground
        cv.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseId)
        cv.register(
            StickerSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: StickerSectionHeader.reuseId
        )
        cv.dataSource = self
        cv.delegate = self
        return cv
    }()

    private let emptyStack: UIStackView = {
        let icon = UIImageView(image: UIImage(systemName: "doc"))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let label = UILabel()
        label.text = String(localized: "sticker.empty", defaultValue: "还没有表情包")
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .callout)
        label.textAlignment = .center

        let button = UIButton(type: .system)
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.title = String(localized: "sticker.add_from_market", defaultValue: "+ 从市场添加")
        button.configuration = config

        let stack = UIStackView(arrangedSubviews: [icon, label, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()


    private let loadingIndicator: UIActivityIndicatorView = {
        let v = UIActivityIndicatorView(style: .medium)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.hidesWhenStopped = true
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(collectionView)
        addSubview(emptyStack)
        addSubview(loadingIndicator)
        // Wire market button properly
        if let button = emptyStack.arrangedSubviews.compactMap({ $0 as? UIButton }).first {
            button.addTarget(self, action: #selector(marketTapped), for: .touchUpInside)
        }
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reloadFromStore()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadFromStore() {
        recent = StickerMarketStore.shared.recentStickers()
        let ids = StickerMarketStore.shared.subscribedGroupIds()
        let localById = Dictionary(uniqueKeysWithValues: StickerMarketStore.shared.loadPersistedDetails().map { ($0.id, $0) })
        details = ids.compactMap { localById[$0] }
        emptyStack.isHidden = !(ids.isEmpty && recent.isEmpty)
        collectionView.isHidden = ids.isEmpty && recent.isEmpty
        collectionView.reloadData()
        guard !ids.isEmpty else { return }
        loadingIndicator.startAnimating()
        Task {
            let loaded = (try? await StickerMarketStore.shared.loadSubscribedDetails()) ?? details
            await MainActor.run {
                self.loadingIndicator.stopAnimating()
                self.details = loaded
                self.recent = StickerMarketStore.shared.recentStickers()
                self.emptyStack.isHidden = !(self.details.isEmpty && self.recent.isEmpty)
                self.collectionView.isHidden = self.details.isEmpty && self.recent.isEmpty
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func marketTapped() {
        onRequestMarket?()
    }

    private var sections: [(title: String, items: [StickerItem])] {
        var result: [(String, [StickerItem])] = []
        if !recent.isEmpty {
            result.append((String(localized: "sticker.recent", defaultValue: "最近使用"), recent))
        }
        for detail in details {
            result.append((detail.name, detail.emojis))
        }
        return result
    }
}

extension StickerPickerView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StickerCell.reuseId, for: indexPath) as! StickerCell
        cell.configure(urlString: sections[indexPath.section].items[indexPath.item].url)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: StickerSectionHeader.reuseId,
            for: indexPath
        ) as! StickerSectionHeader
        header.configure(title: sections[indexPath.section].title)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = sections[indexPath.section].items[indexPath.item]
        StickerMarketStore.shared.addRecent(item)
        onStickerSelected?(item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: 64, height: 64)
    }
}

private final class StickerCell: UICollectionViewCell {
    static let reuseId = "StickerCell"
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(urlString: String) {
        imageView.sd_cancelCurrentImageLoad()
        if let url = URL(string: urlString) {
            imageView.sd_setImage(with: url)
        } else {
            imageView.image = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.sd_cancelCurrentImageLoad()
        imageView.image = nil
    }
}

private final class StickerSectionHeader: UICollectionReusableView {
    static let reuseId = "StickerSectionHeader"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title
    }
}
