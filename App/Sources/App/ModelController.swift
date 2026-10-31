import DoCore
import Foundation
import MageVL
import Observation
import os

/// Downloads, loads, and unloads the on-device model.
///
/// Download and load are shared background tasks: any number of callers can wait on them, and
/// a caller giving up (e.g. the user stops a run during the first download) doesn't cancel the
/// download for everyone else.
@MainActor
@Observable
final class ModelController {
    enum State: Equatable {
        case unknown
        case notDownloaded
        case downloading(done: Int64, total: Int64)
        case verifying
        case downloaded
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .unknown
    let store: ModelStore
    @ObservationIgnored private var runtime: MageVLRuntime?
    @ObservationIgnored private var downloadTask: Task<Void, any Error>?
    @ObservationIgnored private var loadTask: Task<MageVLRuntime, any Error>?
    @ObservationIgnored private var idleUnload: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.do.app", category: "Model")

    init() {
        let revision = Bundle.main.object(forInfoDictionaryKey: "DoModelRevision") as? String
        store = ModelStore(manifest: .mageVLCowork4Bit(revision: revision?.isEmpty == false ? revision! : "main"))
    }

    var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: store.manifest.totalBytes, countStyle: .file)
    }

    var isDownloaded: Bool {
        switch state {
        case .downloaded, .loading, .ready: true
        default: false
        }
    }

    /// Cheap check at launch: is the snapshot already on disk?
    func refresh() async {
        guard state == .unknown || state == .notDownloaded else { return }
        var complete = store.isComplete
        if !complete { complete = await store.adoptExistingIfValid() }
        if complete {
            state = .downloaded
        } else if downloadTask == nil {
            state = .notDownloaded
        }
    }

    // MARK: Download

    /// Starts (or joins) the shared download.
    @discardableResult
    func download() -> Task<Void, any Error> {
        if let downloadTask { return downloadTask }
        let task = Task { @MainActor [store] in
            defer { self.downloadTask = nil }
            do {
                var complete = store.isComplete
                if !complete { complete = await store.adoptExistingIfValid() }
                if complete {
                    self.state = .downloaded
                    return
                }
                self.state = .downloading(done: store.bytesOnDisk, total: store.manifest.totalBytes)
                try await store.download { done, total in
                    Task { @MainActor in
                        guard case .downloading = self.state else { return }
                        self.state = done >= total ? .verifying : .downloading(done: done, total: total)
                    }
                }
                self.state = .downloaded
            } catch {
                self.state = .failed(error.localizedDescription)
                throw error
            }
        }
        downloadTask = task
        return task
    }

    // MARK: Load

    /// Downloads if needed, then loads. Cancelling the caller abandons the wait, not the work.
    func prepare(options: MageVLRuntime.Options) async throws -> MageVLRuntime {
        idleUnload?.cancel()
        if let runtime {
            await runtime.setOptions(options)
            return runtime
        }
        let task = loadTask ?? startLoading(options: options)
        let runtime = try await Self.awaitCancellable(task)
        await runtime.setOptions(options)
        return runtime
    }

    private func startLoading(options: MageVLRuntime.Options) -> Task<MageVLRuntime, any Error> {
        let task = Task { @MainActor [store] () throws -> MageVLRuntime in
            defer { self.loadTask = nil }
            do {
                try await self.download().value
                self.state = .loading
                let started = Date()
                let runtime = try await MageVLRuntime.load(directory: store.directory, options: options)
                await runtime.warmUp()
                Self.log.info("model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
                self.runtime = runtime
                self.state = .ready
                return runtime
            } catch {
                self.state = .failed(error.localizedDescription)
                throw error
            }
        }
        loadTask = task
        return task
    }

    /// Waits for `task` but returns (throwing `CancellationError`) as soon as the caller is
    /// cancelled, leaving `task` running.
    private static func awaitCancellable<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
        let gate = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task {
                    do { gate.resume(.success(try await task.value)) } catch { gate.resume(.failure(error)) }
                }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }

    // MARK: Unload

    /// Schedules unloading after a period of inactivity to give memory back.
    func scheduleUnload(afterMinutes minutes: Int) {
        idleUnload?.cancel()
        guard minutes > 0, runtime != nil else { return }
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    func unload() {
        guard runtime != nil, loadTask == nil else { return }
        runtime = nil
        MageVLRuntime.releaseCachedMemory()
        state = store.isComplete ? .downloaded : .notDownloaded
        Self.log.info("model unloaded")
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?

    func install(_ c: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = lock.withLock {
            if let pending { return pending }
            continuation = c
            return nil
        }
        if let early { c.resume(with: early) }
    }

    func resume(_ result: Result<T, any Error>) {
        let c: CheckedContinuation<T, any Error>? = lock.withLock {
            if let continuation {
                self.continuation = nil
                return continuation
            }
            if pending == nil { pending = result }
            return nil
        }
        c?.resume(with: result)
    }
}
