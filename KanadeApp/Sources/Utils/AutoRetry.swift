import Foundation

func withAutoRetry<T>(
    maxAttempts: Int = 3,
    initialDelay: TimeInterval = 1.0,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(initialDelay * Double(attempt)))
            }
        }
    }
    throw lastError!
}
