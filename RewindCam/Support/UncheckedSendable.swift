import Foundation

/// Carries a non-`Sendable` value across a concurrency boundary when the
/// programmer guarantees exclusive access (e.g. an immutable `CGImage` snapshot).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A tiny lock-protected box for state shared between a capture queue and readers.
final class Locked<Value>: @unchecked Sendable {
    // @unchecked: every access to `value` goes through `lock`.
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}
