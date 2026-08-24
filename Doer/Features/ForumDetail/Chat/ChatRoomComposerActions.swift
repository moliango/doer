import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// FluxDo chat plus-menu: camera / gallery / file / template / date-time.
/// Uploads go out with `upload_ids` on send; templates and dates insert into the field.
@MainActor
final class ChatRoomComposerController: NSObject,
    PHPickerViewControllerDelegate,
    UIDocumentPickerDelegate,
    UIImagePickerControllerDelegate,
    UINavigationControllerDelegate
{
    private weak var host: UIViewController?
    private let api: DiscourseAPI
    var onInsertText: ((String) -> Void)?
    var onUploaded: ((Int, String) -> Void)?
    var onUploadStateChange: ((Bool) -> Void)?
    var plusAnchor: (() -> UIView?)?

    init(host: UIViewController, api: DiscourseAPI) {
        self.host = host
        self.api = api
        super.init()
    }

    func showMenu() {
        guard let host else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(
                title: String(localized: "chat.attach.camera", defaultValue: "拍照"),
                style: .default
            ) { [weak self] _ in
                self?.presentCamera()
            })
        }
        sheet.addAction(UIAlertAction(
            title: String(localized: "chat.attach.gallery", defaultValue: "相册"),
            style: .default
        ) { [weak self] _ in
            self?.presentGallery()
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "chat.attach.file", defaultValue: "附加文件"),
            style: .default
        ) { [weak self] _ in
            self?.presentFilePicker()
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "chat.insert.template", defaultValue: "插入模板"),
            style: .default
        ) { [weak self] _ in
            Task { await self?.insertTemplate() }
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "chat.insert.datetime", defaultValue: "插入日期/时间"),
            style: .default
        ) { [weak self] _ in
            self?.presentDateTimePicker()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            let anchor = plusAnchor?() ?? host.view
            pop.sourceView = anchor
            pop.sourceRect = anchor?.bounds ?? .zero
        }
        host.present(sheet, animated: true)
    }

    // MARK: Camera / gallery / file

    private func presentCamera() {
        guard let host else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            DoerFeedback.presentToast(
                String(localized: "chat.camera.unavailable", defaultValue: "无法使用相机"),
                on: host
            )
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        picker.allowsEditing = false
        host.present(picker, animated: true)
    }

    private func presentGallery() {
        guard let host else { return }
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        host.present(picker, animated: true)
    }

    private func presentFilePicker() {
        guard let host else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        host.present(picker, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        Task { await uploadImage(image, filename: "image.jpg") }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task { @MainActor in
            for result in results {
                if let file = try? await Self.temporaryFile(from: result) {
                    await uploadFile(url: file.url, filename: file.filename)
                }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                await uploadFile(url: url, filename: url.lastPathComponent)
            }
        }
    }

    private static func temporaryFile(from result: PHPickerResult) async throws -> (url: URL, filename: String) {
        let provider = result.itemProvider
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ChatRoomComposer",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Missing image file"]
                        )
                    )
                    return
                }
                do {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                    if FileManager.default.fileExists(atPath: temp.path) {
                        try FileManager.default.removeItem(at: temp)
                    }
                    try FileManager.default.copyItem(at: url, to: temp)
                    continuation.resume(returning: (temp, temp.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func uploadImage(_ image: UIImage, filename: String) async {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try data.write(to: url)
            await uploadFile(url: url, filename: filename)
        } catch {
            presentError(error)
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func uploadFile(url: URL, filename: String) async {
        guard let host else { return }
        onUploadStateChange?(true)
        defer { onUploadStateChange?(false) }
        DoerFeedback.presentToast(
            String(localized: "chat.attach.uploading", defaultValue: "正在上传…"),
            on: host
        )
        do {
            let upload = try await api.uploadComposerFile(fileURL: url, filename: filename)
            guard let id = upload.id else {
                DoerFeedback.presentToast(
                    String(localized: "reply.upload.failed", defaultValue: "上传失败"),
                    on: host
                )
                return
            }
            onUploaded?(id, upload.originalFilename)
        } catch {
            presentError(error)
        }
    }

    // MARK: Template / date

    private func insertTemplate() async {
        guard let host else { return }
        let templates: [DiscourseTemplate]
        do {
            templates = try await api.fetchDiscourseTemplates()
        } catch {
            presentError(error)
            return
        }
        guard !templates.isEmpty else {
            DoerFeedback.presentToast(
                String(localized: "chat.no_templates", defaultValue: "暂无模板"),
                on: host
            )
            return
        }
        let picker = ChatTemplatePickerViewController(templates: templates)
        picker.onPick = { [weak self] template in
            self?.onInsertText?(template.content)
            Task { await self?.api.recordDiscourseTemplateUse(id: template.id) }
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(nav, animated: true)
    }

    private func presentDateTimePicker() {
        guard let host else { return }
        let picker = ChatDateTimePickerViewController()
        picker.onConfirm = { [weak self] markdown in
            self?.onInsertText?(markdown)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
        host.present(nav, animated: true)
    }

    private func presentError(_ error: Error) {
        guard let host else { return }
        DoerFeedback.presentToast(error.localizedDescription, on: host)
    }
}

// MARK: - Template list

final class ChatTemplatePickerViewController: UITableViewController {
    private let templates: [DiscourseTemplate]
    var onPick: ((DiscourseTemplate) -> Void)?

    init(templates: [DiscourseTemplate]) {
        self.templates = templates
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "chat.insert.template", defaultValue: "插入模板")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "template")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        templates.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "template", for: indexPath)
        let template = templates[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = template.title
        content.secondaryText = template.content
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let template = templates[indexPath.row]
        dismiss(animated: true) { [onPick] in
            onPick?(template)
        }
    }
}

// MARK: - Date/time → Discourse [date=] markdown

final class ChatDateTimePickerViewController: UIViewController {
    var onConfirm: ((String) -> Void)?

    private let picker = UIDatePicker()
    private let includeTimeSwitch = UISwitch()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = String(localized: "chat.insert.datetime", defaultValue: "插入日期/时间")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "chat.datetime.done", defaultValue: "完成"),
            primaryAction: UIAction { [weak self] _ in
                self?.confirm()
            }
        )

        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.preferredDatePickerStyle = .wheels
        picker.datePickerMode = .dateAndTime
        picker.date = Date()
        view.addSubview(picker)

        let timeRow = UIStackView()
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal
        timeRow.alignment = .center
        timeRow.spacing = 12

        let timeLabel = UILabel()
        timeLabel.text = String(localized: "chat.datetime.include_time", defaultValue: "包含时间")
        timeLabel.font = .preferredFont(forTextStyle: .body)
        includeTimeSwitch.isOn = true
        includeTimeSwitch.addAction(UIAction { [weak self] _ in
            self?.syncPickerMode()
        }, for: .valueChanged)
        timeRow.addArrangedSubview(timeLabel)
        timeRow.addArrangedSubview(includeTimeSwitch)
        view.addSubview(timeRow)

        NSLayoutConstraint.activate([
            timeRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            timeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            timeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            picker.topAnchor.constraint(equalTo: timeRow.bottomAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    private func syncPickerMode() {
        picker.datePickerMode = includeTimeSwitch.isOn ? .dateAndTime : .date
    }

    private func confirm() {
        let insert = DiscourseDateMarkdown.make(
            date: picker.date,
            includeTime: includeTimeSwitch.isOn,
            timeZone: .current
        )
        dismiss(animated: true) { [onConfirm] in
            onConfirm?(insert)
        }
    }
}

enum DiscourseDateMarkdown {
    static func make(date: Date, includeTime: Bool, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        var markdown = String(format: "[date=%04d-%02d-%02d", year, month, day)
        if includeTime {
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            markdown += String(format: " time=%02d:%02d:00", hour, minute)
        }
        markdown += " timezone=\"\(timeZone.identifier)\"]"
        return markdown
    }
}
