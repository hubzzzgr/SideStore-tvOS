import Foundation

/// Cancels and drains admitted pipelines before a device selection changes.
public final class TVOperationCoordinator: @unchecked Sendable {
    public static let shared = TVOperationCoordinator()
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var transitioning = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public var generation: UInt64 { lock.withLock { epoch } }
    public var hasActiveOperations: Bool { lock.withLock { !cancellations.isEmpty } }
    public func enter(generation: UInt64, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        try lock.withLock {
            guard !transitioning, generation == epoch else { throw CancellationError() }
            let id = UUID(); cancellations[id] = cancel; return id
        }
    }
    public func leave(_ id: UUID) {
        let completed: [CheckedContinuation<Void, Never>] = lock.withLock {
            cancellations.removeValue(forKey: id)
            guard cancellations.isEmpty else { return [] }
            let pending = waiters; waiters.removeAll(); return pending
        }
        completed.forEach { $0.resume() }
    }
    /// The owner serializes transitions; callbacks run outside the lock.
    public func beginTransition() {
        let callbacks = lock.withLock {
            transitioning = true; epoch &+= 1
            return Array(cancellations.values)
        }
        callbacks.forEach { $0() }
    }
    public func drain() async {
        await withCheckedContinuation { continuation in
            let empty = lock.withLock {
                if cancellations.isEmpty { return true }
                waiters.append(continuation); return false
            }
            if empty { continuation.resume() }
        }
    }
    public func endTransition() { lock.withLock { transitioning = false } }
}
