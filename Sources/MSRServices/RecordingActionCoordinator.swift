import Foundation

/// Serializes user transitions and retains sleep intent across suspended start/stop calls.
@MainActor
public final class RecordingActionCoordinator {
    public private(set) var actionInFlight = false
    public private(set) var sleepPending = false
    public private(set) var systemAwake = true
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func perform(_ operation: () async -> Void) async {
        guard !actionInFlight, !sleepPending, systemAwake else { return }
        actionInFlight = true
        await operation()
        finishAction()
    }

    public func prepareForSleep(_ finalize: () async -> Void) async {
        systemAwake = false
        if sleepPending {
            await waitForSleepCompletion()
            return
        }
        sleepPending = true
        await waitUntilIdle()
        actionInFlight = true
        await finalize()
        sleepPending = false
        finishAction()
        let waiters = sleepWaiters
        sleepWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public func didWake() { systemAwake = true }

    public func waitForSleepCompletion() async {
        if sleepPending {
            await withCheckedContinuation { sleepWaiters.append($0) }
        }
    }

    public func waitUntilIdle() async {
        while actionInFlight {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func finishAction() {
        actionInFlight = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
