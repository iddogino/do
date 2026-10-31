import CryptoKit
import Foundation
import os

/// Files that make up a model snapshot on the Hugging Face Hub, pinned to a revision.
public struct ModelManifest: Sendable {
    public struct File: Sendable {
        public var path: String
        public var size: Int64
        /// SHA-256 of large (LFS) files; verified after download.
        public var sha256: String?

        public init(path: String, size: Int64, sha256: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var repository: String
    public var revision: String
    public var files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// `pratikgx/Mage-VL-Cowork-MLX-4bit` — community 4-bit MLX build of microsoft/Mage-VL-Cowork.
    public static func mageVLCowork4Bit(revision: String) -> ModelManifest {
        ModelManifest(
            repository: "pratikgx/Mage-VL-Cowork-MLX-4bit",
            revision: revision,
            files: [
                File(path: "config.json", size: 3509),
                File(path: "generation_config.json", size: 121),
                File(path: "preprocessor_config.json", size: 778),
                File(path: "processor_config.json", size: 627),
                File(path: "chat_template.jinja", size: 5365),
                File(path: "added_tokens.json", size: 706),
                File(path: "special_tokens_map.json", size: 384),
                File(path: "tokenizer_config.json", size: 734),
                File(path: "vocab.json", size: 2_776_833),
                File(path: "model.safetensors.index.json", size: 101_325),
                File(
                    path: "tokenizer.json", size: 11_422_650,
                    sha256: "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
                File(
                    path: "model.safetensors", size: 3_142_599_841,
                    sha256: "227dc83aefc5ee5ffefc1a261e1d8c59fc835c64b09f219e32b76a0f8362dea5"),
            ])
    }
}

public enum ModelStoreError: Error, LocalizedError {
    case httpStatus(Int, String)
    case checksumMismatch(String)
    case sizeMismatch(String, expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let file): "Downloading \(file) failed (HTTP \(code))."
        case .checksumMismatch(let file): "\(file) is corrupted (checksum mismatch). Please try again."
        case .sizeMismatch(let file, let e, let a): "\(file) has the wrong size (\(a) bytes, expected \(e))."
        }
    }
}

/// Downloads and verifies a pinned model snapshot into Application Support, resuming partial
/// downloads with HTTP range requests.
public final class ModelStore: Sendable {
    public let manifest: ModelManifest
    public let directory: URL
    private static let log = Logger(subsystem: "com.do.app", category: "ModelStore")

    public init(manifest: ModelManifest, root: URL = ModelStore.defaultRoot) {
        self.manifest = manifest
        self.directory = root.appending(path: manifest.repository, directoryHint: .isDirectory)
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Do/Models", directoryHint: .isDirectory)
    }

    private var verifiedMarker: URL { directory.appending(path: ".verified-\(manifest.revision)") }

    /// True when every file is present with the expected size (checksums were verified when the
    /// snapshot was completed).
    public var isComplete: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: verifiedMarker.path) else { return false }
        return manifest.files.allSatisfy { file in
            let attrs = try? fm.attributesOfItem(atPath: directory.appending(path: file.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    public var bytesOnDisk: Int64 {
        manifest.files.reduce(0) { total, file in
            let url = directory.appending(path: file.path)
            let partial = directory.appending(path: file.path + ".partial")
            let size = { (u: URL) in
                ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return total + max(size(url), size(partial))
        }
    }

    /// Downloads whatever is missing. `progress` receives (bytes done, bytes total).
    public func download(progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = manifest.totalBytes
        let counter = ByteCounter()
        for file in manifest.files {
            let destination = directory.appending(path: file.path)
            if let size = Self.size(of: destination), size == file.size {
                counter.add(size)
                progress(counter.value, total)
                continue
            }
            try await fetch(file, to: destination, counter: counter, total: total, progress: progress)
        }
        progress(total, total)
        // Verify the large files once, then mark the snapshot complete.
        for file in manifest.files {
            let url = directory.appending(path: file.path)
            guard let actual = Self.size(of: url), actual == file.size else {
                throw ModelStoreError.sizeMismatch(file.path, expected: file.size, actual: Self.size(of: url) ?? 0)
            }
            if let expected = file.sha256 {
                let digest = try await Self.sha256(of: url)
                guard digest == expected else {
                    try? FileManager.default.removeItem(at: url)
                    throw ModelStoreError.checksumMismatch(file.path)
                }
            }
        }
        FileManager.default.createFile(atPath: verifiedMarker.path, contents: Data())
    }

    private func fetch(
        _ file: ModelManifest.File, to destination: URL, counter: ByteCounter, total: Int64,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        var offset = Self.size(of: partial) ?? 0
        if offset > file.size { try? FileManager.default.removeItem(at: partial); offset = 0 }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }

        let url = URL(
            string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(file.path)")!
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        Self.log.info("downloading \(file.path) from offset \(offset)")

        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        counter.add(offset)
        let writer = ChunkWriter(
            handle: handle, file: file.path, resumeOffset: offset, counter: counter, total: total, progress: progress)
        try await writer.run(request)
        try handle.close()
        progress(counter.value, total)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    static func size(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Adopts a snapshot that is already on disk (e.g. fetched by a developer script) if it
    /// verifies, so it doesn't need to be downloaded again.
    public func adoptExistingIfValid() async -> Bool {
        if isComplete { return true }
        for file in manifest.files {
            guard Self.size(of: directory.appending(path: file.path)) == file.size else { return false }
        }
        for file in manifest.files where file.sha256 != nil {
            guard (try? await Self.sha256(of: directory.appending(path: file.path))) == file.sha256 else { return false }
        }
        FileManager.default.createFile(atPath: verifiedMarker.path, contents: Data())
        return true
    }
}

/// Streams one HTTP response body into a file, chunk by chunk.
private final class ChunkWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let handle: FileHandle
    let file: String
    let counter: ByteCounter
    let total: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    private var resumeOffset: Int64
    private var continuation: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?
    private var lastReport = Date.distantPast

    init(
        handle: FileHandle, file: String, resumeOffset: Int64, counter: ByteCounter, total: Int64,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) {
        self.handle = handle
        self.file = file
        self.resumeOffset = resumeOffset
        self.counter = counter
        self.total = total
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                queue.addOperation {
                    self.continuation = c
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            failure = ModelStoreError.httpStatus(status, file)
            completionHandler(.cancel)
            return
        }
        if status == 200 && resumeOffset > 0 {
            // The server ignored the range request: start the file over.
            try? handle.truncate(atOffset: 0)
            counter.add(-resumeOffset)
            resumeOffset = 0
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            counter.add(Int64(data.count))
            if Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                progress(counter.value, total)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

private final class ByteCounter: @unchecked Sendable {
    private var bytes: Int64 = 0
    private let lock = NSLock()
    func add(_ n: Int64) { lock.withLock { bytes += n } }
    var value: Int64 { lock.withLock { bytes } }
}
