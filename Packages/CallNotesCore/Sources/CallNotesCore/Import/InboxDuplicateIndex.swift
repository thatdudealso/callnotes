import CryptoKit
import Foundation

/// Content-hash index so dropping the same recording twice is a no-op.
public actor InboxDuplicateIndex {
    private var hashes: Set<String>
    private let storageURL: URL?
    private let fileManager: FileManager

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        if let storageURL, let data = try? Data(contentsOf: storageURL),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            self.hashes = Set(decoded)
        } else {
            self.hashes = []
        }
    }

    public func fingerprint(of url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FileImportError.invalidAudio("The inbox file could not be read")
        }
        return Array(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    public func contains(_ hash: String) -> Bool {
        hashes.contains(hash)
    }

    /// Returns false when this content was already imported.
    @discardableResult
    public func register(_ hash: String) -> Bool {
        let inserted = hashes.insert(hash).inserted
        persist()
        return inserted
    }

    public func remember(_ url: URL) throws -> Bool {
        try register(fingerprint(of: url))
    }

    private func persist() {
        guard let storageURL else { return }
        let payload = (try? JSONEncoder().encode(Array(hashes).sorted())) ?? Data("[]".utf8)
        try? payload.write(to: storageURL, options: [.atomic])
    }
}
