import Social
import UIKit
import UniformTypeIdentifiers
import CallNotesCore
import Security

/// Accepts audio from Notes, Voice Memos, Files, and Mail, then atomically
/// moves it into the shared App Group queue before the extension exits.
final class ShareViewController: UIViewController {
    private let nameField = UITextField()
    private let dateField = UITextField()
    private var sharedAudioURL: URL?
    private var sharedMetadata: CallUploadMetadata?

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
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { [weak self] url, inPlace, error in
            guard let url else {
                DispatchQueue.main.async { self?.showError(error?.localizedDescription ?? "Could not access the shared audio.") }
                return
            }
            let stagedURL: URL
            do {
                stagedURL = try Self.stageSharedAudio(url, inPlace: inPlace)
            } catch {
                DispatchQueue.main.async { self?.showError(error.localizedDescription) }
                return
            }
            DispatchQueue.main.async {
                self?.sharedAudioURL = stagedURL
                let metadata = ExtensionRecordingTitleParser.parse(suggestedName ?? "")
                self?.sharedMetadata = metadata
                self?.nameField.text = metadata?.counterpartyName
                if let startedAt = metadata?.startedAt {
                    self?.dateField.text = Self.dateFormatter.string(from: startedAt)
                }
            }
        }
    }

    @objc private func sendToMac() {
        guard let sharedAudioURL else { showError("This share item is not an audio file."); return }
        let counterpartyName = nameField.text
        let startedAt = Self.dateFormatter.date(from: dateField.text ?? "") ?? sharedMetadata?.startedAt
        Task {
            do {
                let container = try self.sharedContainer()
                let job = try await ExtensionUploadQueue.enqueue(
                    audioAt: sharedAudioURL,
                    metadata: .init(source: .iphoneRecording, startedAt: startedAt, counterpartyName: counterpartyName),
                    in: container.appendingPathComponent("PhoneUploads", isDirectory: true)
                )
                try ExtensionBackgroundUpload.schedule(job: job, in: container)
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        formatter.timeZone = .current
        return formatter
    }()

    private static func stageSharedAudio(_ source: URL, inPlace: Bool) throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.thatdudealso.callnotes") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = container.appendingPathComponent("SharedAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        let accessed = inPlace && source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do { try FileManager.default.copyItem(at: readableURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t queue recording", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private enum ExtensionUploadQueue {
    static func enqueue(audioAt source: URL, metadata: CallUploadMetadata, in directory: URL) async throws -> PendingUpload {
        let inbox = try PendingUploadInbox(directory: directory)
        return try await inbox.enqueue(audioAt: source, metadata: metadata)
    }
}

private enum ExtensionBackgroundUpload {
    private static let configurationKey = "paired_mac"
    private static let keychainService = "com.thatdudealso.callnotes.phone-pairing"

    static func schedule(job: PendingUpload, in container: URL) throws {
        guard let data = UserDefaults(suiteName: "group.com.thatdudealso.callnotes")?.data(forKey: configurationKey),
              let configuration = try? JSONDecoder().decode(ExtensionPairingConfiguration.self, from: data)
        else { throw URLError(.userAuthenticationRequired) }
        guard let token = token(for: configuration.deviceID) else { throw URLError(.userAuthenticationRequired) }
        let body = try ExtensionMultipartBody.make(job: job, directory: container.appendingPathComponent("UploadRequests", isDirectory: true))
        var request = URLRequest(url: configuration.serverURL.appendingPathComponent("calls").appendingPathComponent(job.id.uuidString))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: "com.thatdudealso.callnotes.share-upload")
        sessionConfiguration.sharedContainerIdentifier = "group.com.thatdudealso.callnotes"
        sessionConfiguration.isDiscretionary = false
        sessionConfiguration.sessionSendsLaunchEvents = true
        sessionConfiguration.waitsForConnectivity = true
        let session = URLSession(configuration: sessionConfiguration, delegate: PinnedExtensionSessionDelegate(fingerprint: configuration.certificateFingerprint), delegateQueue: nil)
        let task = session.uploadTask(with: request, fromFile: body.url)
        task.taskDescription = job.id.uuidString
        task.resume()
    }

    private static func token(for deviceID: UUID) -> String? {
        let task = SecTaskCreateFromSelf(nil)
        guard let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
              let accessGroup = groups.first(where: { $0.hasSuffix(".com.thatdudealso.callnotes.shared") })
        else { return nil }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: deviceID.uuidString, kSecAttrAccessGroup: accessGroup, kSecReturnData: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct ExtensionPairingConfiguration: Codable { var serverURL: URL; var deviceID: UUID; var certificateFingerprint: String }

private final class PinnedExtensionSessionDelegate: NSObject, URLSessionDelegate {
    private let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { completionHandler(.performDefaultHandling, nil); return }
        let actual = CertificateFingerprint.sha256(of: SecCertificateCopyData(certificate) as Data)
        guard actual.caseInsensitiveCompare(fingerprint) == .orderedSame else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private enum ExtensionMultipartBody {
    struct Body { var url: URL; var contentType: String }
    static func make(job: PendingUpload, directory: URL) throws -> Body {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let boundary = "CallNotes-\(UUID().uuidString)"
        let url = directory.appendingPathComponent(job.id.uuidString).appendingPathExtension("multipart")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.write(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        try output.write(contentsOf: encoder.encode(job.metadata))
        try output.write(contentsOf: "\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(job.audioURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        let input = try FileHandle(forReadingFrom: job.audioURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        try output.write(contentsOf: "\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return Body(url: url, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}

private enum ExtensionRecordingTitleParser { static func parse(_ title: String) -> CallUploadMetadata? { SharedRecordingTitleParser.parse(title) } }
