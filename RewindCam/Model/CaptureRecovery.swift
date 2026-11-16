import Foundation

/// Why `AppModel.recoverCapture(_:)` was called (issue #4). Every reason gets the same recovery: the
/// recorder is suspended, the phase says what happened and that a restart is under way, and the source
/// is asked to run again (`FrameSource.resumeRunning()`) on the `RestartBackoff` schedule until it
/// does, or until the budget is spent and the app shows "Not recording" with Try Again.
enum CaptureRecoveryReason: Equatable, Sendable {
    /// The source reported a runtime error (`AVCaptureSession.runtimeErrorNotification`).
    case runtimeError(String)
    /// The status-loop safety net found the source stopped while the app means to record, with no
    /// interruption reported (`AppModel.reconcileCapture()`).
    case sourceStopped

    /// The paused-phase message while recovery runs.
    var pausedMessage: String {
        switch self {
        case .runtimeError(let why): InterruptionReason.runtimeError(why).message
        case .sourceStopped: "The camera stopped. Restarting…"
        }
    }

    /// What `FrameSourceError.restartFailed` reports once recovery gives up.
    var failureDetail: String {
        switch self {
        case .runtimeError(let why): why
        case .sourceStopped: "it stopped unexpectedly"
        }
    }
}

/// Bounded restart schedule for capture recovery: a pure value, like `SegmentRing`.
///
/// The first attempt is immediate (after a runtime error the session is often still running, or able
/// to run at once); later ones back off. After `delays.count` attempts, about 30 s in all, recovery
/// gives up rather than claim "Restarting…" forever.
struct RestartBackoff: Equatable, Sendable {
    /// Wait before each attempt, in seconds.
    static let delays: [TimeInterval] = [0, 1, 2, 4, 8, 15]

    /// Attempts handed out so far.
    private(set) var attempts = 0

    /// True once every attempt has been handed out.
    var isExhausted: Bool { attempts >= Self.delays.count }

    /// The wait before the next attempt, or nil when the budget is spent.
    mutating func nextDelay() -> TimeInterval? {
        guard !isExhausted else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }
}
