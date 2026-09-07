import Foundation

/// A callback may race cancellation (including cancellation before registration). Resume exactly once.
final class AsyncResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { install($0) }
    }
}

public struct TimeoutError: Error {}

/// Bounds the caller even for synchronous system APIs such as Keychain. Owned operations must still
/// implement cancellation; this cannot forcibly interrupt a synchronous system call.
public func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let result = AsyncResult<T>()
    let work = Task.detached {
        do { result.finish(.success(try await body())) }
        catch { result.finish(.failure(error)) }
    }
    let deadline = Task.detached {
        do {
            try await Task.sleep(for: .seconds(seconds))
            work.cancel()
            result.finish(.failure(TimeoutError()))
        } catch {}
    }
    defer { work.cancel(); deadline.cancel() }
    return try await withTaskCancellationHandler {
        try await result.value()
    } onCancel: {
        work.cancel()
        result.finish(.failure(CancellationError()))
    }
}

/// FIFO across suspension points. Invalidating a publish never lets removal overtake its write.
@MainActor public final class SerialOperationQueue {
    private var tail: Task<Void, Never>?
    public init() {}
    public func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let next = Task { await previous?.value; await operation() }
        tail = next
        return next
    }
}
