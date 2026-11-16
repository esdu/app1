import Foundation

/// Runs work on the main actor after a delay. The model's timers — the status loop and the
/// capture-recovery backoff (issue #4) — go through this, so tests drive time with
/// `FakeDelayScheduler.advance(by:)` instead of sleeping. Live: `SystemDelayScheduler`.
///
/// There is no cancellation: callers check a token (for example the recovery id in `AppModel`) when
/// the action runs, and do nothing if it is stale.
@MainActor
protocol DelayScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
final class SystemDelayScheduler: DelayScheduler {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            action()
        }
    }
}

/// Manual time for tests: nothing runs until `advance(by:)`, which runs every action that falls due,
/// soonest first (ties in the order scheduled), including actions scheduled by those actions.
@MainActor
final class FakeDelayScheduler: DelayScheduler {
    private struct Item {
        let due: TimeInterval
        let order: Int
        let action: @MainActor @Sendable () -> Void
    }

    /// Seconds since the scheduler was created.
    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var counter = 0

    /// Actions scheduled and not yet run.
    var pendingCount: Int { items.count }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        counter += 1
        items.append(Item(due: now + max(0, seconds), order: counter, action: action))
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.filter({ $0.due <= target + 1e-9 })
            .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            items.removeAll { $0.order == next.order }
            now = max(now, next.due)
            next.action()
        }
        now = target
    }
}
