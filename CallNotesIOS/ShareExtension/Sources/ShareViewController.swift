import Social
import UIKit
import UniformTypeIdentifiers

/// Accepts audio from Notes, Voice Memos, Files, and Mail, then atomically
/// moves it into the shared App Group queue before the extension exits.
final class ShareViewController: UIViewController {
    private let nameField = UITextField()
    private let dateField = UITextField()
    private var sharedAudioURL: URL?
    private var sharedMetadata: ExtensionUploadMetadata?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Send to Mac"
        view.backgroundColor = .systemBackground
        configureForm()
        loadAudio()
    }

    private func configureForm() {
        let titleLabel = UILabel()
        titleLabel.text = "CallNotes"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        let descriptionLabel = UILabel()
        descriptionLabel.text = "Audio is copied safely, then uploads to your paired Mac in the background."
        descriptionLabel.numberOfLines = 0
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabel
        nameField.placeholder = "Contact name"
        nameField.borderStyle = .roundedRect
        nameField.accessibilityLabel = "Counterparty name"
        dateField.placeholder = "Start time"
        dateField.borderStyle = .roundedRect
        dateField.accessibilityLabel = "Call start time"
        let send = UIButton(type: .system)
        send.configuration = .filled()
        send.configuration?.title = "Send to Mac"
        send.configuration?.image = UIImage(systemName: "arrow.up.circle.fill")
        send.addTarget(self, action: #selector(sendToMac), for: .touchUpInside)
        send.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        send.accessibilityLabel = "Send shared recording to Mac"
        let stack = UIStackView(arrangedSubviews: [titleLabel, descriptionLabel, nameField, dateField, send])
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func loadAudio() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier) })
        else { return }
        let suggestedName = provider.suggestedName
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { [weak self] url, _, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                self?.sharedAudioURL = url
                let metadata = ExtensionRecordingTitleParser.parse(suggestedName ?? "")
                self?.sharedMetadata = metadata
                self?.nameField.text = metadata?.counterpartyName
                if let startedAt = metadata?.startedAt {
                    self?.dateField.text = startedAt.formatted(date: .abbreviated, time: .shortened)
                }
            }
        }
    }

    @objc private func sendToMac() {
        guard let sharedAudioURL else { showError("This share item is not an audio file."); return }
        let counterpartyName = nameField.text
        let startedAt = sharedMetadata?.startedAt
        Task {
            do {
                let container = try self.sharedContainer()
                try ExtensionUploadQueue.enqueue(
                    audioAt: sharedAudioURL,
                    metadata: .init(source: "iphone_recording", startedAt: startedAt, counterpartyName: counterpartyName),
                    in: container.appendingPathComponent("PhoneUploads", isDirectory: true)
                )
                await MainActor.run { self.extensionContext?.completeRequest(returningItems: nil) }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    private func sharedContainer() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.thatdudealso.callnotes") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t queue recording", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private struct ExtensionUploadMetadata: Codable {
    var source: String
    var startedAt: Date?
    var counterpartyName: String?
}

private struct ExtensionPendingUpload: Codable {
    var id: UUID
    var audioURL: URL
    var metadata: ExtensionUploadMetadata
    var createdAt: Date
    var retryCount: Int
    var nextAttemptAt: Date?
}

private enum ExtensionUploadQueue {
    static func enqueue(audioAt source: URL, metadata: ExtensionUploadMetadata, in directory: URL) throws {
        let files = directory.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let extensionName = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let destination = files.appendingPathComponent(UUID().uuidString).appendingPathExtension(extensionName)
        try FileManager.default.copyItem(at: source, to: destination)
        let manifest = directory.appendingPathComponent("pending-uploads.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var pending = (try? decoder.decode([ExtensionPendingUpload].self, from: Data(contentsOf: manifest))) ?? []
        pending.append(.init(id: UUID(), audioURL: destination, metadata: metadata, createdAt: Date(), retryCount: 0, nextAttemptAt: nil))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pending).write(to: manifest, options: .atomic)
    }
}

private enum ExtensionRecordingTitleParser {
    static func parse(_ title: String) -> ExtensionUploadMetadata? {
        let expression = #/^Call with (.+?),\s*(.+)$/#
        guard let match = title.wholeMatch(of: expression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return .init(source: "iphone_recording", startedAt: formatter.date(from: String(match.output.2)), counterpartyName: String(match.output.1))
    }
}
