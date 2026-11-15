import Foundation

/// A deadline for a read operation, including all of its authentication and
/// auxiliary requests. Cancelling the loser also cancels URLSession.data(for:).
enum ReadBudget {
    static func run<Value>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
