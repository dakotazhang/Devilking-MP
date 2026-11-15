import Foundation

/// Limits visible poster reads without polling or holding the main actor.
/// A cancelled queued read is removed; a granted slot is always returned.
actor MPArtworkReadGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func read(_ operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.1.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.1.resume()
        } else {
            active -= 1
        }
    }
}
