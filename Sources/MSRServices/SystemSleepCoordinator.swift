import Foundation
import IOKit
import IOKit.pwr_mgt

/// Owns one kernel sleep notification. Completion and timeout may race safely.
public final class SleepAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledge: (@Sendable () -> Void)?

    public init(acknowledge: @escaping @Sendable () -> Void) {
        self.acknowledge = acknowledge
    }

    public func completeAfter(_ interval: TimeInterval, on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + interval) { self.complete() }
    }

    public func complete() {
        lock.lock()
        let callback = acknowledge
        acknowledge = nil
        lock.unlock()
        callback?()
    }

    deinit { complete() }
}

/// Kernel acknowledgement, not an asynchronous NSWorkspace observer, bounds sleep cleanup.
public final class SystemSleepCoordinator: @unchecked Sendable {
    private let onSleep: @Sendable (SleepAcknowledgement) -> Void
    private let onWake: @Sendable () -> Void
    private let onRegistrationFailure: @Sendable () -> Void
    private let startLock = NSLock()
    private var started = false
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let deadlineQueue = DispatchQueue(label: "app.msr.sleep-deadline")

    public init(onSleep: @escaping @Sendable (SleepAcknowledgement) -> Void,
                onWake: @escaping @Sendable () -> Void,
                onRegistrationFailure: @escaping @Sendable () -> Void = {}) {
        self.onSleep = onSleep
        self.onWake = onWake
        self.onRegistrationFailure = onRegistrationFailure
    }

    /// Kept alive for the application lifetime; its run-loop owns the callback context.
    public func start() {
        let shouldStart = startLock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [self] in
            rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(),
                &notificationPort, { context, _, message, argument in
                    guard let context else { return }
                    let owner = Unmanaged<SystemSleepCoordinator>.fromOpaque(context).takeUnretainedValue()
                    owner.handle(message: message, token: Int(bitPattern: argument))
                }, &notifier)
            guard rootPort != 0, let notificationPort,
                  let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
                onRegistrationFailure()
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            CFRunLoopRun()
            // The thread retains self until callbacks are detached, avoiding dangling refCon.
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(notificationPort)
        }
        thread.name = "MSR system sleep notifications"
        thread.start()
    }

    private func handle(message: UInt32, token: Int) {
        switch message {
        // IOMessage.h's function-like C macros are not imported into Swift.
        case 0xe0000270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(rootPort, token)
        case 0xe0000280: // kIOMessageSystemWillSleep
            let port = rootPort
            let acknowledgement = SleepAcknowledgement { IOAllowPowerChange(port, token) }
            acknowledgement.completeAfter(25, on: deadlineQueue)
            onSleep(acknowledgement)
        case 0xe0000300: // kIOMessageSystemHasPoweredOn
            onWake()
        default:
            break
        }
    }
}
