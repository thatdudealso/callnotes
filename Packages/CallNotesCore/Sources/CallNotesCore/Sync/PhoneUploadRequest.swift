import Foundation

/// The multipart body `MultipartStreamParser` accepts. The app and the Share
/// Extension POST the same recordings to the same route, so one writer owns the
/// format: a body only one of them knows how to build is answered 400, and a
/// terminal 4xx drops the recording instead of retrying it.
public enum MultipartUploadBody {
    public struct Body: Sendable {
        public var url: URL
        public var contentType: String

        public init(url: URL, contentType: String) {
            self.url = url
            self.contentType = contentType
        }
    }

    public static func make(job: PendingUpload, directory: URL) throws -> Body {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let boundary = "CallNotes-\(UUID().uuidString)"
        let url = directory.appendingPathComponent(job.id.uuidString).appendingPathExtension("multipart")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        try output.write(contentsOf: encoder.encode(job.metadata))
        try output.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(job.audioURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: job.audioURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return Body(url: url, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}

/// Starts one background transfer for a queued job. The task is keyed on the
/// upload ID, which is how `SessionUploadDelegate` settles it through the shared
/// `SessionUploadCoordinator` after either process has exited.
public enum PhoneUploadRequest {
    public static func start(
        job: PendingUpload,
        serverURL: URL,
        token: String,
        session: URLSession,
        requestBodiesDirectory: URL
    ) throws {
        let body = try MultipartUploadBody.make(job: job, directory: requestBodiesDirectory)
        var request = URLRequest(url: serverURL.appendingPathComponent("calls").appendingPathComponent(job.id.uuidString))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, fromFile: body.url)
        task.taskDescription = job.id.uuidString
        task.resume()
    }
}
