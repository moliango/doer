import PhotosUI
import UIKit

enum ForumWallpaper {
    static let filename = "custom-list-background.jpg"
    private static let viewTag = 814_229

    static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }

    static var storedImage: UIImage? {
        guard AppSettings.shared.customListBackgroundEnabled else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    static func save(_ image: UIImage) throws {
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw ForumWallpaperError.encodeFailed
        }
        try data.write(to: fileURL, options: .atomic)
        AppSettings.shared.customListBackgroundEnabled = true
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        AppSettings.shared.customListBackgroundEnabled = false
    }

    static func apply(to host: UIView, dim: CGFloat = 0.42) {
        let existing = host.viewWithTag(viewTag) as? ForumWallpaperView
        guard let image = storedImage else {
            existing?.removeFromSuperview()
            return
        }
        let wallpaper = existing ?? {
            let view = ForumWallpaperView()
            view.tag = viewTag
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            host.insertSubview(view, at: 0)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            return view
        }()
        wallpaper.setImage(image, dim: dim)
    }
}

enum ForumWallpaperError: Error, LocalizedError {
    case encodeFailed

    var errorDescription: String? {
        String(localized: "settings.appearance.wallpaper.encode_failed", defaultValue: "无法保存背景图")
    }
}

private final class ForumWallpaperView: UIView {
    private let imageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }()

    private let dimView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.42)
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
        addSubview(dimView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage, dim: CGFloat) {
        imageView.image = image
        dimView.backgroundColor = UIColor.systemBackground.withAlphaComponent(min(max(dim, 0.2), 0.7))
    }
}
